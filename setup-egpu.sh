#!/usr/bin/env bash
# One-time eGPU stabilization setup for the AORUS RTX 5060 Ti AI BOX.
# Fixes three verified crash causes:
#   1. BAR window too small over Thunderbolt -> grow hotplug MMIO windows (kernel cmdline)
#   2. GSP firmware hard-lock on power-state change -> pin GPU power, disable ASPM/link PM
#   3. nouveau grabbing the GPU before the NVIDIA driver -> blacklist (initramfs-safe)
# Also blacklists nvidia_drm/nvidia_modeset: compute-only box, desktop never touches it.
set -euo pipefail

echo "== 1/5 modprobe configuration =="
cat > /etc/modprobe.d/zz-egpu.conf <<'EOF'
blacklist nouveau
alias nouveau off
blacklist nvidia_drm
blacklist nvidia_modeset
options nvidia NVreg_DynamicPowerManagement=0x00
options nvidia NVreg_RegistryDwords="RMSetDynamicPowerManagement=0;PowerMizerEnable=0x1;PerfLevelSrc=0x2222;PowerMizerDefaultAC=0x1;"
EOF
echo "wrote /etc/modprobe.d/zz-egpu.conf"

echo "== 2/5 kernel cmdline =="
if grep -q 'hpmmioprefsize' /etc/default/grub; then
  echo "already patched, skipping"
else
  sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"/GRUB_CMDLINE_LINUX_DEFAULT="quiet splash pci=realloc pci=assign-busses,hpbussize=0x33,hpmmiosize=64M,hpmmioprefsize=384M pcie_aspm=off pcie_port_pm=off iommu=pt thunderbolt.clx=0"/' /etc/default/grub
fi
grep GRUB_CMDLINE_LINUX_DEFAULT /etc/default/grub

echo "== 3/5 update-grub =="
update-grub

echo "== 4/5 update-initramfs =="
update-initramfs -u

echo "== 5/5 persistence daemon =="
systemctl enable nvidia-persistenced

echo
echo "Done. Next steps:"
echo "  1. Shut down the laptop COMPLETELY (power off, not restart)."
echo "  2. Connect the AI BOX to the Thunderbolt port."
echo "  3. Power on and log in."
echo "  4. Run:  nvidia-smi | head -20"
echo "     and:  dmesg | grep -iE 'nvidia|xid|thunderbolt' | tail -30"
