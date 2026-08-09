# Example: NVIDIA RTX 2000 Ada Passthrough

Proxmox VM configuration for the NVIDIA RTX 2000 Ada (Professional / Workstation, Ada-Generation, 16 GB GDDR6 ECC) passed through to an Ubuntu 24.04 guest for ML inference.

> **Status**: ✅ **Production** — promoted 2026-08-09. In production since 2026-05-11 (PaddleOCR GPU inference); ≥2-week uptime threshold ([CONTRIBUTING.md § 1](../../CONTRIBUTING.md#1-no-vendor-recipe-without-2-weeks-production)) cleared 2026-05-25. Shares a host with the [RTX PRO 4500 Blackwell](../nvidia-rtx-pro-4500-blackwell/) (installed 2026-05-15); both cards confirmed in simultaneous operation, with per-container GPU isolation documented in [docs/vendors/nvidia-professional.md](../../docs/vendors/nvidia-professional.md).

## What This Recipe Covers

This repo's rule is **no vendor recipe without ≥2 weeks of production validation on real hardware** (see [CONTRIBUTING.md](../../CONTRIBUTING.md)). That threshold is met: the config below has been carrying an ML-inference workload continuously since 2026-05-11.

What is confirmed and documented here: the config shape, the PCI IDs of GPU and audio companion, the single-line multi-function `hostpci` form, the driver branch, and the fact that **no** hypervisor-hiding is needed. The measurements listed under *Open verification items* below are not part of that — they are unpublished, not unmet.

**Ada-generation caveat, easy to miss**: like Blackwell, Ada Lovelace on the `595` driver branch requires the **open** kernel modules (`nvidia-driver-595-server-open`). The closed variant fails with `RmInitAdapter`. See [TROUBLESHOOTING.md](../../docs/TROUBLESHOOTING.md#nvidia-smi-reports-no-devices-found-linux-guest--blackwell--ada).

## Confirmed Config Shape

Validated on Proxmox VE 9.1.1 / kernel 6.17.2-1-pve, AMD Ryzen 9 9900X host, Ubuntu 24.04 guest:

```
args: (none -- Pro cards do NOT need kvm=off / -hypervisor)
machine: q35
bios: ovmf
cpu: host
balloon: 0
vga: none
hostpci0: 0000:02:00,pcie=1
```

Notes on the config:
- **No function suffix on `hostpci0`**: `0000:02:00` (without `.0`) attaches all functions at once — GPU (`02:00.0`, `10de:28b0`) + audio companion (`02:00.1`, `10de:22be`) in a single line.
- **`vga: none`**: headless VM (RDP/SSH access). If you need noVNC fallback, use `--vga virtio` alongside the hostpci entry.
- **`cpu: host`**: mandatory for CUDA workloads (AVX2, AVX-512). `x86-64-v3` is insufficient.
- **`balloon: 0`**: required with any GPU passthrough; the balloon driver's memory paging is incompatible with DMA from the passed-through device.

Key difference vs the Intel Arc example: **no `-hypervisor` flag**. NVIDIA Pro drivers expect to see KVM. Hiding the hypervisor would disable vGPU features and confuse the enterprise driver.

## Confirmed in production

1. Driver install on the NVIDIA RTX Enterprise branch — `nvidia-driver-595-server-open`, CUDA 13.2, `nvidia-smi` working inside a Docker container via nvidia-container-toolkit 1.19.0
2. Sustained ML-inference workload since 2026-05-11 (smaller models, fp16 / int8 inference, classical CV — the 16 GB headroom covers model + activations + KV cache; larger models go to the PRO 4500 Blackwell sibling card)
3. Simultaneous operation with the PRO 4500 Blackwell in the same host, per-container GPU assignment via `NVIDIA_VISIBLE_DEVICES`

## Open verification items

Not blockers for the passthrough recipe — these are measurements that have not been taken and published yet:

1. ECC memory status (`nvidia-smi -q -d ECC`)
2. CUDA compute benchmarks (`nvcc` sample: deviceQuery, bandwidthTest)
3. NVENC session capability (no Consumer session limit expected on Pro cards)

## Tracking

- Open issue with label `vendor:nvidia-pro` when Code 43 / init issues encountered
- Vendor doc: [../../docs/vendors/nvidia-professional.md](../../docs/vendors/nvidia-professional.md)

## See Also

- [../intel-arc-a310/](../intel-arc-a310/) — Validated Intel Arc example (contrast: hypervisor-hiding required; also serves as Consumer-tier reference)
- [../nvidia-rtx-pro-4500-blackwell/](../nvidia-rtx-pro-4500-blackwell/) — Sibling Pro card in the same workstation (Blackwell-generation, 32 GB)
- [../nvidia-consumer-blackwell/](../nvidia-consumer-blackwell/) — Backlog stub for NVIDIA-GeForce-specific quirks (not in main table)
- [../../docs/vendors/nvidia-professional.md](../../docs/vendors/nvidia-professional.md) — Vendor doc covering both Pro cards
- [../../CONTRIBUTING.md](../../CONTRIBUTING.md) — ≥2-week-uptime rule for promotion to Production

---

*Contributors: if you run RTX A2000 / A4000 / A5000 / RTX 4000 Ada / 5000 Ada / 6000 Ada in Proxmox passthrough, a recipe for your card is welcome — see [CONTRIBUTING.md](../../CONTRIBUTING.md). Professional-card recipes are underrepresented in open-source GPU-passthrough docs.*
