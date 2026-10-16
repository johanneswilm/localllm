#!/usr/bin/env bash
# Stage 8: make the desktop (GUI) work alongside the eGPU.
#
# Root cause of the "graphical login conflicts with the AMD GPU and reboots":
# the desktop compositor (KDE/GDM) initializes the NVIDIA eGPU as a display
# device via nvidia-modeset/nvidia-drm. Traffic over the USB4/TB tunnel then
# kills the GPU -> crash/reboot at login.
#
# Fix: CUDA compute does NOT need nvidia-modeset/nvidia-drm. Blacklist those
# two so the display stack can never touch the box, while nvidia.ko +
# nvidia-uvm stay loaded for CUDA. The internal AMD iGPU drives the desktop
# alone. This is the standard headless-compute eGPU setup.
#
# Safe to re-run. Run as root: sudo bash setup-egpu-stage8-graphics.sh
set -euo pipefail

echo "== 1/5 ensure nvidia core modules (NOT modeset/drm) + stability options =="
cat > /etc/modprobe.d/zz-egpu.conf <<'EOF'
# eGPU compute-only setup: keep nvidia.ko/nvidia-uvm for CUDA,
# keep nvidia_modeset/nvidia_drm OUT so the desktop stack cannot grab the box.
blacklist nvidia_drm
blacklist nvidia_modeset
options nvidia NVreg_DynamicPowerManagement=0x00
EOF

echo "== 2/5 desktop default target = graphical, gdm3 enabled =="
systemctl set-default graphical.target
systemctl enable gdm3

echo "== 3/5 refresh initramfs (blacklists must exist at early boot) =="
update-initramfs -u

echo "== 4/5 refresh grub =="
update-grub

echo "== 5/5 current GRUB default line (verify: no 'recovery', no 'nomodeset') =="
grep '^GRUB_CMDLINE_LINUX' /etc/default/grub || true

cat <<'EOF'

Done. NEXT STEPS (user):
  1. Reboot normally (no GRUB editing). Let it boot into GDM.
  2. Log in on the internal display.
  3. Then verify the box is still compute-ready:
       nvidia-smi | head -12
     Expect: RTX 5060 Ti visible, desktop running, no crash.

If it still crashes at login, capture logs from the boot after the crash:
  journalctl -b -1 --no-pager | grep -iE 'nvidia|amdgpu|xid|reset' | tail -40
EOF
