# NVIDIA RTX 50-series (Blackwell) — Full Recipe

> 🚧 **Status**: Under validation. Confirmed 2026-05-28 on NVIDIA GeForce RTX 5070 GB205,
> Proxmox VE 9.2.2 kernel 7.0.2-6-pve — both Linux (Ubuntu 26.04, nvidia-driver 595.71.05)
> and Windows 11 guests (NVIDIA Game Ready Driver). Promoting to ✅ after ≥2-week production uptime.

## TL;DR

RTX 5070 (Blackwell GB205/GB206/GB207) passthrough to Linux guests requires a **host-side
nvidia→vfio-pci handoff** before each VM start. Blackwell's FSP (Falcon Security Processor)
pre-arms its Write-Protected Region 2 (WPR2) at every PERST# assertion with sentinel
`0xbadf4100`; the guest driver cannot initialize GSP from this invalid state. The fix is to
(1) load `nvidia-open` on the host to run GSP and write a valid WPR2, (2) unload nvidia
(`NVreg_PreserveVideoMemoryAllocations=0` guarantees WPR2 is cleared to 0 on unload), then
(3) bind `vfio-pci`. Passing **only** the GPU function (`00.0`, not the audio `00.1`) in the
VM config causes QEMU to use FLR instead of PCIe Secondary Bus Reset — FLR does not assert
PERST# and WPR2 stays 0 across VM stop/start cycles.

## Tested Matrix

| Host | Guest | Driver | Result |
|------|-------|--------|--------|
| Proxmox VE 9.2.2, kernel 7.0.2-6-pve (Debian 13 Trixie) | Ubuntu 26.04 LTS | nvidia-driver-595-server-open (595.71.05) | ✅ `nvidia-smi` OK, CUDA 13.2, 12 227 MiB VRAM |
| Proxmox VE 9.2.2, kernel 7.0.2-6-pve (Debian 13 Trixie) | Windows 11 (24H2) | NVIDIA Game Ready Driver (standard) | ✅ GPU visible in Device Manager, no error code. `rombar=0` confirmed; `x-vga=1` not required |

## Failure Modes This Recipe Prevents

| Symptom | `dmesg` / log evidence | Root cause |
|---------|------------------------|------------|
| Guest driver fails on every boot | `NVRM: GPU 0000:01:00.0: RmInitAdapter failed! (0x22:0x56:1017)` | WPR2 pre-armed (`0xbadf4100`) by FSP at PERST# — host must clear it before handing GPU to vfio-pci |
| Guest driver works first boot, fails after VM restart | Same `RmInitAdapter` error on second start | QEMU issues PCIe Secondary Bus Reset (SBR) via parent bridge → PERST# asserted → FSP re-arms WPR2 |
| `nvidia-smi` hangs or returns `Failed to initialize NVML` | — | WPR2 not cleared; GSP cannot cold-boot in guest |
| GPU unrecoverable without host reboot | — | After SBR path: only host power-cycle clears FSP state |

## Architecture: Blackwell WPR2 Pre-Arm

```
Power-on / PERST# assertion
  └─ FSP (Falcon Security Processor) arms WPR2 ← sentinel 0xbadf4100  (invalid)

BIOS POST  [if VBIOS executed — see §Host Prep §Fallback: BIOS WPR2 path]
  └─ GSP boots → WPR2 written with valid firmware signature

Host: modprobe nvidia-open
  └─ nvidia driver loads; GPU visible but GSP not yet booted

Host: mknod /dev/nvidia0 + python3 opens it  [Phase 2 of handoff script]
  └─ RmInitAdapter() called → GSP cold-boots → GPU Firmware: <version> logged

Host: rmmod nvidia  [NVreg_PreserveVideoMemoryAllocations=0]
  └─ WPR2 = 0                        ← clean state for guest cold-boot

Host: vfio-pci binds GPU (WPR2 = 0)
  └─ VM starts
  └─ QEMU issues FLR                 ← hot-reset check fails because audio 00.1
     (NOT SBR)                          is in a separate IOMMU group, not in the
                                        VFIO container
  └─ FLR does NOT assert PERST#     ← WPR2 stays 0
  └─ Guest NVIDIA driver loads → GSP cold-boots cleanly → GPU operational
```

Reset type comparison:

| Reset type | PERST# asserted? | WPR2 after reset | Guest driver result |
|-----------|:----------------:|:----------------:|:-------------------:|
| FLR (Function Level Reset) | ❌ No | Unchanged (0 = clean) | ✅ Cold-boots cleanly |
| SBR (Secondary Bus Reset via parent bridge) | ✅ Yes | `0xbadf4100` (invalid) | ❌ `RmInitAdapter` fails |
| D3cold (PCIe power cycle) | ✅ Yes | `0xbadf4100` (invalid) | ❌ `RmInitAdapter` fails |

