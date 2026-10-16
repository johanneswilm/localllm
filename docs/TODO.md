# TODO — open items only

For completed work see `LOG.md`. For the eGPU system changes, stabilization
record and undo commands see `EGPU.md`.

## eGPU (AORUS RTX 5060 Ti AI BOX)

- Booting with the box attached still fails (2026-10-17, probe storm
  fixed): no POST hang, perfect enumeration, kernel assigns all BARs at
  boot — but the GPU function is MMIO-dead ("fallen off the bus") and
  survives box power-cycles, FLR, NHI rebind, cable replug and a fresh
  boot. Manual bring-up after connecting the cable remains the workflow
  (`./run.sh aibox`). Next research step: full config-space diff between
  coldplug-dead and hotplug-alive.
- ~~Verify the first manual bring-up with the new `install` blocks +
  `--ignore-install` combo~~ verified 2026-10-17 13:42: `RESULT: bring-up
  complete`, GPU P0 Gen4 x4.
- Neutralize `/usr/lib/modprobe.d/nvidia-runtimepm.conf` (ships
  `options nvidia "NVreg_DynamicPowerManagement=0x02"`; our `0x00` in
  zz-egpu.conf wins by file order only — rename it or align the value).
- ~~Next coldplug experiment~~ CLOSED 2026-10-17: `NVreg_GspRmMemInitTimeoutMs=20000`
  + `module_blacklist=snd_hda_intel` in one boot, GPU given 45 s of peace —
  BARs still zero. Coldplug is exhausted (EGPU.md facet 4); upstream fix
  only (PCI reset-method quirk for the JHL9480 chain, or an NVIDIA
  early-enumeration fix). Boot-without-box ritual stands.
- Optional: install `egpu-coldplug.sh` + `egpu-coldplug.service` (in this
  repo) to auto-normalize zero-BAR coldplug enumerations at boot — fixes
  the BAR symptom only, not a MMIO-dead GPU.
- Do NOT apply the upstream eGPU patch `NVreg_ForceExternalGpu` (PR #984,
  AUR nvidia-open-egpu): tested negative on identical hardware (AORUS box +
  TB4 host, open-gpu-kernel-modules issue #979). Our modprobe options cover
  its mechanism. Revisit only if a driver newer than 615.78 lands in the
  Ubuntu repos with eGPU fixes (checklist: EGPU.md "When a newer NVIDIA
  driver arrives").
- Box firmware: none exists (investigated 2026-10-17, LOG.md). If GIGABYTE
  ever publishes a Barlow Ridge NVM update, flash it from a STABLE link only.

## llama.cpp speculative decoding (MTP)

- qwen3.8-27b: works; the draft sits on CPU at 64k ctx because VRAM is full.
  At 16k ctx it should fit on the GPU again (~39 t/s measured at 4k) — retest.
- qwen3.8-flash-next (arch `qwen4exp`): `--spec-type draft-mtp` still aborts
  during draft init (re-tested 2026-10-14, llama.cpp master 411d5485).
  Do not enable; retest when
  https://github.com/ggml-org/llama.cpp/issues/27741 is fixed.

## Hardware / system

- External monitor: HDMI expansion card dead on this host (works on old
  laptop), DisplayPort works. Suspected host-side PD/alt-mode issue; revisit
  after a BIOS update.
- `virtualbox-dkms` was purged (cannot build on kernel 7.3); reinstall when
  back on 7.0 kernels if still needed.

## Optional ideas (not pursued)

- Vulkan build for the Radeon 890M iGPU: moot while the eGPU works; the CPU
  build remains the fallback.
- Strata vs llama.cpp quality comparison on flash-next (Strata is not
  bit-identical; UD-Q4_K_XL matches llama.cpp top token 97.5-99%).
- Strata `--api-key` before exposing beyond localhost; `--idle-unload` if
  sharing VRAM with the llama.cpp stack.
- Maya-S24 variant (~+14% decode) if GLM becomes a daily driver;
  `./maya.sh --calibrate` result: LOG.md.
