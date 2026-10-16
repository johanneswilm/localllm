#!/usr/bin/env bash
# Stage 9: stop the crash-under-load by pinning the PCIe link before the
# NVIDIA driver ever sees the GPU.
#
# Root cause (per NVIDIA forum thread 365386, open-gpu-kernel-modules #979):
# the eGPU dies when the link changes speed (Gen3<->Gen4 flap) or enters an
# ASPM/L1 state while the driver is active. Fix:
#   1. blacklist ALL nvidia modules at boot -> nothing touches the GPU early
#   2. a oneshot service pins the link (ASPM off, L1 substates off,
#      target speed, retrain) on GPU + both JHL9480 bridges
#   3. then loads nvidia and pins P0 (persistence + RM registry dwords)
#
# Safe to re-run. Run as root: sudo bash setup-egpu-stage9-linkpin.sh
set -euo pipefail

echo "== 1/6 kernel cmdline: ASPM off, port PM off, passthrough IOMMU =="
sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="quiet splash pcie_aspm=off pcie_port_pm=off iommu=pt thunderbolt.clx=0"/' /etc/default/grub
grep '^GRUB_CMDLINE_LINUX_DEFAULT' /etc/default/grub

echo "== 2/6 modprobe: blacklist all nvidia at boot + P0 registry pins =="
cat > /etc/modprobe.d/zz-egpu.conf <<'EOF'
# eGPU: nothing may touch the GPU during boot. egpu-up.service brings the
# link up (pinned speed, ASPM off) and then loads nvidia explicitly.
blacklist nvidia
blacklist nvidia_uvm
blacklist nvidia_drm
blacklist nvidia_modeset
# once loaded: no dynamic power management, stay at max performance
options nvidia NVreg_DynamicPowerManagement=0x00
options nvidia NVreg_RegistryDwords="RMSetDynamicPowerManagement=0;PowerMizerEnable=0x1;PerfLevelSrc=0x2222;PowerMizerDefaultAC=0x1;"
EOF

echo "== 3/6 retire older experiments =="
systemctl disable egpu-load.service 2>/dev/null && rm -f /etc/systemd/system/egpu-load.service /usr/local/sbin/egpu-load.sh && systemctl daemon-reload || true

echo "== 4/6 egpu-up bring-up script =="
cat > /usr/local/sbin/egpu-up.sh <<'EOF'
#!/usr/bin/env bash
# Pin eGPU link, then load NVIDIA driver. Logs to /var/log/egpu-up.log.
exec >>/var/log/egpu-up.log 2>&1
set -ux

GPU=03:00.0
BRIDGES="01:00.0 02:00.0"

# wait for the device (up to 60s)
for i in $(seq 1 60); do
  [ -e /sys/bus/pci/devices/0000:$GPU ] && break
  sleep 1
done
if [ ! -e /sys/bus/pci/devices/0000:$GPU ]; then
  echo "FAIL: $GPU never appeared"
  exit 1
fi

# keep everything at D0
for d in $BRIDGES $GPU; do
  echo on > /sys/bus/pci/devices/0000:$d/power/control || true
done

# ASPM off (LnkCtl) on bridge + GPU
for d in $BRIDGES $GPU; do
  setpci -s $d CAP_EXP+10.w=0000
done

# L1 substates off (L1.1/L1.2), tolerate devices without the cap
for d in $BRIDGES $GPU; do
  setpci -s $d ECAP_1E+04.l=00000000 || true
done

# target link speed: Gen3 (8 GT/s) on bridge + GPU
for d in $BRIDGES $GPU; do
  setpci -s $d CAP_EXP+30.w=0003
done

# retrain
for d in $BRIDGES $GPU; do
  setpci -s $d CAP_EXP+10.w=0020
done
sleep 2

echo "== link state after pin =="
lspci -vv -s $GPU | grep -E 'LnkCap:|LnkSta:|LnkCtl2' || true
lspci -vv -s 02:00.0 | grep -E 'LnkSta:' || true

# load driver (blacklisted at boot, explicit load here is fine)
modprobe nvidia
modprobe nvidia_uvm
sleep 2

# persistence mode: stay initialized, no power transitions
nvidia-smi -pm 1 || true
nvidia-smi --query-gpu=name,pstate,pcie.link.gen.current,pcie.link.width.current --format=csv || true
echo "DONE"
EOF
chmod +x /usr/local/sbin/egpu-up.sh

echo "== 5/6 egpu-up.service (multi-user, before display manager) =="
cat > /etc/systemd/system/egpu-up.service <<'EOF'
[Unit]
Description=Pin AORUS eGPU link and load NVIDIA driver
After=systemd-udev-settle.service
Wants=systemd-udev-settle.service
Before=display-manager.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/egpu-up.sh
RemainAfterExit=yes
TimeoutStartSec=120

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable egpu-up.service

echo "== 6/6 headless default for first test + rebuild initramfs/grub =="
systemctl set-default multi-user.target
update-initramfs -u
update-grub

cat <<'EOF'

Done. NEXT STEPS (user):
  1. Reboot NORMALLY (no GRUB editing, no recovery mode).
     - boots to a text console (multi-user), no GUI for now
  2. Log in, then tell me - I will verify link state and run the CUDA
     load test myself.
  3. If the box survives load: we re-enable the GUI
       (systemctl set-default graphical.target) and test login.

If it crashes anyway: reboot, select the GRUB entry, press 'e', append
   systemd.mask=egpu-up.service
to the linux line - the box will come up as a dumb hub and we iterate.
EOF