The RTX 5070 supports FLR (`FLReset+` in PCIe DevCap). QEMU selects FLR **only if** the
hot-reset ioctl (`VFIO_DEVICE_PCI_HOT_RESET`) is blocked — which is the case when the audio
companion (`00.1`) is **not** in the VM's VFIO container.

---

## Host Prep

Standard [HOST_SETUP.md](../HOST_SETUP.md) applies. Blackwell-specific steps follow.

### Step 1 — Identify PCI IDs

```bash
lspci -nn | grep -i nvidia
```

Common RTX 50-series IDs (check your card — IDs vary within a SKU family):

| Card | GPU ID | Audio companion ID |
|------|--------|--------------------|
| RTX 5070 | `10de:2f04` | `10de:2f80` |
| RTX 5080 | check `lspci` | check `lspci` |
| RTX 5090 | check `lspci` | check `lspci` |

### Step 2 — Verify IOMMU Groups (Critical)

GPU (`00.0`) and audio (`00.1`) **must** be in separate IOMMU groups for the FLR workaround
to work. Verify:

```bash
for d in /sys/kernel/iommu_groups/*/devices/*; do
    printf "Group %s: %s\n" \
        "$(basename "$(dirname "$(dirname "$d")")")"\
        "$(lspci -nns "$(basename "$d")" 2>/dev/null)"
done | grep -i nvidia
```

Expected (separate groups):
```
Group 24: 0000:03:00.0 VGA compatible controller [0300]: NVIDIA ... [10de:2f04]
Group 25: 0000:03:00.1 Audio device [0403]: NVIDIA ... [10de:2f80]
```

If both devices are in the **same group**, add `pcie_acs_override=downstream,multifunction`
to the kernel cmdline (see Step 3) and recheck after reboot. If they remain in the same
group after ACS override, the FLR workaround cannot be used — you must pass both devices
and accept the SBR path (see §Known Limitations).

### Step 3 — GRUB / Kernel Cmdline

```
GRUB_CMDLINE_LINUX_DEFAULT="... intel_iommu=on iommu=pt \
  pcie_acs_override=downstream,multifunction \
  vfio_iommu_type1.allow_unsafe_interrupts=1 \
  pcie_port_pm=off"
```

| Parameter | Purpose |
|-----------|-------|
| `intel_iommu=on` | Enable Intel VT-d IOMMU (use `amd_iommu=on` for AMD) |
| `iommu=pt` | Pass-through mode: avoids DMA translation overhead for non-IOMMU devices |
| `pcie_acs_override=downstream,multifunction` | Split multifunction PCIe devices into separate IOMMU groups |
| `vfio_iommu_type1.allow_unsafe_interrupts=1` | Required on some platforms for MSI-X passthrough |
| `pcie_port_pm=off` | Disable PCIe port power management — prevents spurious D3 transitions that can trigger PERST# |

Apply:
```bash
update-grub && reboot
```

### Step 4 — Install nvidia-open on Host

Blackwell **requires** `nvidia-open` (open-source kernel modules). The closed `nvidia.ko`
does not support GB2xx/GB3xx architecture — using it produces the `RmInitAdapter` error even
on the host.

```bash
# Debian/Proxmox host
apt install nvidia-open-kernel-dkms
# Or the full headless stack:
apt install nvidia-kernel-open-dkms libnvidia-compute-595-server
```

Do not install `nvidia-driver-595-server` (closed). The package
`nvidia-driver-595-server-open` installs the open variant.

Verify after reboot:
```bash
modprobe nvidia
dmesg | grep -iE "nvidia.*open|gsp" | head -10
# Expected: "nvidia-open 595.71.05" and no RmInitAdapter errors
```

### Step 5 — `/etc/modprobe.d/vfio.conf` (no GPU IDs)

```
# /etc/modprobe.d/vfio.conf
# RTX 50-series (Blackwell) — vfio-pci bind managed by nvidia-to-vfio.service
# Do NOT add ids=10de:2f04,10de:2f80 here — vfio-pci auto-claim blocks the handoff
# script from loading nvidia to initialise GSP. driver_override is used per-device.
options vfio-pci disable_idle_d3=1
softdep nouveau pre: vfio-pci
softdep nvidia pre: vfio-pci
softdep snd_hda_intel pre: vfio-pci
```

### Step 6 — `/etc/modprobe.d/nvidia.conf`

```
# /etc/modprobe.d/nvidia.conf
options nvidia NVreg_PreserveVideoMemoryAllocations=0
```

With `NVreg_PreserveVideoMemoryAllocations=1` (default when system hibernate is enabled),
nvidia preserves GPU state across suspend/resume — which means `rmmod nvidia` does NOT clear
WPR2. Value `0` guarantees WPR2 is zeroed on every unload. Without this setting the handoff
script leaves WPR2 = `0xbadf4100` and the guest driver fails.

### Step 7 — `/etc/modules-load.d/vfio.conf`

