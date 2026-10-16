# AORUS RTX 5060 Ti AI BOX — system changes & how to undo them

Everything the eGPU setup changed on the system, in one place, with the exact
revert commands. Verified against the live system on 2026-10-14; the
2026-10-17 storm fix and coldplug findings are in the Stabilization record.

**Snapshot of the working state (2026-10-14):** kernel `7.3.0-9-generic`,
NVIDIA driver `615.71.09-open` (DKMS, unpatched since the 26.10 upgrade —
the §2 patch is historical), CUDA 13.4,
box up at Gen4 x4 / P0, desktop on the AMD iGPU, monitor via DisplayPort.
Daily bring-up is one command: `./run.sh aibox` (wraps `egpu-bringup.sh`
via sudo; safe to re-run — it no-ops when the driver is already up).
`egpu-bringup.sh --status` (read-only; use **sudo** — unprivileged config
reads get the 64-byte header only, see the read-privilege trap above) dumps
the whole Thunderbolt chain: ids, link speed, ASPM, L1 substates, BARs —
run it first when the box misbehaves.

An executable version of most of these steps is `egpu-undo.sh` (run with
`sudo`). Read this file first so you know what each step re-enables.

---

## Stabilization record — what works, what failed, wedge facets

Status: **stable under load** since 2026-10-14 with the bring-up in
`egpu-bringup.sh` (verified: 81 s sustained CUDA bench, then hours of use;
since also: two full engine calibrations, 20+ min at 100 % GPU).

What failed before (do not retry blindly):
- plain coldplug of `nvidia` at boot: probe fails ("fallen off the bus") or the
  box hard-locks the machine under any CUDA/graphical load
- drivers 595.99.02 and 615.71.09: identical behavior
- kernels 7.0.0-38 and 7.3.0-9: identical behavior
- Gen3 link pin after driver load: no effect (link flap kills a live driver)
- blacklisting only nvidia_drm/nvidia_modeset: not sufficient (load crashes)
- auto-bring-up via systemd at boot (`setup-egpu-stage9-linkpin.sh`):
  blind setpci on a wedged box + modprobe regardless = 164 probe errors
  spamming the console. Replaced by manual `egpu-bringup.sh`.

Winning recipe (from NVIDIA forum thread 365386 / nikomiiller + damianbienias32):
1. blacklist ALL nvidia modules at boot (`/etc/modprobe.d/zz-egpu.conf`)
2. after connecting the cable: pin ASPM off + L1 substates off + Gen4 target +
   retrain on the whole chain (root port 00:01.1, both JHL9480 bridges, GPU —
   the script does this), verify negotiated speed
3. only then `modprobe nvidia nvidia_uvm`, then `nvidia-smi -pm 1` (P0 pin via
   `NVreg_RegistryDwords` in the same modprobe file)
4. kernel cmdline: `quiet splash pcie_aspm=off pcie_port_pm=off iommu=pt
   loglevel=2` (in `/etc/default/grub`; `thunderbolt.clx=0` was tried and
   commented back out — see §6)

Wedge facets (the box degrades on unclean events; all observed live):
1. **Classic**: config space reads 0xFFFF, or the link flaps at 2.5 GT/s x1.
2. **Dead port**: Thunderbolt Router 1's USB-C port hard-crashed the laptop
   (coil whine then shutdown). Only use Router 0's port.
3. **Garbage/dead BARs (2026-10-16)**: box enumerates normally (link Gen4
   x4) but BAR registers return garbage/zero -> no memory BARs ->
   `modprobe nvidia` fails with "PCI I/O region ... is invalid", and
   `nvidia-persistenced` restart-storms (8.8k starts in one boot) with a
   stuck modprobe at ~60 % CPU (hot laptop). The box's own "reboot" button
   did NOT clear it.
