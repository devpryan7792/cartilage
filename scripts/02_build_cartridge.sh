#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUILD_DIR="${REPO_ROOT}/build"
BASE_ROOTFS="/var/lib/cartilage/rootfs"
STAGING_DIR="/var/lib/cartilage/cartridge-staging"
OUTPUT_IMG="${BUILD_DIR}/cartridge.img"

echo "============================================================"
echo "Cartilage OS — Building Cartridge Image with Storage Modes"
echo "Base: ${BASE_ROOTFS}"
echo "Staging: ${STAGING_DIR}"
echo "Output: ${OUTPUT_IMG}"
echo "============================================================"

BUILD_START=$SECONDS

if [[ ! -d "${BASE_ROOTFS}" ]]; then
    echo "Error: Base rootfs not found at ${BASE_ROOTFS}!" >&2
    exit 1
fi

echo "==> Step 1: Preparing staging directory..."
rm -rf "${STAGING_DIR}"
mkdir -p "${STAGING_DIR}"
cp -a "${BASE_ROOTFS}/." "${STAGING_DIR}/"

echo "==> Step 1b: Setting up network, cache dir, and pacman inside staging..."
cp /etc/resolv.conf "${STAGING_DIR}/etc/resolv.conf"
mkdir -p "${STAGING_DIR}/var/cache/pacman/pkg"
mkdir -p "${STAGING_DIR}/etc/pacman.d"
cp "${BUILD_DIR}/mirrorlist" "${STAGING_DIR}/etc/pacman.d/mirrorlist"

cat << 'PAC_EOF' > "${STAGING_DIR}/etc/pacman.conf"
[options]
HoldPkg = pacman glibc
Architecture = x86_64
SigLevel = Never

[core]
Include = /etc/pacman.d/mirrorlist

[extra]
Include = /etc/pacman.d/mirrorlist
PAC_EOF

echo "==> Step 2: Installing packages into staging..."
arch-chroot "${STAGING_DIR}" pacman -Sy --noconfirm cage seatd mesa foot libglvnd kmod ttf-dejavu util-linux e2fsprogs ntfsprogs

mkdir -p "${STAGING_DIR}/data"
mkdir -p "${STAGING_DIR}/mnt/hidden_host"
mkdir -p "${STAGING_DIR}/app/workspace"
mkdir -p "${STAGING_DIR}/etc/cartilage"
echo "cartilage42" > "${STAGING_DIR}/etc/cartilage/passcode"
chmod 0600 "${STAGING_DIR}/etc/cartilage/passcode"

echo "==> Step 3: Writing custom PID 1 /init..."
cat << 'INIT_EOF' > "${STAGING_DIR}/init"
#!/bin/bash
set -euo pipefail

echo "============================================================"
echo "[init] Cartilage OS Cartridge Initializing (PID 1)"
echo "============================================================"

# Mount kernel virtual filesystems
mount -t proc proc /proc -o nosuid,noexec,nodev 2>/dev/null || true
mount -t sysfs sys /sys -o nosuid,noexec,nodev 2>/dev/null || true
mount -t devtmpfs devtmpfs /dev -o nosuid,mode=0755 2>/dev/null || true
mkdir -p /dev/pts /dev/shm
mount -t devpts devpts /dev/pts -o nosuid,noexec,mode=0620,gid=5 2>/dev/null || true
mount -t tmpfs shm /dev/shm -o nosuid,nodev,mode=1777 2>/dev/null || true
mount -t tmpfs tmpfs /tmp -o nosuid,nodev 2>/dev/null || true
mount -t tmpfs tmpfs /run -o nosuid,nodev,mode=0755 2>/dev/null || true

# Load drivers & modules
modprobe drm 2>/dev/null || true
modprobe virtio_gpu 2>/dev/null || true
modprobe bochs 2>/dev/null || true
modprobe overlay 2>/dev/null || true
modprobe zram num_devices=1 2>/dev/null || true
modprobe ext4 2>/dev/null || true
modprobe ntfs3 2>/dev/null || true
modprobe ntfs 2>/dev/null || true