```
vfio
vfio_iommu_type1
vfio_pci
kvm_intel
```

### Step 8 — Handoff Script

Install at `/usr/local/sbin/nvidia-to-vfio.sh`
(see also: [`examples/nvidia-rtx50-blackwell/nvidia-to-vfio.sh`](../../examples/nvidia-rtx50-blackwell/nvidia-to-vfio.sh)):

```bash
#!/bin/bash
# RTX 50-series (Blackwell GB205/GB206/GB207) — nvidia-open → vfio-pci handoff
#
# Mechanism:
#   1. Bind nvidia-open via driver_override (prevents vfio-pci auto-claim)
#   2. Open /dev/nvidia0 to trigger GSP lazy init (RmInitAdapter)
#   3. rmmod nvidia  →  NVreg_PreserveVideoMemoryAllocations=0 clears WPR2 to 0
#   4. Bind vfio-pci via driver_override + drivers_probe
#
# At VM start, QEMU uses FLR (not SBR) because audio 00.1 is in a separate IOMMU
# group and NOT in the VFIO container  →  FLR does not assert PERST#  →  WPR2 stays 0
# →  guest cold-boots cleanly.
#
# Full architecture: docs/vendors/nvidia-rtx50-blackwell.md

set -uo pipefail

GPU_PCI="${1:-0000:03:00.0}"
LOGFILE="/var/log/nvidia-to-vfio.log"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOGFILE"; }
die() { log "ERROR: $*"; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Must run as root"
[ -d /sys/kernel/iommu_groups ]       || die "IOMMU not enabled — add intel_iommu=on to kernel cmdline"
[ -e "/sys/bus/pci/devices/$GPU_PCI" ] || die "PCI device $GPU_PCI not found"

log "=== RTX 50-series handoff starting === GPU: $GPU_PCI"

DRIVER="$(basename "$(readlink "/sys/bus/pci/devices/$GPU_PCI/driver" 2>/dev/null)" 2>/dev/null || true)"
log "Initial driver: ${DRIVER:-none}"

if [ "$DRIVER" = "vfio-pci" ]; then
    log "GPU already on vfio-pci — nothing to do."
    exit 0
fi

# ── Phase 1: Bind nvidia ─────────────────────────────────────────────────────
log "Phase 1: Binding nvidia-open..."
echo "nvidia" > "/sys/bus/pci/devices/$GPU_PCI/driver_override"
if [ -n "$DRIVER" ] && [ "$DRIVER" != "nvidia" ]; then
    echo "$GPU_PCI" > "/sys/bus/pci/drivers/$DRIVER/unbind" 2>/dev/null || true
    sleep 1
fi
modprobe nvidia NVreg_PreserveVideoMemoryAllocations=0
sleep 2
DRIVER="$(basename "$(readlink "/sys/bus/pci/devices/$GPU_PCI/driver" 2>/dev/null)" 2>/dev/null || true)"
if [ "$DRIVER" != "nvidia" ]; then
    echo "$GPU_PCI" > /sys/bus/pci/drivers_probe
    sleep 3
    DRIVER="$(basename "$(readlink "/sys/bus/pci/devices/$GPU_PCI/driver" 2>/dev/null)" 2>/dev/null || true)"
fi
[ "$DRIVER" = "nvidia" ] || die "Failed to bind nvidia (got: ${DRIVER:-none})"
log "  nvidia bound."

# ── Phase 2: Trigger GSP lazy initialization ─────────────────────────────────
# nvidia-open does NOT boot GSP at modprobe time. GSP only initialises when a
# process first opens /dev/nvidia0 (RmInitAdapter). Create device nodes manually
# if nvidia-modprobe is not installed (it is not on Proxmox by default).
log "Phase 2: Triggering GSP initialization..."
if [ ! -e /dev/nvidia0 ]; then
    NVIDIA_MAJOR="$(awk '/nvidia-frontend/{print $1}' /proc/devices 2>/dev/null || true)"
    [ -n "$NVIDIA_MAJOR" ] || NVIDIA_MAJOR="$(awk '/ nvidia$/{print $1}' /proc/devices 2>/dev/null || true)"
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
    print('  /dev/nvidia0 opened OK — GSP initialized')
except OSError as exc:
    print(f'  Warning (non-fatal): {exc}', file=sys.stderr)
PYEOF
sleep 1
FIRMWARE="$(awk '/GPU Firmware/{print $NF}' "/proc/driver/nvidia/gpus/$GPU_PCI/information" 2>/dev/null || true)"
if [ -n "$FIRMWARE" ] && [ "$FIRMWARE" != "N/A" ]; then
    log "  GPU Firmware: $FIRMWARE — GSP active, WPR2 will be cleanly zeroed on unload."
else
    log "  Warning: GSP state unconfirmed. Falling back to BIOS WPR2 state."
    log "  (Valid only if BIOS executed VBIOS at POST — see §Fallback: BIOS WPR2 path)"
fi

# ── Phase 3: Unload nvidia (clears WPR2) ─────────────────────────────────────
log "Phase 3: Unloading nvidia (NVreg_PreserveVideoMemoryAllocations=0 → WPR2=0)..."
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
DRIVER="$(basename "$(readlink "/sys/bus/pci/devices/$GPU_PCI/driver" 2>/dev/null)" 2>/dev/null || true)"
[ "$DRIVER" = "vfio-pci" ] || die "Failed to bind vfio-pci (got: ${DRIVER:-none})"
echo "" > "/sys/bus/pci/devices/$GPU_PCI/driver_override"
log "=== Handoff complete. $GPU_PCI → vfio-pci. GPU ready for passthrough. ==="
```

