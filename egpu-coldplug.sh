#!/usr/bin/env bash
# egpu-coldplug.sh - boot-time normalizer for a boot-attached (coldplugged)
# eGPU. If the GPU enumerated with zero/unprogrammed BARs (the coldplug
# signature: BAR0 reads 00000000 while the device is present), bounce it
# (remove + rescan) so the kernel re-programs the BARs via the runtime
# path. This does NOT revive a coldplugged GPU whose function is MMIO-dead
# ("fallen off the bus") - the driver probe will still fail. It only
# removes the BAR symptom so every failure looks the same. See EGPU.md
# "Coldplug function death".
set -u

GPU=03:00.0
AUDIO=03:00.1
LOG="${1:-/var/log/egpu-coldplug.log}"

log() { echo "$(date '+%F %T') $*" | tee -a "$LOG" >&2; }

# wait for enumeration (max 60 s); no box attached -> nothing to do
found=0
for _ in $(seq 1 60); do
  [ -e "/sys/bus/pci/devices/0000:$GPU/config" ] && { found=1; break; }
  sleep 1
done
if [ "$found" != 1 ]; then
  log "GPU $GPU not enumerated; nothing to do"
  exit 0
fi

bar0=$(setpci -s "$GPU" 0x10.l 2>/dev/null || echo fail)
if [ "$bar0" != "00000000" ] && [ "$bar0" != "fail" ]; then
  log "BAR0=$bar0 - BARs programmed, nothing to do"
  exit 0
fi

log "BAR0='$bar0' - coldplug BAR signature; bouncing $AUDIO + $GPU (remove/rescan)"
echo 1 > "/sys/bus/pci/devices/0000:$AUDIO/remove" 2>/dev/null
echo 1 > "/sys/bus/pci/devices/0000:$GPU/remove" 2>/dev/null
sleep 2
echo 1 > /sys/bus/pci/rescan
sleep 5
bar0=$(setpci -s "$GPU" 0x10.l 2>/dev/null || echo fail)
log "after rescan BAR0=$bar0 (expect a real address); MMIO readiness is the driver's problem now"
exit 0
