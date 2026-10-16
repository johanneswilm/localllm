#!/usr/bin/env bash
# Stage 11: stop gnome-shell freezing when the eGPU driver loads.
#
# Mechanism (observed 2026-10-14): /lib/udev/rules.d/71-nvidia.rules runs
# `modprobe nvidia-modeset` and `modprobe nvidia-drm` the moment the nvidia
# driver binds. Blacklists do NOT stop an explicit modprobe, so nvidia-drm
# initialized, created /dev/dri/card0+renderD129, and gnome-shell hotplugged
# the eGPU as a secondary GPU -> frozen session, logout to gdm.
#
# Fix: `install <module> /bin/true` turns any modprobe of these modules into
# a silent no-op. The desktop can then never see an nvidia DRM device.
# Compute (nvidia.ko + nvidia-uvm) is unaffected.
# Run as root: sudo bash setup-egpu-stage11.sh
set -euo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "== 1/3 block modeset/drm at the modprobe level =="
cat > /etc/modprobe.d/zz-egpu.conf <<'EOF'
# eGPU compute-only setup.
# Nothing may touch the GPU during boot; egpu-bringup.sh brings it up after
# the cable is connected (link pin, then explicit module load).
blacklist nvidia
blacklist nvidia_uvm
blacklist nvidia_drm
blacklist nvidia_modeset
# nvidia's udev rule 71-nvidia.rules explicitly modprobes nvidia-modeset and
# nvidia-drm when the driver binds; a blacklist cannot stop that (this froze
# gnome-shell on 2026-10-14). The install directive no-ops any such attempt.
install nvidia_modeset /bin/true
install nvidia_drm /bin/true
# once loaded: no dynamic power management, stay at max performance
options nvidia NVreg_DynamicPowerManagement=0x00
options nvidia NVreg_RegistryDwords="RMSetDynamicPowerManagement=0;PowerMizerEnable=0x1;PerfLevelSrc=0x2222;PowerMizerDefaultAC=0x1;"
EOF

echo "== 2/3 try to unload drm/modeset now (fails if the desktop holds fds - fine, reboot clears) =="
modprobe -r nvidia_drm 2>/dev/null && echo "nvidia_drm unloaded" || echo "nvidia_drm still in use - will clear on reboot"
modprobe -r nvidia_modeset 2>/dev/null && echo "nvidia_modeset unloaded" || echo "nvidia_modeset still in use - will clear on reboot"

echo "== 3/3 verify the block works =="
if modprobe -n -v nvidia_drm 2>&1 | grep -q 'true'; then
  echo "OK: modprobe nvidia_drm is now a no-op"
else
  echo "WARN: block not effective, check /etc/modprobe.d/zz-egpu.conf"
fi

cat <<EOF

Done. NEXT: reboot, then the Phase-1 flow again:
  1. boot (box disconnected), log in
  2. connect Thunderbolt, sudo bash "$REPO_DIR/egpu-bringup.sh" --gen4
  3. expect: no freeze, desktop stays up, nvidia-smi works
Then Phase 2: boot with the box attached (tests coldplug + shutdown wedge).
EOF