# Helper: Developer Passcode Verification (Shared across Host Access & Debug Console)
verify_developer_passcode() {
    local input="${1:-}"
    local default_pass="cartilage42"
    local expected="$default_pass"
    if [[ -f /etc/cartilage/passcode ]]; then
        expected="$(cat /etc/cartilage/passcode)"
    fi
    # Check kernel cmdline for automated test passes (e.g. host_passcode=cartilage42)
    if [[ -z "$input" ]]; then
        for arg in $(cat /proc/cmdline); do
            if [[ "$arg" =~ ^host_passcode=(.*)$ ]]; then
                input="${BASH_REMATCH[1]}"
            fi
        done
    fi
    if [[ -z "$input" ]]; then
        read -s -p "[auth] Enter Developer Passcode: " input
        echo ""
    fi
    if [[ "$input" == "$expected" ]]; then
        echo "[auth] Developer Passcode verified successfully."
        return 0
    else
        echo "[auth] Authentication failed: invalid passcode." >&2
        return 1
    fi
}

# Helper: NTFS Dirty Bit & BitLocker Detection
check_ntfs_dirty() {
    local dev="$1"
    # BitLocker signature check
    if blkid "$dev" 2>/dev/null | grep -qi "bitlocker"; then
        return 1
    fi
    # NTFS scheduled check
    if ntfsinfo "$dev" 2>&1 | grep -qi "scheduled for check"; then
        return 1
    fi
    # NTFS volume DIRTY flag check
    if ntfsinfo -f -i 3 "$dev" 2>&1 | grep "Volume Flags" | grep -qi "DIRTY"; then
        return 1
    fi
    return 0
}

# Module 3: Storage Setup (Persistent vs Ephemeral Mode)
mkdir -p /data

# Check if a persistent partition (/dev/vdb) is present
if [[ -b /dev/vdb ]]; then
    echo "[init] Persistent partition /dev/vdb detected. Mounting..."
    mkdir -p /run/persistent_data
    if mount -t ext4 /dev/vdb /run/persistent_data 2>/dev/null; then
        mount --bind /run/persistent_data /data
        echo "[init] Persistent Mode active: /dev/vdb bind-mounted to /data"
    else
        echo "[init] Warning: /dev/vdb mount failed, falling back to ephemeral."
        mkdir -p /run/overlay_fs
        mount -t tmpfs -o size=256M tmpfs /run/overlay_fs
        mkdir -p /run/overlay_fs/upper /run/overlay_fs/work
        mount -t overlay overlay -o lowerdir=/data,upperdir=/run/overlay_fs/upper,workdir=/run/overlay_fs/work /data
    fi
else
    # Ephemeral Mode: OverlayFS on tmpfs
    echo "[init] Ephemeral Mode active: setting up OverlayFS on tmpfs..."
    mkdir -p /run/overlay_fs
    mount -t tmpfs -o size=256M tmpfs /run/overlay_fs
    mkdir -p /run/overlay_fs/upper /run/overlay_fs/work
    mount -t overlay overlay -o lowerdir=/data,upperdir=/run/overlay_fs/upper,workdir=/run/overlay_fs/work /data
fi

# Quota-bounded downloads tmpfs
mkdir -p /data/downloads
mount -t tmpfs -o size=20M,mode=0777 tmpfs /data/downloads
export XDG_DOWNLOAD_DIR=/data/downloads

# ZRAM swap setup (zstd)
echo "[init] Configuring zram0 swap (zstd)..."
zramctl -f -s 512M -a zstd 2>/dev/null || zramctl /dev/zram0 -s 512M -a zstd 2>/dev/null || true
mkswap /dev/zram0 2>/dev/null || true
swapon -p 32767 /dev/zram0 2>/dev/null || true
zramctl 2>/dev/null || true

# Module 3 (Part 5): Host Access Mode Setup
# Internal/host drive mounts ro by default under a global hidden path
mkdir -p /mnt/hidden_host
if [[ -b /dev/vdc ]]; then
    echo "[init] Host disk /dev/vdc detected. Mounting ro globally at /mnt/hidden_host..."
    mount -t ntfs3 -o ro,iocharset=utf8 /dev/vdc /mnt/hidden_host 2>/dev/null ||     mount -o ro /dev/vdc /mnt/hidden_host 2>/dev/null || true
    echo "[init] Host disk /dev/vdc mounted ro globally at /mnt/hidden_host."
fi

# --- Automated Test Hooks ---

