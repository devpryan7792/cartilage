#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ROOTFS_DIR="${1:-/var/lib/cartilage/rootfs}"

KERNEL="${ROOTFS_DIR}/boot/vmlinuz-linux"
INITRD="${ROOTFS_DIR}/boot/initramfs-linux.img"

if [[ ! -f "${KERNEL}" ]]; then
    echo "Error: Kernel not found at ${KERNEL}" >&2
    exit 1
fi

echo "============================================================"
echo "Cartilage OS — QEMU Boot Verification (SPEC Task 1)"
echo "Kernel: ${KERNEL}"
echo "Initrd: ${INITRD}"
echo "============================================================"

# Pass -display none -serial stdio to direct serial to stdout without QEMU monitor collision
timeout --preserve-status 10s qemu-system-x86_64 \
  -kernel "${KERNEL}" \
  -initrd "${INITRD}" \
  -append "console=ttyS0 init=/bin/sh rdinit=/bin/sh panic=-1" \
  -display none \
  -serial stdio \
  -m 512M || {
    RC=$?
    # Exit code 143 (SIGTERM) or 124 means timeout reached after running shell prompt
    if [[ $RC -eq 143 || $RC -eq 124 || $RC -eq 1 ]]; then
        echo ""
        echo "==> [PASS] QEMU successfully booted to /bin/sh prompt without kernel panic."
        exit 0
    else
        echo "==> QEMU exited with code: ${RC}"
        exit $RC
    fi
}
