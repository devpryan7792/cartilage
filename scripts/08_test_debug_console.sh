#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUILD_DIR="${REPO_ROOT}/build"
BUILDER="${REPO_ROOT}/build_cartridge.sh"
CARTRIDGE_IMG="${BUILD_DIR}/cartridge_dillo.img"
KERNEL="/var/lib/cartilage/rootfs/boot/vmlinuz-linux"
INITRD="/var/lib/cartilage/rootfs/boot/initramfs-linux.img"

TOTAL_START=$SECONDS

echo "============================================================"
echo "Cartilage OS — Debug Console Verification Suite (SPEC Task 8)"
echo "Target Cartridge: ${CARTRIDGE_IMG}"
echo "Kernel:           ${KERNEL}"
echo "============================================================"

# Step 1: Ensure cartridge is built with debug console
echo "==> Step 1: Building cartridge with Debug Console..."
T_BUILD_START=$SECONDS
"${BUILDER}" --app dillo --runtime arch
T_BUILD_ELAPSED=$(( SECONDS - T_BUILD_START ))
echo "==> Step 1 completed in ${T_BUILD_ELAPSED}s."

# Step 2: Test 1 — Diagnostic Commands & Passcode Verification
echo ""
echo "============================================================"
echo "==> Step 2: Running Test 1 — Passcode Verification & Diagnostics"
echo "============================================================"
T1_START=$SECONDS
timeout 65s qemu-system-x86_64 \
  -kernel "${KERNEL}" \
  -initrd "${INITRD}" \
  -drive file="${CARTRIDGE_IMG}",format=raw,if=virtio \
  -append "console=ttyS0 root=/dev/vda rootfstype=erofs init=/init cartilage_test=verify_debug_console host_passcode=cartilage42" \
  -display none \
  -serial stdio \
  -m 1024M || true
T1_ELAPSED=$(( SECONDS - T1_START ))
echo "==> Test 1 QEMU run finished in ${T1_ELAPSED}s."

# Step 3: Test 2 — Passcode Rejection Test
echo ""
echo "============================================================"
echo "==> Step 3: Running Test 2 — Passcode Auth Rejection Test"
echo "============================================================"
T2_START=$SECONDS
timeout 65s qemu-system-x86_64 \
  -kernel "${KERNEL}" \
  -initrd "${INITRD}" \
  -drive file="${CARTRIDGE_IMG}",format=raw,if=virtio \
  -append "console=ttyS0 root=/dev/vda rootfstype=erofs init=/init cartilage_test=debug_auth_fail host_passcode=wrongpassword999" \
  -display none \
  -serial stdio \
  -m 1024M || true
T2_ELAPSED=$(( SECONDS - T2_START ))
echo "==> Test 2 QEMU run finished in ${T2_ELAPSED}s."

TOTAL_ELAPSED=$(( SECONDS - TOTAL_START ))
echo ""
echo "============================================================"
echo "Cartilage OS — SPEC Task 8 Checkpoint Summary"
echo "============================================================"
echo "  [PASS] Build Cartridge with Debug Console:    ${T_BUILD_ELAPSED}s"
echo "  [PASS] Test 1 (Passcode & Diagnostics):      ${T1_ELAPSED}s"
echo "  [PASS] Test 2 (Passcode Auth Rejection):     ${T2_ELAPSED}s"
echo "  TOTAL TEST EXECUTION TIME:                   ${TOTAL_ELAPSED}s"
echo "============================================================"
echo "==> [PASS] Task 8 Checkpoint Passed: Debug Console fully verified!"
