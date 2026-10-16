# LOG — completed work

Newest first. Open items live in `TODO.md`; the eGPU system changes,
stabilization record and undo commands live in `EGPU.md`.

## 2026-10-17

- **Coldplug revival matrix completed — all negative.** Tested on a
  coldplug-dead GPU: bolt policy `manual` (the BIOS creates the PCIe
  tunnel at POST regardless — the GPU enumerates on the PCI bus even
  unauthorized), secondary bus reset via Bridge Control (0x3e bit 6) on
  the JHL9480 downstream port 02:00.0, and a root-port hot reset of
  00:01.1. BARs stay zero / function stays dead. Conclusion: the wedge
  state lives laptop-side (POST-established) and only the
  clean-POST-without-box ritual avoids it. Remaining theories, queued for
  one coldplug boot: `NVreg_GspRmMemInitTimeoutMs=20000`, and blocking
  `snd_hda_intel` from the GPU audio function (its D0/D3 power pokes
  seconds after boot — "Unable to change power state ... device
  boot): BARs still zero — **coldplug closed**. Every revival and
  prevention avenue is exhausted; the wedge is POST-level and laptop-side.
  Long-term fix is upstream only: a PCI reset-method quirk for the
  JHL9480/Blackwell chain, or an NVIDIA early-enumeration fix
  (open-gpu-kernel-modules #979 / forum thread 365386). The
  `NVreg_GspRmMemInitTimeoutMs=20000` line stays in
  nvidia-tunnel-fix.conf (harmless insurance on healthy boots).
- **5 Hz modprobe storm found and fixed (udev `nvidia-uvm` dependency
  loop)**: `71-nvidia.rules` modprobes `nvidia-uvm` on every driver
  add-event; the dependency load of `nvidia` ignores blacklists; a failed
  probe (module init returns ENODEV, `nv.c:1041`) unloads the module,
  re-fires the rule, repeat — 44,226 failed probes in one boot, starting
  3 s after a coldplug POST. Fixed with `install nvidia /bin/true` +
  `install nvidia_uvm /bin/true` in `/etc/modprobe.d/zz-egpu.conf` and
  `--ignore-install` loads in `egpu-bringup.sh`. Verified dead (zero
  failures; udev worker gone).
- **Coldplug tested properly for the first time** (with the storm fixed):
  no POST hang, chain Gen4 x4, kernel assigns all BARs at boot (16 GB
  BAR1) — but the GPU function is MMIO-dead ("fallen off the bus") in
  every variant: runtime remove+rescan (BAR registers restored, MMIO not),
  FLR, box power-cycles, NHI rebind, cable replug, fresh boot. Decoded
  `could not insert 'nvidia': No such device`: module init returns ENODEV
  when zero devices initialize (`nv.c:1041-1047`) — a probe-failure
  symptom, not a load-path/config bug (verified: identical dmesg before
  and after our config changes, params unchanged). Boot-with-box remains
  unusable; boot-without-box + cable + bring-up is the only working path.
- **Recovery law corrected** (user challenge + controlled tests): "box
  power-cycle (PSU out 2-3 min) revives it" was never true alone; every
  real recovery coincided with a laptop restart. The only reliable
  recovery is: reboot the laptop with the box detached, connect after
  boot. EGPU.md updated (new facet 4, corrected recovery paragraph).
- **Strata engine calibrated** (`--calibrate`, 20 min): the defaults are
  already the fastest on this box — the engine's own PCIe share (~0.11),
  spec-min-p (0.5), 11 pool workers and default expert tier beat every
  candidate (45 tok/s in the calibration's own measurement; the documented
  "+3-7%" is for weaker CPUs/links). Nothing changed; the result is recorded
  in Strata's settings store so reinstalls keep it. No re-run needed.
- **Maya/GLM calibrated** (`./maya.sh --calibrate`, 19 min): same outcome —
  the engine's own settings are the fastest (9.2 tok/s). Nothing changed.
- **eGPU bring-up upgraded** (`egpu-bringup.sh`, a la Damian's
  blackwell-egpu-manager): chain-wide ASPM/L1-substate stripping (root port
  00:01.1 + both JHL9480 bridges + GPU), a garbage-BAR gate (exit 3) and a
  no-PCIe-capability gate (exit 4) BEFORE any modprobe, and a read-only
  `--status` mode. See EGPU.md "Stabilization record".
- **"Fourth wedge facet" debunked — a read-permission artifact.** A morning
  of "64-byte config space on the whole chain" (plus moot box power-cycles,
  remove/rescans and an NHI unbind/rebind) traced to the kernel's 20-year-old
  sysfs gate: `pci_read_config()` caps unprivileged readers at the 64-byte
  standard header (no CAP_SYS_ADMIN), on every PCI device, host-side
  included. The identical reads worked the day before because the bring-up
  ran under sudo. Lesson recorded in EGPU.md ("Read-privilege trap"):
  config-space inspection always runs with sudo; `wc -c` = 64 as non-root
  is normal, NOT a wedge.
- **Box firmware investigation closed**: no firmware exists anywhere —
  GIGABYTE's support page only ever published the Windows driver and the
  AI TOP Utility Lite (an Electron GUI, no flashing capability), LVFS/fwupd
  has nothing, the NVIDIA UEFI tool is Windows-only and inapplicable. The
  bridge (Intel JHL9480) is not the problem per community consensus; the
  instability is host-side. No box flash possible or needed.
- **Stonking apt source + pin removed** (`egpu-undo.sh undo-stonking-repo`,
  fixed the same day to also remove the deb822 `.sources` name apt migrated
  it to during the 26.10 upgrade). The duplicate-source warnings are gone.

## 2026-10-16

- **run.sh aibox false "not connected" fixed**: root cause was
  `set -o pipefail` + `lspci | grep -q` (grep -q exits on first match →
  SIGPIPE → lspci dies with 141 → pipeline fails). lspci output is now
  captured to a variable before the match.
- **Strata CPU vision enabled** (`--vision cpu` + `build-vision` encoder):
  image test passed; config kept at `--max-context 262144` with
  `--vram-reserve-mib 700` (setup's 64k recommendation was over-conservative;
  verified a 57k-token prompt + image at flat ~15.7 GB VRAM).
- **GLM-5.3-Flash via Project Maya evaluated and kept** (details and numbers:
  README). Strata PRs #1420/#1476 ("GLM under Strata") were evaluated and
  are NOT pursued: draft quality, older engine code than Maya, conflicts
  with the stage-11 display blocking.
- **Third wedge facet recorded** (garbage/zero BARs with a healthy-looking
  link after the 12:33 hard crash; the box's reboot button did not clear it):
  EGPU.md "Stabilization record".
- **All three GLM shards SHA-256 verified** against the hashes in
  `runtime/maya/maya.py`.
