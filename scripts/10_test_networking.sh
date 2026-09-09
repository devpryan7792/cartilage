#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUILD_DIR="${REPO_ROOT}/build"
BUILDER="${REPO_ROOT}/build_cartridge.sh"
CARTRIDGE_IMG="${BUILD_DIR}/cartridge_dillo.img"
KERNEL="/var/lib/cartilage/rootfs/boot/vmlinuz-linux"
INITRD="/var/lib/cartilage/rootfs/boot/initramfs-linux.img"
LOG_FILE="${BUILD_DIR}/10_test_networking.log"

TOTAL_START=$SECONDS

echo "============================================================"
echo "Cartilage OS � Network & DNS Verification Suite (Task 11)"
echo "Target Cartridge: ${CARTRIDGE_IMG}"
echo "Kernel:           ${KERNEL}"
echo "============================================================"

# Step 1: Ensure cartridge is built with network & DNS subsystem
echo "==> Step 1: Building test cartridge (dillo)..."
T_BUILD_START=$SECONDS
"${BUILDER}" --app dillo --runtime arch
T_BUILD_ELAPSED=$(( SECONDS - T_BUILD_START ))
echo "==> Step 1 completed in ${T_BUILD_ELAPSED}s."

# Step 2: Boot QEMU with virtio-net-pci and test network hook
echo ""
echo "============================================================"
echo "==> Step 2: Booting QEMU with virtio-net and running network test..."
echo "============================================================"
mkdir -p "${BUILD_DIR}"
T_QEMU_START=$SECONDS

timeout 75s qemu-system-x86_64 \
  -kernel "${KERNEL}" \
  -initrd "${INITRD}" \
  -drive file="${CARTRIDGE_IMG}",format=raw,if=virtio \
  -netdev user,id=net0 \
  -device virtio-net-pci,netdev=net0 \
  -append "console=ttyS0 root=/dev/vda rootfstype=erofs init=/init cartilage_test_net=1" \
  -display none \
  -serial stdio \
  -m 1024M 2>&1 | tee "${LOG_FILE}" || true

T_QEMU_ELAPSED=$(( SECONDS - T_QEMU_START ))
echo "==> QEMU execution finished in ${T_QEMU_ELAPSED}s."

# Step 3: Assert verification results
echo ""
echo "============================================================"
echo "Cartilage OS � Task 11 Verification Assertions"
echo "============================================================"
if grep -q "\[PASS\] Network & DNS verification successful" "${LOG_FILE}"; then
    TOTAL_ELAPSED=$(( SECONDS - TOTAL_START ))
    echo "  [PASS] Cartridge Build:                   ${T_BUILD_ELAPSED}s"
    echo "  [PASS] QEMU Network & DNS Test:           ${T_QEMU_ELAPSED}s"
    echo "  TOTAL EXECUTION TIME:                     ${TOTAL_ELAPSED}s"
    echo "============================================================"
    echo "==> [PASS] Task 11 Checkpoint Passed: Network & DNS verification successful!"
    exit 0
else
    echo "==> [FAIL] Expected '[PASS] Network & DNS verification successful' not found in test log." >&2
    echo "--- Log output ---" >&2
    cat "${LOG_FILE}" >&2
    exit 1
fi
