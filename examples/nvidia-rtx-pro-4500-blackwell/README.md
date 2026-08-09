# Example: NVIDIA RTX PRO 4500 Blackwell Passthrough

Proxmox VM configuration for the NVIDIA RTX PRO 4500 Blackwell (Professional / Workstation, Blackwell silicon, 32 GB GDDR7 ECC) passed through to an Ubuntu 24.04 guest for ML inference.

> **Status**: ✅ **Production** — promoted 2026-08-09. In production since 2026-05-15 under real ML inference (Ollama VLM, qwen3-vl:8b-instruct-q8_0); ≥2-week uptime threshold ([CONTRIBUTING.md § 1](../../CONTRIBUTING.md#1-no-vendor-recipe-without-2-weeks-production)) cleared 2026-05-29.
>
> **Read the WPR2 reset bug below before you rely on this in a stop/start workflow.** It is unfixed, and the only known workaround is a host reboot.

## What This Recipe Covers

This repo's rule is **no vendor recipe without ≥2 weeks of production validation on real hardware** (see [CONTRIBUTING.md](../../CONTRIBUTING.md)). That threshold is met: the config below has been carrying an Ollama VLM workload continuously since 2026-05-15.

What is confirmed and documented here: the mandatory open-kernel-module requirement, the config shape, PCI IDs of GPU and audio companion, the clean IOMMU group, the `vfio.conf` including the `snd_hda_intel` softdep, and the live-bind technique via `new_id`. Two Blackwell-specific measurements remain open — see *Open verification items* at the end; neither blocks the passthrough itself.

## ⚠️ Blackwell Critical: Open Kernel Modules Required

**The most important Blackwell-specific finding before anything else:**

Blackwell GPUs (GB2xx/GB3xx — including the RTX PRO 4500 GB203GL) **do not work with the proprietary NVIDIA kernel modules**. If you install the standard closed-source driver package (`nvidia-driver-XXX-server` on Ubuntu, or any non-open variant), you will see:

```
NVRM: The NVIDIA GPU 0000:02:00.0 (PCI ID: 10de:2c31)
NVRM: installed in this system requires use of the NVIDIA open kernel modules.
NVRM: GPU 0000:02:00.0: RmInitAdapter failed! (0x22:0x56:1017)
NVRM: GPU 0000:02:00.0: rm_init_adapter failed, device minor number 0
```

`nvidia-smi` will report `No devices found` even though the kernel module is loaded. The fix:

```bash
# Ubuntu 24.04 — install the open kernel module variant
sudo apt install nvidia-driver-595-server-open
# (replaces nvidia-driver-595-server; DKMS builds the open module automatically)

# Unload old closed modules, load new open ones (or just reboot the VM)
sudo modprobe -r nvidia_uvm nvidia_drm nvidia_modeset nvidia
sudo modprobe nvidia
```

This requirement applies to **all** Blackwell GPUs in Linux guests, not just Pro cards. The open kernel modules (`nvidia-open`) have been mandatory for Ada Lovelace and newer since NVIDIA deprecated proprietary modules for those architectures.

See also: [TROUBLESHOOTING.md § nvidia-smi reports "No devices found"](../../docs/TROUBLESHOOTING.md#nvidia-smi-reports-no-devices-found-linux-guest--blackwell--ada).

## Confirmed Config Shape

Validated on Proxmox VE 9.1.1 / kernel 6.17.2-1-pve, AMD Ryzen 9 9900X host, Ubuntu 24.04 guest (kernel 6.8.0-111-generic):

```
args: (none -- Pro cards do NOT need kvm=off / -hypervisor)
machine: q35
bios: ovmf
cpu: host
balloon: 32768
vga: none
hostpci1: 0000:01:00,pcie=1
```

Notes on the config:
- **`hostpci1` not `hostpci0`**: In this setup `hostpci0` was already in use (NVMe passthrough). The index is arbitrary — use whatever slot is free.
- **No function suffix**: `0000:01:00` (without `.0`) attaches all functions — GPU (`01:00.0`, `10de:2c31`) + audio companion (`01:00.1`, `10de:22e9`) — in a single line.
- **No `x-vga`**: Card is used headless for ML inference. `x-vga=0` is implicit (and default) when `vga: none` is set.
- **`cpu: host`**: mandatory for CUDA workloads.
- **No extra `-cpu` flags**: Pro cards expect to see KVM. Do not apply Consumer Code-43 workarounds.

Guest-side driver: `nvidia-driver-595-server-open`, nvidia-container-toolkit 1.19.0, CUDA 13.2.

## Confirmed Hardware IDs

| Function | PCI ID | Description |
|----------|--------|-------------|
| GPU | `10de:2c31` | GB203GL — RTX PRO 4500 Blackwell |
| Audio | `10de:22e9` | NVIDIA Blackwell HD Audio companion |

IOMMU group (AMD Ryzen 9 9900X / Granite Ridge platform): **clean isolated group**, GPU + audio companion only. No other devices share the group.

## vfio.conf

```
# /etc/modprobe.d/vfio.conf
options vfio-pci ids=10de:2c31,10de:22e9
softdep snd_hda_intel pre: vfio-pci
softdep nouveau pre: vfio-pci
```

**Audio companion note**: the audio companion (`10de:22e9`) had `snd_hda_intel` bound on first boot. The `softdep snd_hda_intel pre: vfio-pci` line prevents this on subsequent boots. For a live bind without reboot:

```bash
echo 0000:01:00.1 > /sys/bus/pci/drivers/snd_hda_intel/unbind
# If the GPU IDs aren't yet known to the running vfio-pci module:
echo "10de 2c31" > /sys/bus/pci/drivers/vfio-pci/new_id
echo "10de 22e9" > /sys/bus/pci/drivers/vfio-pci/new_id
# Verify
for dev in 0000:01:00.0 0000:01:00.1; do
  echo "$dev → $(basename $(readlink /sys/bus/pci/devices/$dev/driver))"
done
```

Note: `echo <BDF> > /sys/bus/pci/drivers/vfio-pci/bind` fails with "No such device" if the device ID was not known to the running module instance (the IDs in `/etc/modprobe.d/vfio.conf` are only parsed at module load time). Use `new_id` for the live case.

## Why This Card Is Interesting (Beyond "It's a Pro Card")

The PRO 4500 Blackwell sits at an unusual intersection:

- **Architecturally Pro** → `nvidia-pro` profile applies. No `kvm=off`, no `-hypervisor`. The driver expects KVM visible.
- **Silicon-wise Blackwell** → it inherits Consumer-Blackwell-class issues that the Ada-Pro RTX 2000 doesn't have. Specifically:
  - **ReBAR negotiation on a full 32 GB BAR** — mainboard BIOS must map the entire 32 GB BAR through the PCIe hierarchy. Small-memory-map BIOSes silently fall back to a 256 MB BAR with a brutal perf hit. Verify with `lspci -vv -s <BDF>` — the BAR line should show full 32 GB, not the truncated fallback.
  - **PCIe 5.0 link training** — host slot must negotiate full PCIe 5.0 x16 and stay there under load. Some host/board combos drop to PCIe 4.0 / 3.0 thermally. Check `lspci -vv` `LnkSta:` during sustained inference.
  - **GDDR7 ECC** — `nvidia-smi -q -d ECC` should show ECC supported and on (Pro default).

This makes it a **useful contrast** to both the Ada-Pro RTX 2000 (same driver branch, different silicon-era quirks) and the Consumer-Blackwell stub (same silicon, different driver branch).

## Confirmed in production

1. Driver install on the NVIDIA RTX Enterprise branch — `nvidia-driver-595-server-open` (the **open** modules are mandatory, see above), CUDA 13.2, `nvidia-smi` working inside a Docker container via nvidia-container-toolkit 1.19.0
2. Sustained ML-inference workload since 2026-05-15 — Ollama VLM serving (qwen3-vl:8b-instruct-q8_0, with qwen3-vl:32b-instruct-q4_K_M pre-loaded)
3. Simultaneous operation with the RTX 2000 Ada in the same host, per-container GPU assignment via `NVIDIA_VISIBLE_DEVICES`
4. Clean isolated IOMMU group on the AMD Granite Ridge platform — GPU + audio companion only

## Open verification items

These are unmeasured, not failed. They do not block the passthrough recipe, but a Blackwell card is exactly where they can bite:

1. Full BAR exposed — `lspci -vv -s <BDF>` should show the whole 32 GB BAR, not a truncated 256 MB fallback
2. PCIe 5.0 x16 link width sustained under load (`lspci -vv` `LnkSta:` during inference)
3. ECC memory active (`nvidia-smi -q -d ECC`)
4. CUDA compute benchmarks (`nvcc` sample: deviceQuery, bandwidthTest)
5. NVENC session capability (no Consumer per-process session cap expected on Pro cards)

## Known Open Defect

The **WPR2 reset bug** is unfixed: the GPU does not survive a VM stop/start cycle without a full host reboot, because PCIe FLR does not reset the GSP firmware's WPR2 state. This hits on the *second* VM boot, not the first — a successful first boot is a false signal. Full write-up and the comparison against the AMD Reset Bug: [TROUBLESHOOTING.md § WPR2 Reset Bug](../../docs/TROUBLESHOOTING.md#nvidia-blackwell-gpu-failed-to-initialize-on-second-vm-start-wpr2-reset-bug). A `vendor-reset`-based long-term fix depends on Blackwell support landing in `gnif/vendor-reset`.

## Two-Card-One-Host Considerations

This card shares a workstation with the RTX 2000 Ada. See [../../docs/vendors/nvidia-professional.md § Two-Card-One-Host Considerations](../../docs/vendors/nvidia-professional.md#two-card-one-host-considerations) for IOMMU group placement, slot routing, TDP budget, and thermal coupling notes.

## Tracking

- Open issue with label `vendor:nvidia-pro-blackwell` when init / ReBAR / link-training issues encountered
- Vendor doc: [../../docs/vendors/nvidia-professional.md](../../docs/vendors/nvidia-professional.md)

## See Also

- [../intel-arc-a310/](../intel-arc-a310/) — Validated Intel Arc example (contrast: hypervisor-hiding required)
- [../nvidia-rtx-2000-ada/](../nvidia-rtx-2000-ada/) — Sibling Ada-Pro recipe (same Pro driver branch, older silicon)
- [../nvidia-consumer-blackwell/](../nvidia-consumer-blackwell/) — Consumer-Blackwell stub (same silicon family, different driver branch)
- [../../docs/vendors/nvidia-professional.md](../../docs/vendors/nvidia-professional.md) — Vendor doc for both Pro cards
- [../../CONTRIBUTING.md](../../CONTRIBUTING.md) — ≥2-week-uptime rule for promotion to Production

---

*Contributors: if you run any other RTX PRO Blackwell variant (PRO 4000 / 5000 / 6000 Blackwell) in Proxmox passthrough, a recipe for your card is welcome — see [CONTRIBUTING.md](../../CONTRIBUTING.md). Pro-Blackwell recipes are close to absent from open-source GPU-passthrough docs.*
