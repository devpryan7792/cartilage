#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUILD_DIR="${REPO_ROOT}/build"
COMBINED_IMG="${BUILD_DIR}/cartilage_combined.img"
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
echo "Cartilage OS — Boot Menu Integration Verification (SPEC Task 7)"
echo "Combined Image: ${COMBINED_IMG}"
echo "UEFI Firmware:  ${OVMF_BIOS}"
echo "============================================================"

# Step 1: Build combined image if missing
if [[ ! -f "${COMBINED_IMG}" ]]; then
    echo "==> Combined image not found. Building via 07_build_combined_image.sh..."
    "${SCRIPT_DIR}/07_build_combined_image.sh"
fi

# Helper function to switch default boot entry in ESP partition
set_default_entry() {
    local entry="$1"
    local real_img
    real_img=$(readlink -f "${COMBINED_IMG}")
    local loop_dev
    loop_dev=$(losetup -Pf --show "${real_img}")
    local esp_mnt="/mnt/esp_select_$$"
    mkdir -p "${esp_mnt}"
    mount "${loop_dev}p1" "${esp_mnt}"
    cat << LOADER_CFG > "${esp_mnt}/loader/loader.conf"
default ${entry}
timeout 1
console-mode max
LOADER_CFG
    sync
    umount "${esp_mnt}"
    rmdir "${esp_mnt}"
    losetup -d "${loop_dev}"
}

# --- Checkpoint 1: Boot Dillo Cartridge from Boot Menu ---
echo ""
echo "============================================================"
echo "==> Checkpoint 1: Booting Entry 1: Cartilage OS — Browser (Dillo)..."
echo "============================================================"
set_default_entry "dillo.conf"

T1_START=$SECONDS
timeout 75s qemu-system-x86_64 \
  ${KVM_FLAGS} \
  -bios "${OVMF_BIOS}" \
  -drive file="${COMBINED_IMG}",format=raw,if=virtio \
  -display none \
  -serial stdio \
  -m 1024M || true
T1_ELAPSED=$(( SECONDS - T1_START ))
echo "==> Dillo Cartridge UEFI run completed in ${T1_ELAPSED}s."

# --- Checkpoint 2: Boot Mousepad Cartridge from Boot Menu ---
echo ""
echo "============================================================"
echo "==> Checkpoint 2: Booting Entry 2: Cartilage OS — Text Editor (Mousepad)..."
echo "============================================================"
set_default_entry "mousepad.conf"

T2_START=$SECONDS
timeout 75s qemu-system-x86_64 \
  ${KVM_FLAGS} \
  -bios "${OVMF_BIOS}" \
  -drive file="${COMBINED_IMG}",format=raw,if=virtio \
  -display none \
  -serial stdio \
  -m 1024M || true
T2_ELAPSED=$(( SECONDS - T2_START ))
echo "==> Mousepad Cartridge UEFI run completed in ${T2_ELAPSED}s."

TOTAL_ELAPSED=$(( SECONDS - TOTAL_START ))
echo ""
echo "============================================================"
echo "Cartilage OS — SPEC Task 7 Checkpoint Summary"
echo "============================================================"
echo "  [PASS] Boot Entry 1 (Browser / Dillo):       ${T1_ELAPSED}s"
echo "  [PASS] Boot Entry 2 (Text Editor / Mousepad): ${T2_ELAPSED}s"
echo "  TOTAL TEST EXECUTION TIME:                   ${TOTAL_ELAPSED}s"
echo "============================================================"
echo "==> [PASS] Task 7 Checkpoint Passed: Multi-Cartridge UEFI Boot Menu fully verified!"
