# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Planned
- Extend `collect-diagnostics.sh` sanitizer to mask IPv4/IPv6, hardware/BIOS UUIDs, and usernames in paths — once enough real-world diag bundles surface the common patterns.
- Publish the outstanding NVIDIA Pro measurements: ECC status (`nvidia-smi -q -d ECC`), CUDA/NVENC benchmarks (both cards), and — Blackwell-specific — full 32 GB BAR exposure and PCIe 5.0 link width under sustained load.
- `vendor-reset` installation guide for Blackwell WPR2 reset bug — once Blackwell support in `gnif/vendor-reset` is confirmed.

## [1.2.2] — 2026-08-09

### Changed
- **`README.md`, `docs/vendors/nvidia-professional.md`, `examples/nvidia-rtx-2000-ada/README.md`, `examples/nvidia-rtx-pro-4500-blackwell/README.md`: both NVIDIA Pro cards promoted 🚧 In validation → ✅ Production (2026-08-09).** RTX 2000 Ada has carried a PaddleOCR GPU-inference workload since 2026-05-11 (≥2-week threshold cleared 2026-05-25); RTX PRO 4500 Blackwell has carried an Ollama VLM workload since 2026-05-15 (threshold cleared 2026-05-29). Status updated in all five places per card: GPU table, roadmap, documentation table, vendor doc, example README.
- `README.md` roadmap: removed the two target-promotion dates (2026-05-25, 2026-05-29), which had been in the past for eleven weeks while the entries still read "full recipe after threshold". Replaced by the actual production-since dates and the remaining open items.
- `docs/vendors/nvidia-professional.md`: status block now states explicitly what "Production" covers here — passthrough recipe, PCI IDs, IOMMU placement, `vfio.conf`, mandatory open kernel modules, dual-GPU operation — and what it does not: the unpublished measurements, and the WPR2 reset bug as a known unfixed defect. "Anticipated Test Plan" replaced by a validation path marking step 5 (capability probe) as the one item still open.
- `examples/nvidia-rtx-2000-ada/README.md`, `examples/nvidia-rtx-pro-4500-blackwell/README.md`: rewritten from placeholder framing ("will land here once…") to recipes. Each now separates *Confirmed in production* from *Open verification items*; the Blackwell example gained a dedicated "Known Open Defect" section for the WPR2 reset bug so the promotion does not bury it. The Ada example gained the open-kernel-module caveat, which applies to Ada Lovelace on the `595` branch and not only to Blackwell.

### Fixed
- **`examples/intel-arc-a310/README.md`: status still read 🚧 In validation with a promotion date of 2026-05-04**, while `README.md` and `docs/vendors/intel-arc-dg2.md` had said ✅ Production since v1.2.1. The fifth status location was missed in that release — the same class of omission v1.2.0 already recorded for the RTX PRO 4500. Now ✅ Production, promoted 2026-05-15.
- `examples/nvidia-rtx-2000-ada/README.md`: dropped the stale "will share a host with the RTX PRO 4500 Blackwell once that card is installed" — the card was installed 2026-05-15 and simultaneous dual-GPU operation was already documented in v1.2.0.
- **Three broken heading anchors** into `docs/TROUBLESHOOTING.md` § *nvidia-smi Reports "No devices found"* — in `docs/vendors/nvidia-professional.md`, `examples/nvidia-rtx-2000-ada/README.md` and `examples/nvidia-rtx-pro-4500-blackwell/README.md`. The heading contains an em dash (`Linux Guest — Blackwell / Ada`), which GitHub's slug algorithm collapses into a **double** hyphen (`…linux-guest--blackwell--ada`); the three links carried a single one. Only `README.md` had the correct form. The `markdown-links` CI job does not validate URL fragments, so CI stayed green over these.
- `docs/HOST_SETUP.md`: vendor-doc list still marked `nvidia-professional.md` as 🚧.

## [1.2.1] — 2026-07-26

### Changed
- Intel Arc A310: promoted from 🚧 In validation → ✅ Production (2026-05-15 — ≥2-week uptime confirmed). Status updated in `README.md`, `docs/vendors/intel-arc-dg2.md`, and documentation table.
- `README.md` roadmap: both NVIDIA entries moved from "planned" to in-validation with the actual workloads (PaddleOCR GPU on RTX 2000 Ada, Ollama VLM on RTX PRO 4500 Blackwell), open items (WPR2 reset, ReBAR on the full 32 GB BAR, PCIe 5.0 link training) and target promotion dates.
- `README.md` documentation table: `nvidia-professional` "planned" → "in validation, dual-GPU confirmed"; `intel-arc-dg2` 🚧 → ✅; TROUBLESHOOTING scope line extended by WPR2 reset and the open-module requirement.
- `README.md` "The One Thing Most Guides Miss" → "The Things Most Guides Miss": added the NVIDIA Blackwell/Ada open-module finding and the WPR2 reset bug alongside the existing Intel Arc entry.

## [1.2.0] — 2026-05-15

### Added
- `docs/TROUBLESHOOTING.md`: new section "NVIDIA Blackwell: GPU Failed to Initialize on Second VM Start (WPR2 Reset Bug)" — root cause (GSP firmware WPR2 persists through PCIe FLR), contrast with AMD Reset Bug (comparison table), short-term fix (host reboot), long-term fix pointer (`vendor-reset`).
- `docs/vendors/nvidia-professional.md`: new subsection "Confirmed: Dual GPU to Same Linux VM — Docker Container Isolation" — documents `NVIDIA_VISIBLE_DEVICES` per-container GPU assignment, passthrough order (`hostpci1` → GPU 0), verification commands, WPR2 cross-reference. Confirmed 2026-05-15 with RTX PRO 4500 + RTX 2000 Ada in simultaneous production operation.

