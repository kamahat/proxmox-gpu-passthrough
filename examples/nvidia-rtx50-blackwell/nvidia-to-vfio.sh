#!/bin/bash
# RTX 50-series (Blackwell GB205/GB206/GB207) — nvidia-open -> vfio-pci handoff
#
# Mechanism:
#   1. Bind nvidia-open via driver_override (prevents vfio-pci auto-claim)
#   2. Open /dev/nvidia0 to trigger GSP lazy init (RmInitAdapter)
#   3. rmmod nvidia  ->  NVreg_PreserveVideoMemoryAllocations=0 clears WPR2 to 0
#   4. Bind vfio-pci via driver_override + drivers_probe
#
# At VM start, QEMU uses FLR (not SBR) because audio 00.1 is in a separate IOMMU
# group and NOT in the VFIO container  ->  FLR does not assert PERST#  ->  WPR2
# stays 0  ->  guest cold-boots cleanly.
#
# Full architecture: docs/vendors/nvidia-rtx50-blackwell.md
#
# Usage:  nvidia-to-vfio.sh [GPU_BDF]
#         Default GPU_BDF: 0000:03:00.0

set -uo pipefail

GPU_PCI="${1:-0000:03:00.0}"
LOGFILE="/var/log/nvidia-to-vfio.log"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOGFILE"; }
die() { log "ERROR: $*"; exit 1; }

# ── Prerequisite checks ──────────────────────────────────────────────────────
[ "$(id -u)" -eq 0 ] || die "Must run as root"
[ -d /sys/kernel/iommu_groups ] \
    || die "IOMMU not enabled -- add intel_iommu=on (or amd_iommu=on) to kernel cmdline"
[ -e "/sys/bus/pci/devices/$GPU_PCI" ] \
    || die "PCI device $GPU_PCI not found -- check lspci and adjust GPU_PCI"

log "=== RTX 50-series handoff starting === GPU: $GPU_PCI"

DRIVER="$(basename "$(readlink "/sys/bus/pci/devices/$GPU_PCI/driver" 2>/dev/null)" \
         2>/dev/null || true)"
log "Initial driver: ${DRIVER:-none}"

if [ "$DRIVER" = "vfio-pci" ]; then
    log "GPU already on vfio-pci -- nothing to do."
    exit 0
fi

# ── Phase 1: Bind nvidia-open ────────────────────────────────────────────────
log "Phase 1: Binding nvidia-open..."
echo "nvidia" > "/sys/bus/pci/devices/$GPU_PCI/driver_override"
if [ -n "$DRIVER" ] && [ "$DRIVER" != "nvidia" ]; then
    echo "$GPU_PCI" > "/sys/bus/pci/drivers/$DRIVER/unbind" 2>/dev/null || true
    sleep 1
fi
modprobe nvidia NVreg_PreserveVideoMemoryAllocations=0
sleep 2
DRIVER="$(basename "$(readlink "/sys/bus/pci/devices/$GPU_PCI/driver" 2>/dev/null)" \
         2>/dev/null || true)"
if [ "$DRIVER" != "nvidia" ]; then
    echo "$GPU_PCI" > /sys/bus/pci/drivers_probe
    sleep 3
    DRIVER="$(basename "$(readlink "/sys/bus/pci/devices/$GPU_PCI/driver" 2>/dev/null)" \
             2>/dev/null || true)"
fi
[ "$DRIVER" = "nvidia" ] || die "Failed to bind nvidia (got: ${DRIVER:-none})"
log "  nvidia bound."

# ── Phase 2: Trigger GSP lazy initialization ─────────────────────────────────
# nvidia-open does NOT boot GSP at modprobe time. GSP only initialises when the
# first user-space process opens /dev/nvidia0 (RmInitAdapter). Create device
# nodes manually if nvidia-modprobe is not installed (not on Proxmox by default).
log "Phase 2: Triggering GSP initialization..."
if [ ! -e /dev/nvidia0 ]; then
    NVIDIA_MAJOR="$(awk '/nvidia-frontend/{print $1}' /proc/devices 2>/dev/null \
                   || true)"
    [ -n "$NVIDIA_MAJOR" ] \
        || NVIDIA_MAJOR="$(awk '/ nvidia$/{print $1}' /proc/devices 2>/dev/null \
                          || true)"
    [ -n "$NVIDIA_MAJOR" ] || NVIDIA_MAJOR=195
    mknod -m 666 /dev/nvidiactl c "$NVIDIA_MAJOR" 255 2>/dev/null || true
    mknod -m 666 /dev/nvidia0   c "$NVIDIA_MAJOR" 0   2>/dev/null || true
    log "  Created /dev/nvidia0 (major=$NVIDIA_MAJOR)"
fi
python3 - <<'PYEOF'
import os, sys, time
try:
    fd = os.open('/dev/nvidia0', os.O_RDWR)
    time.sleep(3)
    os.close(fd)
    print('  /dev/nvidia0 opened OK -- GSP initialized')
except OSError as exc:
    print(f'  Warning (non-fatal): {exc}', file=sys.stderr)
PYEOF
sleep 1
FIRMWARE="$(awk '/GPU Firmware/{print $NF}' \
           "/proc/driver/nvidia/gpus/$GPU_PCI/information" 2>/dev/null || true)"
if [ -n "$FIRMWARE" ] && [ "$FIRMWARE" != "N/A" ]; then
    log "  GPU Firmware: $FIRMWARE -- GSP active, WPR2 will be cleanly zeroed on unload."
else
    log "  Warning: GSP state unconfirmed. Falling back to BIOS WPR2 state."
    log "  (Valid only if BIOS executed VBIOS at POST -- see recipe §Fallback)"
fi

# ── Phase 3: Unload nvidia (clears WPR2) ─────────────────────────────────────
log "Phase 3: Unloading nvidia (NVreg_PreserveVideoMemoryAllocations=0 -> WPR2=0)..."
rm -f /dev/nvidia0 /dev/nvidiactl 2>/dev/null || true
rmmod nvidia_drm     2>/dev/null || true
rmmod nvidia_modeset 2>/dev/null || true
rmmod nvidia_uvm     2>/dev/null || true
sleep 1
rmmod nvidia || die "Could not unload nvidia module"
lsmod | grep -q "^nvidia " && die "nvidia still loaded after rmmod"
log "  nvidia unloaded. WPR2 cleared."

# ── Phase 4: Bind vfio-pci ───────────────────────────────────────────────────
log "Phase 4: Binding vfio-pci..."
modprobe vfio-pci
modprobe vfio_iommu_type1 2>/dev/null || true
echo "vfio-pci" > "/sys/bus/pci/devices/$GPU_PCI/driver_override"
echo "$GPU_PCI"  > /sys/bus/pci/drivers_probe
sleep 1
DRIVER="$(basename "$(readlink "/sys/bus/pci/devices/$GPU_PCI/driver" 2>/dev/null)" \
         2>/dev/null || true)"
[ "$DRIVER" = "vfio-pci" ] || die "Failed to bind vfio-pci (got: ${DRIVER:-none})"
echo "" > "/sys/bus/pci/devices/$GPU_PCI/driver_override"
log "=== Handoff complete. $GPU_PCI -> vfio-pci. GPU ready for passthrough. ==="