Make executable:
```bash
chmod 750 /usr/local/sbin/nvidia-to-vfio.sh
```

### Step 9 — Systemd Service

```ini
# /etc/systemd/system/nvidia-to-vfio.service
[Unit]
Description=RTX 50-series nvidia-open -> vfio-pci handoff (Blackwell WPR2 workaround)
Documentation=https://github.com/kamahat/proxmox-gpu-passthrough/blob/main/docs/vendors/nvidia-rtx50-blackwell.md
After=sysinit.target local-fs.target
Before=pve-guests.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/nvidia-to-vfio.sh
StandardOutput=journal+console
StandardError=journal+console
TimeoutStartSec=120
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
```

Enable:
```bash
systemctl daemon-reload
systemctl enable --now nvidia-to-vfio.service
systemctl status nvidia-to-vfio.service
journalctl -u nvidia-to-vfio.service -f
# Persistent log: /var/log/nvidia-to-vfio.log
```

---

## VM Config

> **Key**: `hostpci0: 0000:03:00.0,pcie=1,rombar=0` — GPU function **only**, no audio `00.1`.
> This single change is what forces FLR over SBR. See §Why Audio is Excluded below.

```
# Sanitized output of: qm config <vmid>
agent: 1,fstrim_cloned_disks=1
balloon: 0
bios: ovmf
boot: order=virtio0;net0
cores: 6
cpu: host
efidisk0: local-lvm:vm-100-disk-0,efitype=4m,size=4M
hostpci0: 0000:03:00.0,pcie=1,rombar=0
machine: q35
memory: 16384
net0: virtio=00:00:5E:00:53:01,bridge=vmbr0
numa: 0
onboot: 1
ostype: l26
vga: none
virtio0: local-lvm:vm-100-disk-1,cache=writeback,iothread=1,size=20G
```

### VM Config Rationale

| Setting | Value | Reason |
|---------|-------|-------|
| `hostpci0` | `0000:03:00.0,pcie=1,rombar=0` | GPU function only — prevents SBR; `pcie=1` = PCIe native mode; `rombar=0` = no VBIOS ROM BAR (Linux guest uses firmware from driver package) |
| `bios` | `ovmf` | UEFI required — SeaBIOS does not enumerate PCIe capabilities correctly for NVIDIA passthrough |
| `machine` | `q35` | Required for `pcie=1` — Q35 provides PCIe topology |
| `cpu` | `host` | Full host CPU features exposed; NVIDIA GSP requires certain instructions |
| `vga` | `none` | Disable emulated VGA framebuffer — avoids init conflicts with passthrough GPU |
| `balloon` | `0` | Disable memory ballooning — NVIDIA driver pins GPU DMA pages; balloon driver conflicts |
| `onboot` | `1` | Autostart after `nvidia-to-vfio.service` completes (enforced by `Before=pve-guests.service`) |

### Windows 11 Guest — Looking Glass / Gaming Config

The same `hostpci0` line works unchanged for Windows 11. Key differences from the Linux config:

```
# Windows 11 passthrough — key lines (sanitized qm config output)
bios: ovmf
machine: pc-q35-11.0
ostype: win11
cpu: host,hidden=1,flags=-hv-evmcs;-hv-tlbflush;+pcid
hostpci0: 0000:03:00.0,pcie=1,rombar=0
vga: virtio
tpmstate0: local-lvm:vm-XXX-disk-0,size=4M,version=v2.0
```

| Setting | Windows-specific note |
|---------|----------------------|
| `hostpci0` | **Identical** to Linux — same `rombar=0`, no `x-vga=1` needed |
| `vga: virtio` | Use `virtio` (not `none`) when Looking Glass is in the guest — Windows needs a primary display for the desktop session |
| `ostype: win11` | Activates Windows-specific QEMU settings |
| `tpmstate0` | TPM 2.0 required by Windows 11 — swtpm auto-configured by Proxmox |
| `cpu: hidden=1` | Hides KVM hypervisor from guest — required for some anti-cheat systems (Valorant, Easy Anti-Cheat) |