4. **Coldplug function death (2026-10-17)**: booting with the box attached
   no longer hangs POST (it did on 2026-10-14), and enumeration is perfect
   — whole chain Gen4 x4, kernel assigns every BAR including the 16 GB
   BAR1. But the GPU *function* comes up MMIO-dead: config space answers
   (IDs, PCIe caps, BAR offsets), device-side BAR writes do not stick, and
   every driver probe logs "fallen off the bus and is not responding to
   commands" (probe error -1; module init then returns ENODEV — modprobe's
   `could not insert 'nvidia': No such device` — which per `nv.c:1041-1047`
   of the driver source only means "zero devices initialized", NOT a
   missing or config-broken module). Ruled OUT as revival routes on
   2026-10-17: the probe storm (fixed below), runtime remove+rescan
   (restores the BAR registers but not MMIO), FLR via sysfs reset, box
   power-cycles (incl. full PSU drain + cable replug), NHI unbind/rebind, a
   fresh boot with the storm already fixed, bolt policy change (the BIOS
   creates the PCIe tunnel at POST, below bolt's authority — the GPU
   enumerates even with the stored device set to `manual`), secondary bus
   reset via Bridge Control on 02:00.0, a root-port hot reset of 00:01.1,
   the `NVreg_GspRmMemInitTimeoutMs=20000` option, and blocking
   `snd_hda_intel` from the GPU audio function (boot-time D3 power-poke
   theory; tested with the storm fixed and 45 s of probe-free peace). The
   ONLY recovery is the original ritual: reboot the laptop with the box
   DETACHED, connect the cable after boot, run the bring-up.

