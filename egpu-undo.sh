#!/usr/bin/env bash
# egpu-undo.sh - revert the AORUS eGPU system changes documented in EGPU.md.
#
# Usage: sudo bash egpu-undo.sh <stage>
#   status            show what is currently applied (no changes)
#   undo-modprobe     remove zz-egpu.conf + experiment leftovers, restore
#                     nvidia_drm modeset, refresh initramfs
#   undo-systemd      remove egpu-down/egpu-up units + helper scripts
#   undo-grub         restore stock kernel cmdline (quiet splash)
#   undo-stonking-repo remove the leftover stonking apt source + pin
#   undo-kernel       purge the 7.3.0-9 kernel stack + libssl4
#                     (BOOT 7.0.0-38 FIRST)
#   undo-driver       reinstall nvidia-driver-595-open (drops 615 + the
#                     patched DKMS source tree with it)
#   undo-cuda         purge CUDA 13.4 + its apt source
#   full              modprobe + systemd + grub + stonking-repo + driver
#                     (kernel and CUDA stay; do them deliberately)
set -euo pipefail

if [ "$(id -u)" != "0" ]; then echo "run with sudo"; exit 1; fi

stage="${1:-}"
case "$stage" in
  status)
    echo "== modprobe config =="
    for f in /etc/modprobe.d/zz-egpu.conf /etc/modprobe.d/nvidia-tunnel-fix.conf; do
      [ -f "$f" ] && echo "PRESENT  $f" || echo "absent   $f"
    done
    grep -H 'options nvidia_drm' /etc/modprobe.d/nvidia-graphics-drivers-kms.conf 2>/dev/null || echo "no nvidia_drm options line"
    echo "== grub cmdline =="
    grep '^GRUB_CMDLINE_LINUX_DEFAULT' /etc/default/grub
    echo "== systemd =="
    systemctl is-enabled egpu-down.service 2>&1 | sed 's/^/egpu-down: /'
    systemctl is-enabled egpu-up.service 2>&1 | sed 's/^/egpu-up:  /'
    ls /usr/local/sbin/egpu-up.sh 2>/dev/null || echo "no /usr/local/sbin/egpu-up.sh"
    echo "== stonking leftovers =="
    ls /etc/apt/sources.list.d/zz-stonking-kernel.list /etc/apt/sources.list.d/zz-stonking-kernel.sources /etc/apt/preferences.d/zz-stonking-kernel 2>/dev/null || echo "none"
    echo "== kernel / driver =="
    dpkg -l 2>/dev/null | awk '/linux-image-unsigned-7.3.0-9|libssl4|nvidia-driver-615-open|nvidia-driver-595-open/ {print $1, $2, $3}'
    dkms status 2>/dev/null | grep -i nvidia || true
    echo "== DKMS source patch (dmem build fix) =="
    if grep -q 'struct dmem_cgroup_init init' /usr/src/nvidia-615.71.09/nvidia/os-interface.c 2>/dev/null; then
      echo "PRESENT in /usr/src/nvidia-615.71.09 (dies on driver upgrade/reinstall)"
    else
      echo "absent"
    fi
    exit 0
    ;;

  undo-modprobe)
    rm -f /etc/modprobe.d/zz-egpu.conf /etc/modprobe.d/nvidia-tunnel-fix.conf
    if [ -f /etc/modprobe.d/nvidia-graphics-drivers-kms.conf ]; then
      sed -i 's/^options nvidia_drm modeset=0 fbdev=0/options nvidia_drm modeset=1/' \
        /etc/modprobe.d/nvidia-graphics-drivers-kms.conf
    fi
    update-initramfs -u
    echo "modprobe config reverted. NOTE: nvidia will load at boot again and"
    echo "the display stack will see the box - only safe with a fixed driver."
    ;;

  undo-systemd)
    systemctl disable egpu-down.service 2>/dev/null || true
    rm -f /etc/systemd/system/egpu-down.service \
          /etc/systemd/system/egpu-up.service \
          /usr/local/sbin/egpu-up.sh /var/log/egpu-up.log
    systemctl daemon-reload
    echo "systemd units removed."
    ;;

  undo-grub)
    sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"/' /etc/default/grub
    update-grub
    grep '^GRUB_CMDLINE_LINUX_DEFAULT' /etc/default/grub
    echo "grub cmdline restored to stock (takes effect on next boot)."
    ;;

  undo-stonking-repo)
    rm -f /etc/apt/sources.list.d/zz-stonking-kernel.list /etc/apt/sources.list.d/zz-stonking-kernel.sources /etc/apt/preferences.d/zz-stonking-kernel
    apt update
    echo "stonking source + pin removed (installed 7.3 packages stay)."
    ;;

  undo-kernel)
    echo "WARNING: make sure you booted 7.0.0-38 before purging 7.3. Current: $(uname -r)"
    read -r -p "Type 'yes' to continue: " a
    [ "$a" = "yes" ] || { echo "aborted"; exit 1; }
    apt purge -y 'linux-image-unsigned-7.3.0-9-generic' 'linux-modules-7.3.0-9-generic' \
      'linux-headers-7.3.0-9*' 'linux-main-modules-zfs-7.3.0-9-generic' \
      'linux-main-modules-v4l2loopback-7.3.0-9-generic' libssl4
    apt autoremove -y
    echo "7.3 kernel stack purged. Consider: apt install virtualbox-dkms (if wanted)"
    ;;

  undo-driver)
    apt install -y nvidia-driver-595-open
    echo "595-open restored. The 615 DKMS tree (with the dmem patch) was removed with it."
    echo "Reboot, then: nvidia-smi | head -12"
    ;;

  undo-cuda)
    apt purge -y 'cuda-toolkit-13-4' 'cuda-*-13-4' cuda-keyring
    rm -f /etc/apt/sources.list.d/cuda-ubuntu2604-x86_64.list
    apt update
    echo "CUDA 13.4 purged."
    ;;

  full)
    "$0" undo-modprobe
    "$0" undo-systemd
    "$0" undo-grub
    "$0" undo-stonking-repo
    "$0" undo-driver
    echo
    echo "Full revert done (kernel 7.3 + CUDA kept on purpose). Reboot into"
    echo "7.0.0-38 if you also want: sudo bash $0 undo-kernel"
    ;;

  *)
    sed -n '2,20p' "$0"
    exit 1
    ;;
esac