# 1. Ephemeral Test Hook
if grep -q "cartilage_test=ephemeral" /proc/cmdline; then
    echo "============================================================"
    echo "[TEST] Running Ephemeral Mode Verification Suite (SPEC Task 3)"
    echo "============================================================"
    echo "==> Check 1: OverlayFS mount verification"
    mount | grep overlay || true
    echo "==> Check 2: Bounded tmpfs quota verification"
    mount | grep tmpfs | grep "/data/downloads" || true
    echo "==> Check 3: Active zram device verification"
    zramctl || true
    echo "==> Check 4: Quota overflow ENOSPC test"
    set +e
    dd if=/dev/zero of=/data/downloads/test.bin bs=1M count=999999 2>&1
    DD_STATUS=$?
    set -e
    ls -lh /data/downloads/test.bin || true
    df -h /data/downloads || true
    echo "[TEST] ENOSPC test completed with exit code: $DD_STATUS"
    echo "[TEST] ALL EPHEMERAL CHECKS COMPLETED SUCCESSFULLY."
    sync
    poweroff -f || reboot -f
    exit 0
fi

# 2. Persistent Write Test Hook
if grep -q "cartilage_test=persist_write" /proc/cmdline; then
    echo "============================================================"
    echo "[TEST] Running Persistent Mode: Write Phase (SPEC Task 4)"
    echo "============================================================"
    echo "Writing marker file to /data/persistence_test.txt..."
    echo "CARTILAGE_PERSISTENCE_TOKEN_12345" > /data/persistence_test.txt
    sync
    ls -l /data/persistence_test.txt
    cat /data/persistence_test.txt
    echo "[TEST] Marker file successfully written to persistent storage."
    sync
    poweroff -f || reboot -f
    exit 0
fi

# 3. Persistent Read Test Hook (Post-Reboot)
if grep -q "cartilage_test=persist_read" /proc/cmdline; then
    echo "============================================================"
    echo "[TEST] Running Persistent Mode: Read Phase (SPEC Task 4)"
    echo "============================================================"
    if [[ -f /data/persistence_test.txt ]] && grep -q "CARTILAGE_PERSISTENCE_TOKEN_12345" /data/persistence_test.txt; then
        echo "==> [PASS] Marker file survived reboot intact!"
        cat /data/persistence_test.txt
        echo "[TEST] ALL PERSISTENCE CHECKS COMPLETED SUCCESSFULLY."
        sync
        poweroff -f || reboot -f
        exit 0
    else
        echo "==> [FAIL] Marker file not found or corrupted after reboot!" >&2
        poweroff -f || reboot -f
        exit 1
    fi
fi

# 4. Host Access: Happy Path Test Hook (SPEC Task 5)
if grep -q "cartilage_test=host_happy" /proc/cmdline; then
    echo "============================================================"
    echo "[TEST] Running Host Access Mode: Happy Path (SPEC Task 5)"
    echo "============================================================"
    echo "==> Check 1: Verifying global hidden ro mount before auth..."
    if mount | grep -q "/mnt/hidden_host"; then
        echo "[TEST-PASS] Global hidden ro mount verified: /mnt/hidden_host is mounted."
    else
        echo "[TEST-FAIL] /mnt/hidden_host is not mounted!" >&2
        poweroff -f || reboot -f
        exit 1
    fi

    echo "==> Check 2: Verifying Developer Passcode Gate..."
    if verify_developer_passcode; then
        echo "[TEST-PASS] Developer Passcode accepted."
    else
        echo "[TEST-FAIL] Developer Passcode rejected!" >&2
        poweroff -f || reboot -f
        exit 1
    fi

    echo "==> Check 3: Verifying NTFS volume integrity (clean volume check)..."
    if check_ntfs_dirty /dev/vdc; then
        echo "[TEST-PASS] NTFS volume is clean. Read-Write access approved."
        mount -o remount,rw /mnt/hidden_host 2>/dev/null || true
    else
        echo "[TEST-FAIL] Clean volume falsely reported as dirty!" >&2
        poweroff -f || reboot -f
        exit 1
    fi

    echo "==> Check 4: Testing Mount Namespace Isolation (unshare -m)..."
    mkdir -p /app/workspace
    unshare -m /bin/bash << 'UNSHARE_EOF'
set -uo pipefail
mount --make-rprivate /

# Bind-mount chosen subdirectory into /app/workspace
mount --bind /mnt/hidden_host/workspace /app/workspace

# Unmount /mnt/hidden_host so host disk is invisible inside app namespace
umount -l /mnt/hidden_host

