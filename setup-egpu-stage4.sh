#!/usr/bin/env bash
# Stage 4: pin the eGPU link to Gen3 with setpci BEFORE loading nvidia.
# Documented fix for "fallen off the bus" on the AORUS AI BOX over USB4-class
# links (Gen4<->Gen3 flap kills the tunnel when the driver takes ownership).
# REQUIRES Secure Boot OFF (lockdown blocks setpci config writes).
# Topology auto-detected; works on any kernel.
set -uo pipefail

D=$(lspci -nn | awk '/10de:2d04/ {print $1; exit}')
if [ -z "$D" ]; then echo "eGPU not found on the bus"; exit 1; fi
DD="0000:$D"
BUS=${D%%:*}
BR1=$(printf "0000:%02x:00.0" $((BUS - 1)))
BR2=$(printf "0000:%02x:00.0" $((BUS - 2)))
echo "GPU: $DD  bridges: $BR1 $BR2"

echo "== sanity: config-space write permitted? =="
setpci -s "$DD" CAP_EXP+30.w >/dev/null 2>&1 || { echo "setpci blocked -- is Secure Boot still on?"; exit 1; }

echo "== unload driver, ASPM off on chain =="
modprobe -r nvidia_uvm nvidia 2>/dev/null || true
for d in "$BR1" "$BR2" "$DD"; do
  [ -d "/sys/bus/pci/devices/$d" ] && setpci -s "$d" CAP_EXP+10.w=0000 2>/dev/null && echo "$d: ASPM off"
done

echo "== force Gen3 target on bridge + GPU, retrain =="
for d in "$BR2" "$DD"; do
  setpci -s "$d" CAP_EXP+30.w=0x0003:0x000f 2>/dev/null && echo "$d: target Gen3"
done
sleep 1
for d in "$BR2" "$DD"; do
  setpci -s "$d" CAP_EXP+10.w=0x0020:0x0020 2>/dev/null && echo "$d: retrain"
done
sleep 6
echo "link now: $(cat /sys/bus/pci/devices/$DD/current_link_speed 2>/dev/null) x$(cat /sys/bus/pci/devices/$DD/current_link_width 2>/dev/null)"

ok=0
for i in 1 2 3; do
  modprobe nvidia 2>/dev/null
  sleep 4
  if nvidia-smi >/dev/null 2>&1; then ok=1; echo "load attempt $i: SUCCESS"; break; fi
  echo "load attempt $i: failed"
  modprobe -r nvidia 2>/dev/null || true
  sleep 5
done

if [ "$ok" = 1 ]; then
  nvidia-smi | head -20
  echo
  echo "PASS with Gen3 pin. Tell me, and I will bake it into the boot service."
else
  echo "FAIL: Gen3 pin did not help on this kernel."
  echo "Try: reboot into kernel 7.2.6 (setup-egpu-stage5-kernel.sh) and rerun this script."
fi
