#!/usr/bin/env bash
# egpu-doctor: one-shot health check + single clean driver load attempt.
# Use after driver updates, kernel updates, BIOS updates, or on a new host.
# Prints a PASS/FAIL verdict and appends a dated log under logs/.
set -uo pipefail
cd "$(dirname "$0")"
LOG="logs/egpu-doctor-$(date +%Y%m%d-%H%M%S).log"
{
echo "== egpu-doctor $(date) =="
uname -r

D=$(lspci -nn | awk '/10de:2d04/ {print $1; exit}')
if [ -z "$D" ]; then
  echo "VERDICT: FAIL -- eGPU not on the PCI bus"
  boltctl list 2>&1 | head -8
  exit 0
fi
DD="0000:$D"
echo "GPU at $DD, link $(cat /sys/bus/pci/devices/$DD/current_link_speed 2>/dev/null) x$(cat /sys/bus/pci/devices/$DD/current_link_width 2>/dev/null), status $(cat /sys/bus/pci/devices/$DD/power/runtime_status 2>/dev/null)"

BUS=${D%%:*}
for b in "$((BUS - 2))" "$((BUS - 1))" "$BUS"; do
  p=$(printf "0000:%02x:00.0" "$b")
  [ -d "/sys/bus/pci/devices/$p" ] && echo on > "/sys/bus/pci/devices/$p/power/control" 2>/dev/null
done

modprobe -r nvidia_uvm nvidia 2>/dev/null
modprobe nvidia 2>/dev/null
sleep 5
if nvidia-smi >/dev/null 2>&1; then
  echo "VERDICT: PASS -- driver loaded"
  nvidia-smi | head -20
else
  echo "VERDICT: FAIL -- probe failed"
  journalctl -k -b 0 --no-pager | grep -iE 'nvidia|fallen|03:00' | grep -vE 'Nvlink Core is being init|Unregistered Nvlink' | tail -12
fi
} | tee "$LOG"
echo "(log saved: $LOG)"