Correction to earlier claims: "a box power-cycle (PSU out 2-3 min) revives
it" was never true on its own — every past recovery coincided with a
laptop restart (user eyewitness over months + today's controlled tests).
A wedged box is un-wedged by resetting the LAPTOP side, not the box.

The 5 Hz modprobe storm (2026-10-17) — found, explained, fixed:
nvidia's udev rule (`/lib/udev/rules.d/71-nvidia.rules`) runs
`/sbin/modprobe nvidia-uvm` whenever the nvidia driver registers.
`nvidia-uvm` DEPENDS on `nvidia`, and modprobe resolves dependencies
IGNORING blacklists — so the rule silently loads `nvidia` too. When the
probe fails (any facet above), module init returns ENODEV, the module
auto-unloads, the driver's register/unregister uevents re-fire the rule,
and the cycle repeats at ~5 Hz — 44,226 failed probes in one boot. At
coldplug it started 3 s after POST and likely helped wedge the freshly
powered GPU (its GSP firmware was still booting). Blacklists cannot stop
this; `install` lines can: `install nvidia /bin/true` + `install nvidia_uvm
/bin/true` in `zz-egpu.conf` (same trick as the modeset/drm pair, §3).
`egpu-bringup.sh` loads with `modprobe --ignore-install` to bypass its own
block. Verified: storm dead, boot quiet, no auto-probes.

Read-privilege trap (NOT a wedge, but looks identical): the kernel caps
sysfs config reads at the 64-byte standard header for non-root readers
(`pci_read_config()`, hardcoded `size = 64` without CAP_SYS_ADMIN — ~20
years old). So without sudo: `wc -c /sys/bus/pci/devices/*/config` = 64,
capability reads EOF at 0x40, `lspci -v` shows "Capabilities: <access
denied>" — on EVERY PCI device, host-side ones included. On 2026-10-17 this
was misread as a "fourth wedge facet" and cost a day of moot box
power-cycles. Rule: any config-space inspection (`--status`, BAR reads, cap
walks) runs with sudo; as root, `wc -c` = 4096 and EOF/0xFFFF at 0x00 is a
REAL dead device.

Diagnose: `sudo bash egpu-bringup.sh --status` (whole chain: ids, link,
ASPM, L1 substates, BARs). Recovery in all facets: stop the engines, `sudo
rmmod nvidia_uvm nvidia` (desktop apps like the DING extension / GTK apps
hold `/dev/nvidia0` open — `gnome-extensions disable ding@rastersoft.com`
first), then **reboot the laptop with the box detached** and connect the
cable only after boot (`./run.sh aibox`). A box power-cycle alone has never
been observed to fix anything; the box's reboot button least of all.

`egpu-bringup.sh`: chain-wide ASPM/L1-substate stripping, a garbage-BAR
gate and a no-PCIe-capability gate (exit 3/4) BEFORE any modprobe, verified
link speed, modprobe (`--ignore-install`, see the storm note above) with
one bounce-retry, P0 pin. Flags: `--gen3|--gen4` (target), `--pin-only`,
`--status` (read-only; sudo recommended).

GUI + eGPU coexist (stage 11 + 2026-10-17): blacklisting is NOT enough —
nvidia's udev rules explicitly modprobe nvidia-modeset/nvidia-drm when the
driver binds, and the nvidia-uvm rule pulls nvidia in as a dependency; a
loaded nvidia-drm made gnome-shell hotplug the box and freeze the session
(2026-10-14). Fix in `/etc/modprobe.d/zz-egpu.conf`: `install` no-op lines
for nvidia_modeset + nvidia_drm (2026-10-14) and nvidia + nvidia_uvm
(2026-10-17, the storm fix). Desktop stays on the AMD iGPU; CUDA works
under the desktop (verified with llama-bench).

The only source patch ever applied is the kernel-7.3 dmem build fix inside
the 615.71.09 DKMS tree (§2); it dies automatically on any driver
upgrade/reinstall.

## 1. NVIDIA driver: 615-open instead of 595-open

- Installed: `nvidia-driver-615-open` + its stack (`nvidia-dkms-615-open`,
  `nvidia-kernel-source-615-open`, `nvidia-utils-615`, `libnvidia-*-615`,
  `xserver-xorg-video-nvidia-615`, ...). All from the Ubuntu 26.04 repos.
- Replaced: `nvidia-driver-595-open` (still `rc` on the system — removed but
  config files kept, so it restores cleanly).
- **Undo:** `sudo apt install nvidia-driver-595-open` (apt will swap the
  stacks). Nothing else references 615.

## 2. DKMS source patch (build fix for kernel 7.3 — the ONLY source patch)

- Problem: 615.71.09 fails to build on kernel 7.3 because
  `dmem_cgroup_register_region()` gained a new `struct dmem_cgroup_init`
  argument.
- Applied by `setup-egpu-stage6-nvidia-dkms-fix.sh` **directly into**
  `/usr/src/nvidia-615.71.09/nvidia/os-interface.c` (guarded by
  `#if LINUX_VERSION_CODE >= KERNEL_VERSION(7, 3, 0)`, so it is inert on 7.0
  kernels; those build the original code path).
- **Undo:** nothing to do manually — the patch lives *inside the 615.71.09
  DKMS source tree*, so any driver upgrade or reinstall wipes it:
  `sudo apt install --reinstall nvidia-kernel-source-615-open` restores the
  pristine file and rebuilds. When a newer driver (e.g. upstream 615.78.08,
  or an Ubuntu build that supports 7.3 out of the box) arrives, just upgrade.
- DKMS currently has nvidia built for `7.0.0-30`, `7.0.0-38`, `7.3.0-9`.

**Update 2026-10-16 (Ubuntu 26.10 upgrade):** as designed, the upgrade wiped
the locally patched `os-interface.c` (distro source `615.71.09-0ubuntu1` took
over). The new source calls `dmem_cgroup_register_region(size, name)` (2-arg)
and builds on kernel 7.3.0-9.9 **without any patch** — DKMS rebuilt
`nvidia.ko` during the upgrade (visible as the `09:23` mtime in
`updates/dkms/`) and the driver runs unpatched. §2 is now historical; a
`--reinstall` no longer loses a needed fix.

## 3. `/etc/modprobe.d/zz-egpu.conf` — the core compute-only config

Created by `setup-egpu-stage11.sh` (superseding stage 8/9 versions). Content:

- `blacklist nvidia / nvidia_uvm / nvidia_drm / nvidia_modeset` — nothing
  auto-loads by alias at boot. (Blacklists do NOT cover dependency loads —
  see the install bullets below and the storm note in the Stabilization
  record.)
- `install nvidia_modeset /bin/true` + `install nvidia_drm /bin/true` —
  nvidia's udev rule (`/lib/udev/rules.d/71-nvidia.rules`) explicitly
  modprobes these when the driver binds; a blacklist cannot stop that, and
  when nvidia-drm initialized, gnome-shell hotplugged the eGPU and froze the
  session (2026-10-14). This turns those loads into no-ops.
- `install nvidia /bin/true` + `install nvidia_uvm /bin/true`
  (2026-10-17) — the udev rule's `modprobe nvidia-uvm` pulls `nvidia` in as
  a dependency (dependency loads ignore blacklists), and on a failed probe
  the load/unload cycle re-fires the rule at ~5 Hz forever (44k probes in
  one boot). The install no-ops stop that; the bring-up script loads
  explicitly with `--ignore-install`.
- Footgun: `/usr/lib/modprobe.d/nvidia-runtimepm.conf` (ships with the
  driver deb) sets `options nvidia "NVreg_DynamicPowerManagement=0x02"`.
  zz-egpu.conf's `0x00` wins by file order today, but rename or align that
  file when next touching modprobe config (TODO.md).
- `options nvidia NVreg_DynamicPowerManagement=0x00` and
  `NVreg_RegistryDwords="RMSetDynamicPowerManagement=0;PowerMizerEnable=0x1;
  PerfLevelSrc=0x2222;PowerMizerDefaultAC=0x1;"` — no runtime power
  management, pinned to max performance (the crash trigger was link
  speed/ASPM transitions while the driver is live).

**Undo:** `sudo rm /etc/modprobe.d/zz-egpu.conf && sudo update-initramfs -u`
then reboot. Consequence: nvidia loads at boot again and the display stack
touches the box — on the current driver that reintroduces the crashes
documented in `TODO.md`. Only do this to test a driver that claims a fix.

## 4. `/etc/modprobe.d/nvidia-tunnel-fix.conf` — experiment leftover

- From the stage 3/4 era. Only active line: `options nvidia
  NVreg_EnableResizableBar=0` (the rest is commented). Harmless, superseded
  by §3's options. **Undo:** `sudo rm /etc/modprobe.d/nvidia-tunnel-fix.conf`

## 5. `/etc/modprobe.d/nvidia-graphics-drivers-kms.conf` — hand-modified

- Ships with the driver but was edited during the headless era: active lines
  are `options nvidia_drm modeset=0 fbdev=0` (stock: `modeset=1`).
- Currently **inert** (§3 blocks nvidia_drm entirely), but restore it if you
  ever revert §3:
  `sudo sed -i 's/^options nvidia_drm modeset=0 fbdev=0/options nvidia_drm modeset=1/' /etc/modprobe.d/nvidia-graphics-drivers-kms.conf`
  (or `sudo apt install --reinstall nvidia-driver-615-open` to regenerate).

## 6. Kernel cmdline (`/etc/default/grub`)

- Stock Ubuntu: `GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"`
- Current active line:
  `GRUB_CMDLINE_LINUX_DEFAULT="quiet splash pcie_aspm=off pcie_port_pm=off iommu=pt loglevel=2"`
  (`thunderbolt.clx=0` was tested earlier, currently commented out;
  `loglevel=2` only suppresses console kernel-spam from a wedged box).
- **Undo:** set it back to `"quiet splash"`, then `sudo update-grub`.
  The register-level link pin in `egpu-bringup.sh` may make the params
  redundant — but that is UNVERIFIED; test before dropping them.

## 7. Kernel 7.3.0-9 (from Ubuntu stonking / 26.10)

- Installed by `setup-egpu-stage5b-stonking-kernel.sh` via a temporary apt
  source. Packages now on the system:
  `linux-image-unsigned-7.3.0-9-generic`, `linux-modules-7.3.0-9-generic`,
  `linux-headers-7.3.0-9-generic`, `linux-main-modules-zfs-7.3.0-9-generic`,
  `linux-main-modules-v4l2loopback-7.3.0-9-generic`, plus the cross-release
  dependency `libssl4` (4.0.3).
- Boot fallback: `linux-image-7.0.0-38-generic` (and -30) still installed;
  pick it in GRUB → Advanced options.
- The temporary apt source + pin were removed 2026-10-17 via
  `egpu-undo.sh undo-stonking-repo` (nothing references them anymore).
- **Full kernel undo:** after rebooting into 7.0.0-38:
  `sudo apt purge 'linux-*-7.3.0-9*' libssl4` (+ `sudo apt autoremove`).
  Note: 7.3.0-9 image is *unsigned*; Secure Boot must stay **off** to boot it
  (it is off now; `mokutil --sb-state`).

## 8. systemd units

- **`egpu-down.service`** (enabled; installed by `setup-egpu-stage10.sh`):
  detaches the GPU from the PCI bus during shutdown so the box doesn't wedge.
  **Undo:** `sudo systemctl disable egpu-down.service && sudo rm /etc/systemd/system/egpu-down.service && sudo systemctl daemon-reload`
- **`egpu-up.service`** + `/usr/local/sbin/egpu-up.sh` (both DISABLED, files
  left over from the abandoned stage-9 auto bring-up; nothing references
  them). **Undo/cleanup:** `sudo rm /etc/systemd/system/egpu-up.service /usr/local/sbin/egpu-up.sh /var/log/egpu-up.log && sudo systemctl daemon-reload`
  (remove egpu-down.service first if you want the box config fully gone).
- Default target is `graphical.target` (stock; was temporarily `multi-user`
  during bring-up).

## 9. virtualbox-dkms — purged

- `setup-egpu-stage6` purged it because virtualbox 7.2.6 can't build on
  kernel 7.3, which blocked `dpkg --configure -a`.
- **Undo:** `sudo apt install virtualbox-dkms` (builds fine on 7.0 kernels;
  leave it out while booting 7.3).

## 10. CUDA 13.4 (NVIDIA repo)

- Added `/etc/apt/sources.list.d/cuda-ubuntu2604-x86_64.list` + package
  `cuda-keyring`; installed `cuda-toolkit-13-4` into `/usr/local/cuda`.
  Needed to build llama.cpp for Blackwell (sm_120).
- **Undo (optional):** `sudo apt purge cuda-toolkit-13-4 'cuda-*-13-4'
  cuda-keyring && sudo rm /etc/apt/sources.list.d/cuda-ubuntu2604-x86_64.list`

## 11. Not changes (for completeness)

- **bolt**: the box is stored/authorized with policy `iommu` — stock
  Thunderbolt behavior, nothing custom.
- **User-space only** (delete to remove, touches nothing system-wide):
  `runtime/strata`, `runtime/Strata-data`, `runtime/llama.cpp/build-cuda`,
  `models/`, and the scripts in this repo.
- **`nvidia-persistenced.service`** is enabled (stock static unit; harmless
  with or without the box).

---

## When a newer NVIDIA driver arrives (checklist)

1. Check the upstream tracker first:
   [open-gpu-kernel-modules #979](https://github.com/NVIDIA/open-gpu-kernel-modules/issues/979)
   (the umbrella issue for this bug class) and the
   [AORUS AI BOX forum thread](https://forums.developer.nvidia.com/t/rtx-5060-ti-egpu-aorus-ai-box-cuda-hard-lock-on-linux-via-thunderbolt-4/365386).
2. Upgrade the driver (`sudo apt update && sudo apt install nvidia-driver-6xx-open`).
   The §2 dmem patch dies with the old source tree; a new driver may also
   need its own 7.3 build fix — check `dkms status` before rebooting.
3. Re-test in this order (each step is a reboot + `sudo bash egpu-bringup.sh --gen4`):
   a. current config (blacklists + manual bring-up) — must still work;
   b. **boot with the box attached** — tested 2026-10-17 with the storm
      fixed: no POST hang, perfect enumeration, kernel assigns all BARs —
      but the GPU function is still MMIO-dead at the first probe ("fallen
      off the bus"). Still the open question on a NEWER driver; if
      `nvidia-smi` works after a boot-attached start, the driver fixed the
      early-enumeration path;
   c. only if (b) works: remove `zz-egpu.conf` (`egpu-undo.sh undo-modprobe`)
      and let the display stack touch the box. If any step crashes the
      machine: power-cycle the box (PSU 30 s) before the next attempt.
4. If reverting, `sudo bash egpu-undo.sh status` first to see what's applied.

The 615.78.08 diff and the `NVreg_ForceExternalGpu` (PR #984) investigation
(2026-10-14) are summarized in TODO.md's open items: no eGPU fixes in 615.78,
patch tested negative on identical hardware — do not apply either.

## External monitor — current status (2026-10-14)

- **Working:** external monitor via **DisplayPort** (different cable than
  the HDMI one).
- **Dead:** the Framework HDMI expansion card gives no signal on THIS
  laptop — from the very first boot screen. The same HDMI cable + monitor
  work on the old laptop; all USB-C DP-alt-mode paths on this host show
  "disconnected" in `/sys/class/drm`. Ruled out: kernel 7.3 (worked
  yesterday on 7.3), kernel cmdline (reverted, no change), eGPU bandwidth
  (one dead boot had the box fully disconnected).
- No software change was made for this; it is suspected to be host-side
  (port/PD negotiation or BIOS/EC level). Revisit after a BIOS update or the
  26.10 upgrade; the ThinkPad dock's DP path is a second workaround.
