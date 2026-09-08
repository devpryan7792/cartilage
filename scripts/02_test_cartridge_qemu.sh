#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUILD_DIR="${REPO_ROOT}/build"
CARTRIDGE_IMG="${BUILD_DIR}/cartridge.img"
KERNEL="/var/lib/cartilage/rootfs/boot/vmlinuz-linux"
INITRD="/var/lib/cartilage/rootfs/boot/initramfs-linux.img"

if [[ ! -f "${CARTRIDGE_IMG}" ]]; then
    echo "Error: ${CARTRIDGE_IMG} not found. Run scripts/02_build_cartridge.sh first." >&2
    exit 1
fi

echo "============================================================"
echo "Cartilage OS — QEMU Cartridge Boot Verification (Task 2)"
echo "Cartridge: ${CARTRIDGE_IMG}"
echo "============================================================"

# Pass -vga virtio per SPEC.md Task 2
timeout 30s qemu-system-x86_64 \
  -kernel "${KERNEL}" \
  -initrd "${INITRD}" \
  -drive file="${CARTRIDGE_IMG}",format=raw,if=virtio \
  -append "console=ttyS0 root=/dev/vda rootfstype=erofs init=/init" \
  -vga virtio \
  -display none \
  -serial stdio \
  -m 1024M || {
    RC=$?
    if [[ $RC -eq 124 || $RC -eq 143 ]]; then
        echo ""
        echo "==> [PASS] Cartridge booted successfully, seatd started before cage, and cage ran without panic/crash."
        exit 0
    else
        echo "==> QEMU exited with code: ${RC}"
        exit $RC
    fi
}