### Changed
- `docs/vendors/nvidia-professional.md`, RTX 2000 Ada: driver corrected to `nvidia-driver-595-server-open` (open kernel modules required for Ada Lovelace on this driver branch — same requirement as Blackwell, not only Blackwell as previously implied); added dual-GPU-confirmed note; added `qm set` / `vfio.conf` independence gotcha.
- `README.md`: RTX PRO 4500 Blackwell status corrected from `🚧 Planned` to `🚧 In validation` with hardware details — this promotion was done in v1.1.0 but the README table was not updated.

## [1.1.0] — 2026-05-15

### Added
- `docs/TROUBLESHOOTING.md`: new section "nvidia-smi Reports 'No devices found'
  (Linux Guest — Blackwell / Ada)" — root cause (closed-source kernel modules do not
  support Blackwell/Ada Lovelace), fix (`nvidia-driver-<VERSION>-server-open` or
  `-open` variant), affected architectures, and live VFIO bind technique via
  `new_id` (when device IDs are unknown to the already-loaded module instance).

### Changed
- RTX 2000 Ada (`docs/vendors/nvidia-professional.md`, `examples/nvidia-rtx-2000-ada/README.md`,
  `README.md`): status Planned → In validation (first hardware session 2026-05-11).
  Confirmed vendor:device IDs (`10de:28b0` GPU, `10de:22be` audio companion),
  CUDA compute 8.9, driver branch `nvidia-driver-595-server`. Documented Ubuntu 24.04
  gotcha: `nvidia-container-toolkit` is absent from standard apt repos — NVIDIA's own
  apt repository (`nvidia.github.io/libnvidia-container`) is required.
- RTX PRO 4500 Blackwell (`examples/nvidia-rtx-pro-4500-blackwell/README.md`,
  `docs/vendors/nvidia-professional.md`): status Planned → In validation (first hardware
  session 2026-05-15). Confirmed vendor:device IDs (`10de:2c31` GPU, `10de:22e9` audio
  companion), clean IOMMU group (AMD Raphael/Granite Ridge, group isolated to GPU +
  audio companion only), config shape validated on Proxmox VE 9.1.1 / kernel
  6.17.2-1-pve host, Ubuntu 24.04 guest (kernel 6.8.0-111-generic). Critical
  Blackwell finding: open kernel modules mandatory — `nvidia-driver-595-server`
  (closed) fails with `RmInitAdapter (0x22:0x56:1017)`; fix is
  `nvidia-driver-595-server-open`. Audio companion had `snd_hda_intel` bound on
  first boot; `softdep snd_hda_intel pre: vfio-pci` in `modprobe.d` prevents
  recurrence.

## [1.0.0] — 2026-04-21

Initial public release.

### Added
- Repository structure (scripts, docs, examples, CI)
- **Intel Arc A310 (DG2) recipe** — full Code-43 fix with CPUID mechanics (🚧 in validation, promotes to ✅ on 2026-05-04)
  - QEMU args: `kvm=off`, `-hypervisor`, `hv_vendor_id=GenuineIntel`, `hv_relaxed`, `hv_spinlocks=0x1fff`
  - Failure-mode documentation: `E_NOINTERFACE` → `STATUS_UNSUCCESSFUL` → OK evolution
  - INF gotcha: `iigd_dch_d.inf` (DG2-discrete) vs `iigd_dch.inf` (iGPU) distinction
  - Vulkan ICD manual registration (pnputil skips it)
- **Host setup scripts** — `enable-iommu.sh` (auto-detects GRUB vs. proxmox-boot-tool), `bind-vfio.sh`, `check-vfio-binding.sh`, `check-iommu-groups.sh`
- **Vendor-aware CPU-args generator** (`generate-vm-args.sh`) — dual-mode (raw args for `qm set --args`, or `--as-config-line` for config-file paste); `--explain` mode for pedagogy; profiles for intel-arc, nvidia-consumer, nvidia-pro, amd
- **Reset-method hookscript** template (`hookscripts/reset-method.sh`) + installer (`install-reset-hook.sh`)
- **Windows guest capability probe** (`capability-probe.ps1`) — DXGI-based VRAM detection (avoids the 32-bit WMI cap), Vulkan ICD registry check, DirectX feature levels, NVENC/QSV/AMF detection
- **Diagnostic bundler** (`collect-diagnostics.sh`) with auto-sanitization disclaimer
- **Vendor stubs** for NVIDIA Pro (RTX 2000 Ada + RTX PRO 4500 Blackwell, planned), NVIDIA Consumer (backlog — Intel Arc A310 already covers Consumer-tier), AMD (backlog)
- **Cluster support** — `RESOURCE_MAPPINGS.md` for Proxmox VE 8+ HA / migration scenarios
- **Troubleshooting matrix** (symptom → vendor → root cause → fix)
- **CI** — shellcheck (severity=warning) + bash-syntax + markdown-link-check via GitHub Actions
- **Release automation** via `release.yml` workflow (extracts CHANGELOG section on tag push)