**Anti-cheat CPU args** (add to `args` if needed for Valorant/EAC):
```
-cpu host,kvm=off,hv_vendor_id=GenuineIntel,hv_relaxed=off,hv_vapic=off,hv_time=off,hv_crash=off,hv_reset=off,hv_vpindex=off,hv_runtime=off,hv_synic=off,hv_stimer=off,hv_tlbflush=off,hv_evmcs=off
```
This completely disables Hyper-V enlightenments and masks KVM. Not needed for the passthrough to work — only for games that ban on detected virtualization.

**Looking Glass** (optional — host-to-guest low-latency display capture):
```
# Add to args:
-device ivshmem-plain,memdev=ivshmem,bus=pcie.0
-object memory-backend-file,id=ivshmem,share=on,mem-path=/dev/shm/looking-glass,size=128M
-device virtio-mouse-pci
-device virtio-keyboard-pci
```
See [Looking Glass documentation](https://looking-glass.io/docs/stable/) for the host client and guest IVSHMEM driver.

### Why Audio (`00.1`) is Intentionally Excluded

The mechanism relies on VFIO's hot-reset permission check:

1. QEMU calls `VFIO_DEVICE_PCI_HOT_RESET` on the GPU at VM init.
2. The kernel checks that **all** devices in the reset path's IOMMU groups are owned by the
   same VFIO container.
3. With only `00.0` passed to the VM, `00.1` (audio, in its own IOMMU group) is **not** in
   the container → hot-reset check **fails**.
4. QEMU falls back to FLR (`FLReset+` is present in RTX 5070 PCIe DevCap).
5. FLR resets only the function's internal state and does **not** assert PERST# on the PCIe
   bus → FSP does not re-arm WPR2 → WPR2 stays 0 → guest cold-boots.

Without audio in the VM, use a software audio path: PipeWire/PulseAudio network audio,
USB audio passthrough, or QEMU's built-in AC'97/HDA emulation (`-soundhw hda`).

---

## Guest Driver Install

### Windows 11

Install the standard **NVIDIA Game Ready Driver** or **Studio Driver** from
[nvidia.com/drivers](https://www.nvidia.com/drivers). The open-source `nvidia-open` modules
are Linux-only; Windows uses the standard Windows driver package.

```
# Windows — not a command, just a note:
# Download: https://www.nvidia.com/drivers  (Game Ready or Studio, GeForce RTX 5070)
# Install normally — no special flags needed
# Reboot when prompted
```

Verify in **Device Manager → Display adapters**: "NVIDIA GeForce RTX 5070" should appear with
no yellow warning triangle (code 43 or similar). If you see Code 43, check:
1. `rombar=0` is set in the VM config (already the recommended value)
2. The handoff service ran successfully at host boot:
   `journalctl -u nvidia-to-vfio.service` should show `Handoff complete`

> **Note**: `x-vga=1` is **not** required for Windows with RTX 50-series — confirmed working
> without it. `rombar=0` also works for Windows (standard VBIOS is not needed; the driver
> uses its own firmware).

### Linux — Ubuntu 24.04 / 26.04

```bash
# Inside the Ubuntu VM
sudo apt update
sudo ubuntu-drivers install --gpgpu
# Or explicitly (replace 595 with available version):
sudo apt install nvidia-driver-595-server-open
```

Verify:
```bash
nvidia-smi
```

Expected output:
```
+-----------------------------------------------------------------------------------------+
| NVIDIA-SMI 595.71.05              Driver Version: 595.71.05      CUDA Version: 13.2     |
+-----------------------------------------+------------------------+----------------------+
|   0  NVIDIA GeForce RTX 5070        Off |   00000000:01:00.0 Off |                  N/A |
|  0%   39C    P8              4W /  250W |      27MiB /  12227MiB |      0%      Default |
+-----------------------------------------+------------------------+----------------------+
```

### Why Open Modules Are Required in the Linux Guest

```
# dmesg with closed nvidia.ko in guest:
NVRM: The NVIDIA GPU 0000:01:00.0 (PCI ID: 10de:2f04)
NVRM: installed in this system requires use of the NVIDIA open kernel modules.
NVRM: GPU 0000:01:00.0: RmInitAdapter failed! (0x22:0x56:1017)
NVRM: GPU 0000:01:00.0: rm_init_adapter failed, device minor number 0
```

All Blackwell (GB1xx/GB2xx/GB3xx) and Ada Lovelace (AD1xx) GPUs require open modules.
Install `nvidia-driver-<VERSION>-open` (desktop) or `nvidia-driver-<VERSION>-server-open`
(headless/server). Turing (TU1xx) and Ampere (GA1xx) still work with either.

---

## Vendor-Specific Gotchas and Fixes

### Gotcha 1 — GSP Lazy Init: Must Open `/dev/nvidia0`

`modprobe nvidia` does **not** boot GSP. GSP only initialises when the first user-space
process calls `open("/dev/nvidia0")` (triggers `RmInitAdapter` in the open-source driver).

**Consequence on Proxmox**: `nvidia-modprobe` is not installed by default. After
`modprobe nvidia`, the `/dev/nvidia*` nodes do not exist. The handoff script creates them
manually using `mknod` with the major number from `/proc/devices` (entry name
`nvidia-frontend`, fallback major 195).

Confirmed working — boot log excerpt:
```
06:25:47   Phase 2: Triggering GSP initialization...
06:25:47   Created device nodes (major=195)
06:25:53   /dev/nvidia0 opened OK -- GSP initialized
06:25:53   GPU Firmware: 595.71.05 -- GSP active, WPR2 will be cleanly zeroed on unload.
06:25:54   nvidia unloaded. WPR2 cleared.
06:25:55   Handoff complete. 0000:a2:00.0 -> vfio-pci.
```

If the device nodes fail to create (check `/var/log/nvidia-to-vfio.log` for "Warning:
non-fatal"), the script falls back to the BIOS WPR2 path (Phase 2 no-op; see §Gotcha 2).

### Gotcha 2 — Fallback: BIOS WPR2 Path

> **This is a fallback path.** The primary path (GSP full init via `/dev/nvidia0`, §Gotcha 1)
> is confirmed working and preferred. This fallback activates only when Phase 2 cannot
> complete — e.g. on an older script version, or if `/dev/nvidia0` creation fails.

If Phase 2 (GSP init) is skipped, the script still works **provided the BIOS executed the
VBIOS ROM during POST**. In that case:
- BIOS boots GSP at power-on → WPR2 = valid firmware signature (not `0xbadf4100`)
- `modprobe nvidia` on host: driver loads, attaches to already-valid WPR2 (no new GSP boot)
- `rmmod nvidia` with `NVreg_PreserveVideoMemoryAllocations=0`: WPR2 preserved as-is
  (already valid from BIOS; not zeroed, but sufficient for guest cold-boot)
- Guest cold-boots successfully against the BIOS-valid WPR2 state

Log signature for this fallback path:
```
Phase 2: Triggering GSP initialization...
Warning: GSP state unconfirmed. Falling back to BIOS WPR2 state.
```

This path requires the platform BIOS to execute the GPU VBIOS at POST
(see §Appendix for HP ProLiant configuration). On standard consumer boards,
VBIOS execution at POST is typically enabled by default when a display is connected.

### Gotcha 3 — `NVreg_PreserveVideoMemoryAllocations` Must Be 0

With the default value `1` (set when system suspend/hibernate is available), `rmmod nvidia`
**preserves** GPU memory state for resume — including WPR2. After unload, WPR2 = `0xbadf4100`
(the pre-arm sentinel) rather than 0. vfio-pci binds to a GPU with invalid WPR2, and the
guest driver fails.

This parameter must be `0` on the **host** (in `/etc/modprobe.d/nvidia.conf`). The guest's
value is independent and can be set to `1` if the guest OS uses hibernate.

### Gotcha 4 — Do Not Access BAR0 via `/dev/mem` When IOMMU Active

Even after enabling memory decode in the PCIe config space, accessing BAR0 via `/dev/mem`
when `iommu=pt` is active causes an IOMMU fault → PCIe Unsupported Request (UR) error →
GPU removed from PCIe bus ("fallen off the bus"). Symptom: `lspci` no longer shows the GPU.

Recovery without reboot:
```bash
echo 1 > /sys/bus/pci/devices/0000:03:00.0/remove
echo 1 > /sys/bus/pci/rescan
```

Use `lspci -vv -s 0000:03:00.0` for capability inspection instead of `/dev/mem`.

### Gotcha 5 — `rombar=0` vs `rombar=1`

Linux guests using nvidia-open do not read the VBIOS ROM BAR — GSP firmware comes from the
driver package (`/lib/firmware/nvidia/`). `rombar=0` avoids mapping an unnecessary BAR and
prevents spurious ROM BAR enable cycles that can confuse the GPU at init. **Windows guests
also work with `rombar=0` — confirmed with RTX 5070 + Windows 11 + standard NVIDIA Game
Ready Driver.** `rombar=1` is not needed for either Linux or Windows on Blackwell.

### Gotcha 6 — WPR2 Register Reference (Diagnostic, Read-Only)

For debugging only — **do not write to this register**:

| Item | Value (RTX 5070 GB205) |
|------|------------------------|
| BAR0 base | `0xe0000000` (32-bit, 64 MiB) |
| WPR2 register offset | `0x110094` |
| WPR2 physical address | `0xe0110094` |
| Pre-arm sentinel (bad state) | `0xbadf4100` |
| After clean GSP init + rmmod | `0x00000000` |
| After BIOS GSP init (valid) | Non-zero firmware signature |

---

## Capability Verification

```bash
# On the VM (Linux guest):
nvidia-smi --query-gpu=name,driver_version,memory.total,temperature.gpu \
           --format=csv,noheader
# Expected for RTX 5070:
# NVIDIA GeForce RTX 5070, 595.71.05, 12227 MiB, 39
```

| Metric | Expected (RTX 5070 GB205) |
|--------|---------------------------|
| GPU Name | NVIDIA GeForce RTX 5070 |
| Driver Version | 595.71.05 or newer |
| CUDA Version | 13.2 |
| Total VRAM | 12 227 MiB |
| Open modules required | Yes (host and Linux guest — Windows uses standard driver) |
| WPR2 state at VM start | 0 (cleared via GSP full init — confirmed across multiple reboots) |

---

## Known Limitations

| Feature | Status | Notes |
|---------|--------|-------|
| HD Audio companion (`00.1`) in VM | ❌ Excluded by design | Required for FLR workaround — see §Why Audio is Excluded |
| VM stop/start without host reboot | ✅ Supported | FLR keeps WPR2 = 0 across cycles |
| Windows guest | ✅ Confirmed | Works with `rombar=0` (no `rombar=1` needed), no `x-vga=1` required. Anti-cheat: add `kvm=off,hv_vendor_id=GenuineIntel` in CPU args. Looking Glass supported. |
| D3cold recovery after host crash | ❌ Not available on most platforms | PCIe power gating unsupported in standard slots; requires PSU-off cycle |
| `vendor-reset` module | Not needed | FLR path prevents the reset bug entirely |

---

## What's NOT the Fix

| Tried | Outcome |
|-------|--------|
| `kvm=off` / `-hypervisor` CPUID flags | Not needed for the passthrough to work. Useful for Windows gaming VMs to bypass anti-cheat detection (Valorant, EAC) — not a passthrough requirement |
| `vendor-reset` DKMS module | Not needed — FLR path prevents the reset bug |
| `romfile=<vbios.bin>` | Not needed for Linux or Windows guest |
| `ids=10de:2f04,10de:2f80` in `vfio.conf` | Actively harmful — blocks handoff script from loading nvidia |
| Passing both `00.0` + `00.1` to VM | Enables SBR path → PERST# → WPR2 re-armed → `RmInitAdapter` fails |
| `pci=noaer` | Reduces log noise but not required for functionality |
| Accessing BAR0 via `/dev/mem` to read WPR2 | Causes IOMMU fault; GPU falls off bus |

---

## Appendix: Server Platform Notes — HPE ProLiant DL380 Gen10 Plus

> This appendix documents platform-specific BIOS and kernel configuration required when
> running this recipe on HPE ProLiant DL380 Gen10 Plus servers. Standard desktop and
> workstation motherboards generally do not need these steps.

### Hardware Context

- Server: HPE ProLiant DL380 Gen10 Plus
- Firmware management: iLO 5
- GPU slot: PCIe Gen4 ×16 (Slot 5 in validated configuration)
- PCIe topology:
  ```
  Intel Ice Lake Root Port A  (0000:02:02.0)
    ├─ 0000:03:00.0  RTX 5070 GB205  [10de:2f04]  → IOMMU group N     (GPU, alone)
    └─ 0000:03:00.1  HD Audio        [10de:2f80]  → IOMMU group N+1   (Audio, alone)
  ```

### Required BIOS Settings

#### PostVideoSupport = DisplayAllAvailable  ⚠️ Critical

**Why**: The HP ProLiant BIOS defaults to `VideoOnly`, which does not execute PCIe option
ROMs for add-in GPUs during POST. Without VBIOS execution, the GPU's FSP does not complete
GSP initialization at power-on: WPR2 remains `0xbadf4100` after POST.

`DisplayAllAvailable` instructs the BIOS to execute all available video option ROMs — the
GPU VBIOS runs, GSP boots, and WPR2 is left in a valid signed state. This enables the
BIOS WPR2 fallback path (§Gotcha 2) in case Phase 2 of the handoff script cannot complete.

Configure via iLO Redfish API (replace IP and credentials with your values — sanitize before
sharing):

```bash
curl -sk -X PATCH \
  -H "Content-Type: application/json" \
  -u "<ilo-user>:<ilo-password>" \
  "https://<ilo-ip>/redfish/v1/Systems/1/Bios/Settings" \
  -d '{"Attributes":{"PostVideoSupport":"DisplayAllAvailable"}}'
# Settings are pending — apply with a full server restart
```

UEFI setup menu equivalent:
**System Configuration → BIOS/Platform Configuration (RBSU) → Video Options →
POST Video Support → All Available Video Devices**

#### PciSlot5OptionROM = Enabled

Allows execution of the GPU option ROM from PCIe Slot 5 during POST. Without this, BIOS
ignores the VBIOS even with `DisplayAllAvailable` set.

```bash
curl -sk -X PATCH \
  -H "Content-Type: application/json" \
  -u "<ilo-user>:<ilo-password>" \
  "https://<ilo-ip>/redfish/v1/Systems/1/Bios/Settings" \
  -d '{"Attributes":{"PciSlot5OptionROM":"Enabled"}}'
```

#### PciSlot5Aspm = Disabled

Disable Active State Power Management for the GPU slot. ASPM L1/L1.2 link transitions
can cause PCIe link retraining events on Blackwell that trigger spurious PERST# under load.

```bash
curl -sk -X PATCH \
  -H "Content-Type: application/json" \
  -u "<ilo-user>:<ilo-password>" \
  "https://<ilo-ip>/redfish/v1/Systems/1/Bios/Settings" \
  -d '{"Attributes":{"PciSlot5Aspm":"Disabled"}}'
```

#### Apply All Three at Once

```bash
curl -sk -X PATCH \
  -H "Content-Type: application/json" \
  -u "<ilo-user>:<ilo-password>" \
  "https://<ilo-ip>/redfish/v1/Systems/1/Bios/Settings" \
  -d '{
    "Attributes": {
      "PostVideoSupport":  "DisplayAllAvailable",
      "PciSlot5OptionROM": "Enabled",
      "PciSlot5Aspm":      "Disabled"
    }
  }'
```

Verify pending settings:
```bash
curl -sk -u "<ilo-user>:<ilo-password>" \
  "https://<ilo-ip>/redfish/v1/Systems/1/Bios/Settings" \
  | python3 -m json.tool \
  | grep -A1 -E "PostVideo|PciSlot5"
# Expected:
# "PostVideoSupport":  "DisplayAllAvailable",
# "PciSlot5OptionROM": "Enabled",
# "PciSlot5Aspm":      "Disabled",
```

Restart via Redfish:
```bash
curl -sk -X POST \
  -H "Content-Type: application/json" \
  -u "<ilo-user>:<ilo-password>" \
  "https://<ilo-ip>/redfish/v1/Systems/1/Actions/ComputerSystem.Reset" \
  -d '{"ResetType":"ForceRestart"}'
```

> **iLO settings lag**: BIOS settings applied via Redfish are "Pending" until the next
> full server restart. `/redfish/v1/Systems/1/Bios` (no trailing `/Settings`) shows the
> currently active values; `/redfish/v1/Systems/1/Bios/Settings` shows pending.

### Extended GRUB Cmdline (DL380 Gen10 Plus Specific)

In addition to the standard Proxmox IOMMU parameters, the DL380 Gen10 Plus requires:

```
intel_iommu=on,relax_rmrr iommu=pt pcie_acs_override=downstream,multifunction
vfio_iommu_type1.allow_unsafe_interrupts=1 pcie_port_pm=off pci=noaer
pci=realloc pci=hpmemsize=1G,hpiosize=0
```

| Extra parameter | Reason on DL380 Gen10 Plus |
|-----------------|---------------------------|
| `intel_iommu=on,relax_rmrr` | HP UEFI registers RMRR (Reserved Memory Region Reporting) entries for BMC/iLO devices; `relax_rmrr` prevents IOMMU from blocking passthrough of unrelated devices in the same RMRR range |
| `pci=noaer` | Suppresses AER (Advanced Error Reporting) interrupts generated by the GPU slot during vfio-pci bind/unbind cycles — reduces log noise without masking real errors |
| `pci=realloc` | Forces kernel to reallocate PCIe BARs — required when BIOS under-allocates the 64 MiB BAR0 + 8 GiB BAR1 for Blackwell |
| `pci=hpmemsize=1G,hpiosize=0` | Extends the PCIe hotplug memory window to 1 GiB for correct large-BAR allocation under HP's firmware |

### DL380 Gen10 Plus Known Limitations

| Issue | Notes |
|-------|-------|
| ReBAR not negotiated by default | HP UEFI may not advertise Resizable BAR to the OS. Check: `lspci -vv -s 0000:03:00.0 \| grep -i "bar\|memory"`. If BAR0 is 64 MiB and BAR1 is absent, ReBAR is not active. Enable via BIOS: **PCIe Resizable BAR Support → Enabled** |
| D3cold unavailable | DL380 PCIe slots do not support D3cold power gating. Recovery from a crashed-VM GPU state requires a full PSU-off cycle, not just OS reboot |
| PCIe Gen speed | DL380 Gen10 Plus PCIe Gen4 ×16 slots may negotiate at Gen3 under default power profile. Set **PCIe Maximum Link Speed → PCIe Gen 4 Speed** in BIOS if you observe reduced GPU bandwidth |
| Slot numbering | The `PciSlotN` BIOS attribute number matches the physical slot label on the server backplane. Use `lspci -vv` to correlate the GPU BDF to the physical slot, then adjust `PciSlot5` references accordingly if your GPU is in a different slot |
