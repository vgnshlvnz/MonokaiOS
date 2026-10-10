#!/usr/bin/env bash
# shellcheck disable=SC2012,SC2054  # ls -t picks newest ISO; commas are QEMU syntax
# testiso.sh — boot an ISO in a QEMU window.
#   ./testiso.sh                 newest *.iso here, UEFI
#   ./testiso.sh my.iso bios     BIOS instead of UEFI
#   DISK=20G ./testiso.sh        also attach a blank 20 GB disk (for install tests)
#   GL=1 ./testiso.sh            3D-accelerated display (needed for Hyprland)
# SSH into the VM:  ssh -p 2222 netops@localhost
# Serial console:   View → serial0 in the QEMU window
set -euo pipefail

ISO="${1:-$(ls -t ./*.iso 2>/dev/null | head -n1)}"
MODE="${2:-uefi}"
[[ -f "${ISO}" ]] || { echo "No ISO found. Usage: $0 file.iso [uefi|bios]" >&2; exit 1; }

args=(-m 4096 -smp 4 -cdrom "${ISO}" -boot d
      -nic user,model=virtio-net-pci,hostfwd=tcp::2222-:22
      -usb -device usb-tablet)

# GL=1: virtio GPU with host OpenGL (virgl) — required for Hyprland in a VM.
if [[ "${GL:-0}" == 1 ]]; then args+=(-device virtio-vga-gl -display gtk,gl=on)
else args+=(-display gtk -vga virtio); fi

if [[ -w /dev/kvm ]]; then args+=(-enable-kvm -cpu host)
else echo "No /dev/kvm access — slow emulation (sudo usermod -aG kvm \$USER, then re-login)" >&2; fi

if [[ "${MODE}" == uefi ]]; then
  code=/usr/share/OVMF/OVMF_CODE_4M.fd vars_src=/usr/share/OVMF/OVMF_VARS_4M.fd
  [[ -f "${code}" ]] || { echo "Install OVMF: sudo apt install ovmf" >&2; exit 1; }
  vars="${ISO%.iso}.vars.fd"; [[ -f "${vars}" ]] || cp "${vars_src}" "${vars}"
  args+=(-machine q35 -drive "if=pflash,format=raw,readonly=on,file=${code}"
         -drive "if=pflash,format=raw,file=${vars}")
fi

if [[ -n "${DISK:-}" ]]; then
  disk="${ISO%.iso}.disk.qcow2"
  [[ -f "${disk}" ]] || qemu-img create -f qcow2 "${disk}" "${DISK}"
  args+=(-drive "file=${disk},if=virtio,format=qcow2")
fi

exec qemu-system-x86_64 "${args[@]}"