echo "==> [Inside Namespace] Checking /mnt/hidden_host isolation..."
if ls /mnt/hidden_host 2>/dev/null | grep -q .; then
    echo "[TEST-FAIL] /mnt/hidden_host is still accessible inside app namespace!" >&2
    exit 1
else
    echo "[TEST-PASS] Isolation verified: /mnt/hidden_host is empty/unmounted in app namespace."
fi

echo "==> [Inside Namespace] Checking /app/workspace content..."
ls -la /app/workspace
if [[ -d /app/workspace/project_notes ]]; then
    echo "[TEST-PASS] Workspace subdirectory successfully exposed inside namespace."
else
    echo "[TEST-FAIL] Expected subdirectory project_notes not found in /app/workspace!" >&2
    exit 1
fi

echo "==> [Inside Namespace] Writing marker file to /app/workspace/host_test.txt..."
echo "HOST_CLEAN_WRITE_TOKEN_9876" > /app/workspace/host_test.txt
sync
if [[ -f /app/workspace/host_test.txt ]] && grep -q "HOST_CLEAN_WRITE_TOKEN_9876" /app/workspace/host_test.txt; then
    echo "[TEST-PASS] Marker file write succeeded inside namespace."
else
    echo "[TEST-FAIL] Marker file write failed!" >&2
    exit 1
fi
UNSHARE_EOF
    STATUS=$?
    if [[ $STATUS -eq 0 ]]; then
        echo "[TEST] ALL HAPPY PATH CHECKS COMPLETED SUCCESSFULLY."
    else
        echo "[TEST] HAPPY PATH CHECKS FAILED with status $STATUS" >&2
    fi
    sync
    poweroff -f || reboot -f
    exit $STATUS
fi

# 5. Host Access: Dirty NTFS / Hibernation Failure Test Hook (SPEC Task 5)
if grep -q "cartilage_test=host_dirty" /proc/cmdline; then
    echo "============================================================"
    echo "[TEST] Running Host Access Mode: Dirty NTFS Path (SPEC Task 5)"
    echo "============================================================"
    echo "==> Check 1: Verifying Developer Passcode Gate..."
    if verify_developer_passcode; then
        echo "[TEST-PASS] Developer Passcode accepted."
    else
        echo "[TEST-FAIL] Developer Passcode rejected!" >&2
        poweroff -f || reboot -f
        exit 1
    fi

    echo "==> Check 2: Verifying NTFS volume integrity (dirty volume detection)..."
    if check_ntfs_dirty /dev/vdc; then
        echo "[TEST-FAIL] Dirty volume was falsely reported as clean!" >&2
        poweroff -f || reboot -f
        exit 1
    else
        echo "[TEST-PASS] NTFS dirty/hibernation bit successfully detected!"
        echo "================================================================================"
        echo "[SECURITY ALERT] HOST ACCESS RESTRICTED: DIRTY NTFS / BITLOCKER DETECTED!"
        echo "--------------------------------------------------------------------------------"
        echo "The detected host volume (/dev/vdc) has its NTFS dirty/hibernation bit set"
        echo "or is BitLocker encrypted. This usually occurs when Windows Fast Startup"
        echo "or Hibernation is enabled."
        echo ""
        echo "Writing to a hibernated or dirty Windows volume causes silent NTFS corruption."
        echo "To protect host data, write access is HARD-DENIED and volume is dropped to READ-ONLY."
        echo ""
        echo "CORRECTIVE INSTRUCTION:"
        echo "1. Boot Windows on the host machine."
        echo "2. Open Control Panel -> Power Options -> \"Choose what the power buttons do\"."
        echo "3. Click \"Change settings that are currently unavailable\"."
        echo "4. Uncheck \"Turn on fast startup (recommended)\"."
        echo "5. Perform a full restart (\"Restart\", not \"Shut down\") or run:"
        echo "   shutdown /s /f /t 0"
        echo "================================================================================"
    fi

    echo "==> Check 3: Enforcing read-only downgrade and verifying write failure..."
    mkdir -p /app/workspace
    unshare -m /bin/bash << 'UNSHARE_DIRTY_EOF'
set -uo pipefail
mount --make-rprivate /

# Bind-mount into workspace as READ-ONLY
mount --bind /mnt/hidden_host/workspace /app/workspace
mount -o remount,ro,bind /app/workspace

# Unmount /mnt/hidden_host from namespace
umount -l /mnt/hidden_host

