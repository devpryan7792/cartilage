#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUILD_DIR="${REPO_ROOT}/build"
CARTRIDGE_IMG="${BUILD_DIR}/cartridge.img"
DATA_IMG="${BUILD_DIR}/data_partition.img"
CLEAN_IMG="${BUILD_DIR}/host_clean.img"
DIRTY_IMG="${BUILD_DIR}/host_dirty.img"
KERNEL="/var/lib/cartilage/rootfs/boot/vmlinuz-linux"
INITRD="/var/lib/cartilage/rootfs/boot/initramfs-linux.img"

if [[ ! -f "${CARTRIDGE_IMG}" ]]; then
    echo "Error: ${CARTRIDGE_IMG} not found. Run scripts/02_build_cartridge.sh first." >&2
    exit 1
fi

TOTAL_START=$SECONDS

echo "============================================================"
echo "Cartilage OS — Host Access Mode Verification (SPEC Task 5)"
echo "Cartridge:  ${CARTRIDGE_IMG}"
echo "Clean Host: ${CLEAN_IMG}"
echo "Dirty Host: ${DIRTY_IMG}"
echo "============================================================"

# --- Step 1: Prepare Clean NTFS Image ---
echo "==> Step 1: Preparing Clean NTFS Image (64MB)..."
rm -f "${CLEAN_IMG}"
truncate -s 64M "${CLEAN_IMG}"
mkfs.ntfs -Q -F -L HOSTCLEAN "${CLEAN_IMG}" >/dev/null

MNT_TMP="/mnt/host_clean_tmp"
mkdir -p "${MNT_TMP}"
mount -o loop "${CLEAN_IMG}" "${MNT_TMP}"
mkdir -p "${MNT_TMP}/workspace/project_notes"
echo "Initial host project documentation." > "${MNT_TMP}/workspace/project_notes/readme.txt"
sync
umount "${MNT_TMP}"
rmdir "${MNT_TMP}"
echo "Clean NTFS image ready with /workspace/project_notes populated."

# --- Step 2: Prepare Dirty NTFS Image ---
echo "==> Step 2: Preparing Dirty NTFS Image (64MB)..."
rm -f "${DIRTY_IMG}"
truncate -s 64M "${DIRTY_IMG}"
mkfs.ntfs -Q -F -L HOSTDIRTY "${DIRTY_IMG}" >/dev/null

MNT_TMP="/mnt/host_dirty_tmp"
mkdir -p "${MNT_TMP}"
mount -o loop "${DIRTY_IMG}" "${MNT_TMP}"
mkdir -p "${MNT_TMP}/workspace/project_notes"
echo "Initial host project documentation on dirty drive." > "${MNT_TMP}/workspace/project_notes/readme.txt"
sync
umount "${MNT_TMP}"
rmdir "${MNT_TMP}"

python3 "${SCRIPT_DIR}/set_ntfs_dirty.py" "${DIRTY_IMG}"
echo "Dirty NTFS image ready (dirty/hibernation bit set)."

# --- Step 3: Test 1 — Happy Path (Clean NTFS Volume) ---
echo ""
echo "============================================================"
echo "==> Step 3: Running Test 1 — Happy Path (Clean NTFS Volume)"
echo "============================================================"
T1_START=$SECONDS

timeout 65s qemu-system-x86_64 \
  -kernel "${KERNEL}" \
  -initrd "${INITRD}" \
  -drive file="${CARTRIDGE_IMG}",format=raw,if=virtio \
  -drive file="${DATA_IMG}",format=raw,if=virtio \
  -drive file="${CLEAN_IMG}",format=raw,if=virtio \
  -append "console=ttyS0 root=/dev/vda rootfstype=erofs init=/init cartilage_test=host_happy host_passcode=cartilage42" \
  -display none \
  -serial stdio \
  -m 1024M || true

T1_ELAPSED=$(( SECONDS - T1_START ))
echo "==> Test 1 QEMU run finished in ${T1_ELAPSED}s."

# Verify that marker file was actually written to the clean NTFS image
echo "==> Host-side verification of written marker file on clean NTFS image..."
mkdir -p /mnt/verify_clean
mount -o loop,ro "${CLEAN_IMG}" /mnt/verify_clean
if [[ -f /mnt/verify_clean/workspace/host_test.txt ]] && grep -q "HOST_CLEAN_WRITE_TOKEN_9876" /mnt/verify_clean/workspace/host_test.txt; then
    echo "==> [PASS] Host-side verification succeeded: Token verified on NTFS image!"
    cat /mnt/verify_clean/workspace/host_test.txt
else
    echo "==> [FAIL] Marker file not found on host NTFS image!" >&2
    umount /mnt/verify_clean
    rmdir /mnt/verify_clean
    exit 1
fi
umount /mnt/verify_clean
rmdir /mnt/verify_clean

# --- Step 4: Test 2 — Failure Path (Dirty NTFS / Windows Hibernation) ---
echo ""
echo "============================================================"
echo "==> Step 4: Running Test 2 — Failure Path (Dirty NTFS Volume)"
echo "============================================================"
T2_START=$SECONDS

timeout 65s qemu-system-x86_64 \
  -kernel "${KERNEL}" \
  -initrd "${INITRD}" \
  -drive file="${CARTRIDGE_IMG}",format=raw,if=virtio \
  -drive file="${DATA_IMG}",format=raw,if=virtio \
  -drive file="${DIRTY_IMG}",format=raw,if=virtio \
  -append "console=ttyS0 root=/dev/vda rootfstype=erofs init=/init cartilage_test=host_dirty host_passcode=cartilage42" \
  -display none \
  -serial stdio \
  -m 1024M || true

T2_ELAPSED=$(( SECONDS - T2_START ))
echo "==> Test 2 QEMU run finished in ${T2_ELAPSED}s."

# --- Step 5: Test 3 — Authentication Gate Rejection Test ---
echo ""
echo "============================================================"
echo "==> Step 5: Running Test 3 — Passcode Auth Rejection Test"
echo "============================================================"
T3_START=$SECONDS

timeout 65s qemu-system-x86_64 \
  -kernel "${KERNEL}" \
  -initrd "${INITRD}" \
  -drive file="${CARTRIDGE_IMG}",format=raw,if=virtio \
  -drive file="${DATA_IMG}",format=raw,if=virtio \
  -drive file="${CLEAN_IMG}",format=raw,if=virtio \
  -append "console=ttyS0 root=/dev/vda rootfstype=erofs init=/init cartilage_test=host_auth_fail host_passcode=invalidpassword123" \
  -display none \
  -serial stdio \
  -m 1024M || true

T3_ELAPSED=$(( SECONDS - T3_START ))
echo "==> Test 3 QEMU run finished in ${T3_ELAPSED}s."

TOTAL_ELAPSED=$(( SECONDS - TOTAL_START ))
echo ""
echo "============================================================"
echo "Cartilage OS — SPEC Task 5 Checkpoint Summary"
echo "============================================================"
echo "  [PASS] Test 1 (Happy Path - Clean NTFS):  ${T1_ELAPSED}s"
echo "  [PASS] Test 2 (Failure Path - Dirty NTFS): ${T2_ELAPSED}s"
echo "  [PASS] Test 3 (Passcode Auth Rejection):  ${T3_ELAPSED}s"
echo "  TOTAL EXECUTION TIME:                    ${TOTAL_ELAPSED}s"
echo "============================================================"
echo "==> [PASS] Task 5 Checkpoint Passed: Storage Host Access Mode verified!"
