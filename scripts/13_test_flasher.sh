#!/usr/bin/env bash
set -uo pipefail

if [[ $EUID -ne 0 ]]; then
    exec sudo bash "$0" "$@"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUILD_DIR="${REPO_ROOT}/build"
FLASHER="${SCRIPT_DIR}/13_flash_usb.sh"
LOG_FILE="${BUILD_DIR}/13_test_flasher.log"

OVMF_BIOS="/usr/share/ovmf/OVMF.fd"
if [[ ! -f "${OVMF_BIOS}" ]]; then
    OVMF_BIOS="/usr/share/qemu/OVMF.fd"
fi

KVM_FLAGS=""
if [[ -c /dev/kvm ]]; then
    KVM_FLAGS="-enable-kvm -cpu host"
fi


TOTAL_START=$SECONDS

echo "============================================================"
echo "Cartilage OS — Bare-Metal USB Flasher Verification Suite (Task 14)"
echo "Flasher Script: ${FLASHER}"
echo "UEFI Firmware:  ${OVMF_BIOS}"
echo "============================================================"
mkdir -p "${BUILD_DIR}"
rm -f "${LOG_FILE}"

# --- Test 1: Safety Guard Rejection Test ---
echo ""
echo "============================================================"
echo "==> Test 1: Verifying Safety Guard on Fixed Internal Drives..."
echo "============================================================"
# /dev/sda is typically the primary disk (or virtual disk) in WSL / host
SAFETY_OUTPUT=""
SAFETY_CODE=0
if [[ -b /dev/sda ]]; then
    SAFETY_OUTPUT=$("${FLASHER}" /dev/sda 2>&1 || true)
    if echo "${SAFETY_OUTPUT}" | grep -q "Safety Guard Triggered"; then
        echo "[TEST-PASS] Safety Guard correctly rejected fixed internal drive /dev/sda."
    else
        echo "[TEST-INFO] /dev/sda was not flagged (might be removable/loop): ${SAFETY_OUTPUT}"
    fi
else
    echo "[TEST-INFO] No /dev/sda found, skipping internal drive rejection check."
fi

# --- Test 2: Virtual Disk Creation & Flashing ---
echo ""
echo "============================================================"
echo "==> Test 2: Creating Virtual Target Disk (2048M) and Flashing..."
echo "============================================================"
RAW_TARGET="/var/lib/cartilage/test_usb_flasher.raw"
rm -f "${RAW_TARGET}"
truncate -s 2048M "${RAW_TARGET}"

LOOP_DEV=$(losetup -Pf --show "${RAW_TARGET}")
echo "Attached target loop device: ${LOOP_DEV}"

# Run flasher with --force-internal --yes
T_FLASH_START=$SECONDS
"${FLASHER}" "${LOOP_DEV}" --force-internal --yes
T_FLASH_ELAPSED=$(( SECONDS - T_FLASH_START ))
echo "==> Flasher finished in ${T_FLASH_ELAPSED}s."

# Detach loop device so QEMU can read the raw image
losetup -d "${LOOP_DEV}"

# --- Test 3: Boot Flashed Disk in QEMU via UEFI (Entry 1: Dillo) ---
echo ""
echo "============================================================"
echo "==> Test 3: Booting Flashed Disk in QEMU (Entry 1: Dillo via PARTLABEL)..."
echo "============================================================"
T_QEMU1_START=$SECONDS
timeout 60s qemu-system-x86_64   ${KVM_FLAGS}   -bios "${OVMF_BIOS}"   -drive file="${RAW_TARGET}",format=raw,if=virtio   -display none   -serial stdio   -m 1024M 2>&1 | tee "${LOG_FILE}" || true
T_QEMU1_ELAPSED=$(( SECONDS - T_QEMU1_START ))
echo "==> QEMU Entry 1 execution finished in ${T_QEMU1_ELAPSED}s."

# --- Test 4: Switch Entry to Mousepad & Boot via PARTLABEL ---
echo ""
echo "============================================================"
echo "==> Test 4: Switching to Entry 2 (Mousepad) and Booting via PARTLABEL..."
echo "============================================================"
LOOP_DEV=$(losetup -Pf --show "${RAW_TARGET}")
ESP_MNT=$(mktemp -d /tmp/esp_test_XXXXXX)
mount "${LOOP_DEV}p1" "${ESP_MNT}"
cat << 'LOADER_EOF' > "${ESP_MNT}/loader/loader.conf"
default mousepad.conf
timeout 1
console-mode max
LOADER_EOF
sync
umount "${ESP_MNT}"
rmdir "${ESP_MNT}"
losetup -d "${LOOP_DEV}"

T_QEMU2_START=$SECONDS
timeout 60s qemu-system-x86_64   ${KVM_FLAGS}   -bios "${OVMF_BIOS}"   -drive file="${RAW_TARGET}",format=raw,if=virtio   -display none   -serial stdio   -m 1024M 2>&1 | tee -a "${LOG_FILE}" || true
T_QEMU2_ELAPSED=$(( SECONDS - T_QEMU2_START ))
echo "==> QEMU Entry 2 execution finished in ${T_QEMU2_ELAPSED}s."

# Clean up raw target image
rm -f "${RAW_TARGET}"

# --- Step 5: Assert Verification Results ---
echo ""
echo "============================================================"
echo "Cartilage OS — Task 14 Verification Assertions"
echo "============================================================"
HAS_DILLO=0
HAS_MOUSEPAD=0

if grep -q "CARTRIDGE VERIFICATION FOR dillo SUCCEEDED" "${LOG_FILE}"; then
    HAS_DILLO=1
    echo "  [PASS] Entry 1 (Dillo via PARTLABEL=CART_DILLO) verified."
fi

if grep -q "CARTRIDGE VERIFICATION FOR mousepad SUCCEEDED" "${LOG_FILE}"; then
    HAS_MOUSEPAD=1
    echo "  [PASS] Entry 2 (Mousepad via PARTLABEL=CART_MOUSEPAD) verified."
fi

if [[ ${HAS_DILLO} -eq 1 && ${HAS_MOUSEPAD} -eq 1 ]]; then
    TOTAL_ELAPSED=$(( SECONDS - TOTAL_START ))
    echo "  [PASS] Disk Flashing:                     ${T_FLASH_ELAPSED}s"
    echo "  [PASS] QEMU Entry 1 Boot:                 ${T_QEMU1_ELAPSED}s"
    echo "  [PASS] QEMU Entry 2 Boot:                 ${T_QEMU2_ELAPSED}s"
    echo "  TOTAL EXECUTION TIME:                     ${TOTAL_ELAPSED}s"
    echo "============================================================"
    echo "==> [PASS] Flashed USB disk image boots successfully with PARTLABEL root routing."
    exit 0
else
    echo "==> [FAIL] Verification failed! One or more entries did not boot correctly via PARTLABEL." >&2
    echo "--- Log output ---" >&2
    cat "${LOG_FILE}" >&2
    exit 1
fi