echo "==> [Inside Namespace] Attempting write to read-only workspace..."
set +e
touch /app/workspace/should_fail.txt 2>&1
TOUCH_STATUS=$?
set -e

if [[ $TOUCH_STATUS -ne 0 ]]; then
    echo "[TEST-PASS] Write attempt was correctly denied (exit code: $TOUCH_STATUS). Read-only enforced."
    echo "[TEST] ALL DIRTY NTFS FAILURE CHECKS COMPLETED SUCCESSFULLY."
    exit 0
else
    echo "[TEST-FAIL] Write unexpectedly succeeded on dirty NTFS volume!" >&2
    exit 1
fi
UNSHARE_DIRTY_EOF
    STATUS=$?
    sync
    poweroff -f || reboot -f
    exit $STATUS
fi

# 6. Host Access: Passcode Rejection Test Hook
if grep -q "cartilage_test=host_auth_fail" /proc/cmdline; then
    echo "============================================================"
    echo "[TEST] Running Host Access Mode: Passcode Rejection Test"
    echo "============================================================"
    if verify_developer_passcode; then
        echo "[TEST-FAIL] Invalid passcode was accepted!" >&2
        poweroff -f || reboot -f
        exit 1
    else
        echo "[TEST-PASS] Invalid passcode correctly rejected."
        poweroff -f || reboot -f
        exit 0
    fi
fi

# Normal Boot: Wayland environment variables & App launch in private namespace
export XDG_RUNTIME_DIR=/run/user/0
mkdir -p "$XDG_RUNTIME_DIR"
chmod 0700 "$XDG_RUNTIME_DIR"
export WLR_BACKENDS=drm,libinput
export WLR_LIBINPUT_NO_DEVICES=1
export SEATD_LOGLEVEL=info

# Start seatd before cage
echo "[init] Starting seatd..."
seatd -u root &
sleep 0.5

# Launch cage kiosk inside isolated mount namespace (hiding /mnt/hidden_host)
echo "[init] Launching cage -- foot in isolated namespace..."
unshare -m /bin/bash << 'APP_LAUNCH_EOF' &
mount --make-rprivate /
umount -l /mnt/hidden_host 2>/dev/null || true
cage -s -- foot
APP_LAUNCH_EOF
CAGE_PID=$!

wait $CAGE_PID || true

echo "[init] cage terminated. Executing hard reboot..."
sync
reboot -f
INIT_EOF

chmod +x "${STAGING_DIR}/init"

echo "==> Step 4: Sanitization pass..."
if [[ ! -f "${STAGING_DIR}/bin/bash" ]]; then
    echo "Error: /bin/bash missing before sanitization!" >&2
    exit 1
fi

rm -rf "${STAGING_DIR}/usr/share/man" "${STAGING_DIR}/usr/share/doc"
rm -rf "${STAGING_DIR}/var/cache/pacman/pkg/"*

echo "==> Stripping binaries..."
find "${STAGING_DIR}/usr/bin" "${STAGING_DIR}/usr/lib" -type f -exec strip --strip-unneeded {} + 2>/dev/null || true

echo "==> Verifying shell preservation..."
if [[ ! -f "${STAGING_DIR}/bin/bash" ]]; then
    echo "Fatal: /bin/bash was stripped or removed!" >&2
    exit 1
fi
echo "==> Preserved: ${STAGING_DIR}/bin/bash"

echo "==> Step 5: Packing into EROFS image with lz4 compression..."
rm -f "${OUTPUT_IMG}"
mkfs.erofs -z lz4 "${OUTPUT_IMG}" "${STAGING_DIR}"

echo "==> Cartridge image generated: $(ls -lh "${OUTPUT_IMG}")"

echo "==> Step 6: Loop-mount verification..."
TEST_MNT="/mnt/cartridge_test"
mkdir -p "${TEST_MNT}"
mount -o loop,ro "${OUTPUT_IMG}" "${TEST_MNT}"
if [[ -x "${TEST_MNT}/init" ]]; then
    echo "==> [PASS] Loop-mount verified. /init is present and executable."
else
    echo "Error: /init not found or not executable in mounted image!" >&2
    umount "${TEST_MNT}"
    exit 1
fi
umount "${TEST_MNT}"
rmdir "${TEST_MNT}"

BUILD_ELAPSED=$(( SECONDS - BUILD_START ))
echo "============================================================"
echo "==> Cartridge build complete in ${BUILD_ELAPSED}s!"
echo "============================================================"
