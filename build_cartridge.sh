#!/usr/bin/env bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    exec sudo bash "$0" "$@"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}"
BUILD_DIR="${REPO_ROOT}/build"
BASE_ROOTFS="/var/lib/cartilage/rootfs"
CACHE_DIR="/var/lib/cartilage/pacman-cache"

# Default options
APP_INPUT=""
RUNTIME="arch"
OUTPUT_IMG=""

usage() {
    echo "Usage: $0 --app <package-name|path-to-deb> [--runtime arch] [--output <image-path>]"
    echo ""
    echo "Options:"
    echo "  --app <name|path>   Arch package name or path to .deb package"
    echo "  --runtime <runtime> Target runtime ('arch' is supported in v1; default: arch)"
    echo "  --output <path>     Path to output .img file (default: build/cartridge_<app>.img)"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --app)
            APP_INPUT="${2:-}"
            shift 2
            ;;
        --runtime)
            RUNTIME="${2:-}"
            shift 2
            ;;
        --output)
            OUTPUT_IMG="${2:-}"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Error: Unknown argument '$1'" >&2
            usage
            exit 1
            ;;
    esac
done

if [[ -z "${APP_INPUT}" ]]; then
    echo "Error: --app is required." >&2
    usage
    exit 1
fi

if [[ "${RUNTIME}" != "arch" ]]; then
    echo "Error: Runtime '${RUNTIME}' is not supported in v1. Only 'arch' is supported." >&2
    exit 1
fi

if [[ ! -d "${BASE_ROOTFS}" ]]; then
    echo "Error: Base rootfs not found at ${BASE_ROOTFS}. Run scripts/01_build_base_rootfs.sh first." >&2
    exit 1
fi

# Detect whether input is a .deb file or repository package
IS_DEB=0
if [[ -f "${APP_INPUT}" && "${APP_INPUT}" == *.deb ]]; then
    IS_DEB=1
    APP_NAME="$(basename "${APP_INPUT}" .deb)"
    APP_NAME="$(echo "${APP_NAME}" | cut -d'_' -f1)"
else
    APP_NAME="${APP_INPUT}"
fi

if [[ -z "${OUTPUT_IMG}" ]]; then
    OUTPUT_IMG="${BUILD_DIR}/cartridge_${APP_NAME}.img"
fi

mkdir -p "${BUILD_DIR}"

echo "============================================================"
echo "Cartilage OS — Cartridge Builder CLI (Module 4)"
echo "Target App:  ${APP_NAME} (Input: ${APP_INPUT}, is_deb=${IS_DEB})"
echo "Runtime:     ${RUNTIME}"
echo "Base Rootfs: ${BASE_ROOTFS}"
echo "Output:      ${OUTPUT_IMG}"
echo "============================================================"

BUILD_START=$SECONDS

# Create hermetic, temporary staging directory on native ext4
STAGING_DIR="$(mktemp -d /var/lib/cartilage/cartridge-staging-${APP_NAME}-XXXXXX)"
trap 'chmod -R u+w "${STAGING_DIR}" 2>/dev/null || true; rm -rf "${STAGING_DIR}" 2>/dev/null || true' EXIT INT TERM

TEMPLATE_DIR="/var/lib/cartilage/base_template"
if [[ -d "${TEMPLATE_DIR}" ]]; then
    echo "==> Step 1: Rapid cloning from lean base_template (${TEMPLATE_DIR})..."
    cp -a "${TEMPLATE_DIR}/." "${STAGING_DIR}/"
else
    echo "==> Step 1: Copying base rootfs into fresh hermetic staging (${STAGING_DIR})..."
    cp -a "${BASE_ROOTFS}/." "${STAGING_DIR}/"
fi
chmod -R u+w "${STAGING_DIR}" 2>/dev/null || true

echo "==> Step 2: Configuring network, cache, and pacman repositories..."
cp /etc/resolv.conf "${STAGING_DIR}/etc/resolv.conf"
mkdir -p "${STAGING_DIR}/var/cache/pacman/pkg"
mkdir -p "${STAGING_DIR}/etc/pacman.d"
cp "${BUILD_DIR}/mirrorlist" "${STAGING_DIR}/etc/pacman.d/mirrorlist"

# Use persistent pacman cache to accelerate hermetic builds
mkdir -p "${CACHE_DIR}"
cp -n "${CACHE_DIR}"/* "${STAGING_DIR}/var/cache/pacman/pkg/" 2>/dev/null || true

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

echo "==> Step 3: Verifying Wayland kiosk environment and network utilities..."
if [[ ! -x "${STAGING_DIR}/usr/bin/cage" ]]; then
    echo "Installing Wayland kiosk environment and core tools..."
    arch-chroot "${STAGING_DIR}" pacman -Sy --noconfirm cage seatd mesa foot libglvnd kmod ttf-dejavu util-linux e2fsprogs ntfsprogs xorg-xwayland xorg-xkbcomp xkeyboard-config grim dash
else
    echo "Wayland kiosk environment already pre-installed in base template."
fi

if [[ ! -x "${STAGING_DIR}/usr/bin/dhcpcd" ]]; then
    echo "Installing dhcpcd network client..."
    arch-chroot "${STAGING_DIR}" pacman -Sy --noconfirm dhcpcd
fi

if [[ ! -x "${STAGING_DIR}/usr/bin/curl" ]]; then
    echo "Installing curl utility..."
    arch-chroot "${STAGING_DIR}" pacman -Sy --noconfirm curl
fi

echo "==> Step 4: Installing target application (${APP_NAME})..."
APP_EXEC="${APP_NAME}"
if [[ ${IS_DEB} -eq 1 ]]; then
    echo "Extracting Debian package ${APP_INPUT}..."
    if command -v dpkg-deb >/dev/null 2>&1; then
        dpkg-deb -x "${APP_INPUT}" "${STAGING_DIR}"
    else
        ar -p "${APP_INPUT}" data.tar.* | tar -xf - -C "${STAGING_DIR}"
    fi
    # Find executable in /usr/bin or /bin
    if [[ ! -x "${STAGING_DIR}/usr/bin/${APP_NAME}" ]]; then
        FOUND_BIN=$(find "${STAGING_DIR}/usr/bin" -type f -perm -111 2>/dev/null | head -n 1)
        if [[ -n "${FOUND_BIN}" ]]; then
            APP_EXEC="$(basename "${FOUND_BIN}")"
        fi
    fi
    echo "Debian package extracted. Selected executable: ${APP_EXEC}"
else
    echo "Installing package ${APP_NAME} via pacman..."
    arch-chroot "${STAGING_DIR}" pacman -S --noconfirm "${APP_NAME}"
    echo "Package ${APP_NAME} installed successfully."
fi

# Sync newly downloaded packages back to persistent cache
cp -n "${STAGING_DIR}/var/cache/pacman/pkg"/* "${CACHE_DIR}/" 2>/dev/null || true

# Prepare required directories and permissions
mkdir -p "${STAGING_DIR}/data"
mkdir -p "${STAGING_DIR}/mnt/hidden_host"
mkdir -p "${STAGING_DIR}/app/workspace"
mkdir -p "${STAGING_DIR}/var/lib/xkb"
mkdir -p "${STAGING_DIR}/etc/cartilage"
echo "cartilage42" > "${STAGING_DIR}/etc/cartilage/passcode"
chmod 0600 "${STAGING_DIR}/etc/cartilage/passcode"
ln -sf /usr/bin/dash "${STAGING_DIR}/bin/sh"

echo "==> Step 5: Writing custom PID 1 /init configured for ${APP_EXEC}..."
cat << INIT_EOF > "${STAGING_DIR}/init"
#!/bin/bash
set -euo pipefail

echo "============================================================"
echo "[init] Cartilage OS Cartridge Initializing (PID 1)"
echo "[init] Target Application: ${APP_EXEC}"
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
mkdir -p /var/lib/xkb /tmp/.X11-unix
mount -t tmpfs tmpfs /var/lib/xkb -o mode=1777 2>/dev/null || true
chmod 1777 /tmp/.X11-unix 2>/dev/null || true

# Load drivers & modules
modprobe drm 2>/dev/null || true
modprobe virtio_gpu 2>/dev/null || true
modprobe bochs 2>/dev/null || true
modprobe overlay 2>/dev/null || true
modprobe zram num_devices=1 2>/dev/null || true
modprobe ext4 2>/dev/null || true
modprobe ntfs3 2>/dev/null || true
modprobe ntfs 2>/dev/null || true
modprobe evdev 2>/dev/null || true
modprobe virtio_input 2>/dev/null || true
modprobe psmouse 2>/dev/null || true
modprobe atkbd 2>/dev/null || true
modprobe usbhid 2>/dev/null || true
modprobe hid_generic 2>/dev/null || true
modprobe virtio_net 2>/dev/null || true

# Initialize udev daemon to tag input devices for seatd and libinput
/usr/lib/systemd/systemd-udevd --daemon 2>/dev/null || true
udevadm trigger --action=add 2>/dev/null || true
udevadm settle --timeout=3 2>/dev/null || true

# Network & DNS Subsystem (Phase 2 Task 11)
echo "[init] Initializing Network & DNS Subsystem..."
ip link set lo up 2>/dev/null || true

ETH_DEV=""
for iface in /sys/class/net/eth* /sys/class/net/ens* /sys/class/net/enp*; do
    if [[ -e "\$iface" ]]; then
        ETH_DEV="\$(basename "\$iface")"
        break
    fi
done
if [[ -z "\$ETH_DEV" ]]; then
    for iface in /sys/class/net/*; do
        dev="\$(basename "\$iface")"
        if [[ "\$dev" != "lo" && -e "\$iface" ]]; then
            ETH_DEV="\$dev"
            break
        fi
    done
fi

if [[ -n "\$ETH_DEV" ]]; then
    echo "[init] Primary ethernet interface detected: \$ETH_DEV"
    ip link set "\$ETH_DEV" up 2>/dev/null || true
    dhcpcd -b -q "\$ETH_DEV" 2>/dev/null || true
else
    echo "[init] No ethernet interface detected."
fi

mkdir -p /run
printf "nameserver 1.1.1.1\nnameserver 9.9.9.9\n" > /run/resolv.conf
chmod 0644 /run/resolv.conf 2>/dev/null || true
ln -sf /run/resolv.conf /etc/resolv.conf 2>/dev/null || true
if [[ ! -L /etc/resolv.conf ]]; then
    mount --bind /run/resolv.conf /etc/resolv.conf 2>/dev/null || true
fi

# Helper: Developer Passcode Verification (Shared across Host Access & Debug Console)
verify_developer_passcode() {
    local input="\${1:-}"
    local default_pass="cartilage42"
    local expected="\$default_pass"
    if [[ -f /etc/cartilage/passcode ]]; then
        expected="\$(cat /etc/cartilage/passcode)"
    fi
    if [[ -z "\$input" ]]; then
        for arg in \$(cat /proc/cmdline); do
            if [[ "\$arg" =~ ^host_passcode=(.*)$ ]]; then
                input="\${BASH_REMATCH[1]}"
            fi
        done
    fi
    if [[ -z "\$input" ]]; then
        read -s -p "[auth] Enter Developer Passcode: " input
        echo ""
    fi
    if [[ "\$input" == "\$expected" ]]; then
        echo "[auth] Developer Passcode verified successfully."
        return 0
    else
        echo "[auth] Authentication failed: invalid passcode." >&2
        return 1
    fi
}

# Helper: NTFS Dirty Bit & BitLocker Detection
check_ntfs_dirty() {
    local dev="\$1"
    if blkid "\$dev" 2>/dev/null | grep -qi "bitlocker"; then
        return 1
    fi
    if ntfsinfo "\$dev" 2>&1 | grep -qi "scheduled for check"; then
        return 1
    fi
    if ntfsinfo -f -i 3 "\$dev" 2>&1 | grep "Volume Flags" | grep -qi "DIRTY"; then
        return 1
    fi
    return 0
}

# Module 3: Storage Setup (Persistent vs Ephemeral Mode)
mkdir -p /data
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
    echo "[init] Ephemeral Mode active: setting up OverlayFS on tmpfs..."
    mkdir -p /run/overlay_fs
    mount -t tmpfs -o size=256M tmpfs /run/overlay_fs
    mkdir -p /run/overlay_fs/upper /run/overlay_fs/work
    mount -t overlay overlay -o lowerdir=/data,upperdir=/run/overlay_fs/upper,workdir=/run/overlay_fs/work /data
fi

mkdir -p /data/downloads
mount -t tmpfs -o size=20M,mode=0777 tmpfs /data/downloads
export XDG_DOWNLOAD_DIR=/data/downloads

echo "[init] Configuring zram0 swap (zstd)..."
zramctl -f -s 512M -a zstd 2>/dev/null || zramctl /dev/zram0 -s 512M -a zstd 2>/dev/null || true
mkswap /dev/zram0 2>/dev/null || true
swapon -p 32767 /dev/zram0 2>/dev/null || true
zramctl 2>/dev/null || true

mkdir -p /mnt/hidden_host
if [[ -b /dev/vdc ]]; then
    echo "[init] Host disk /dev/vdc detected. Mounting ro globally at /mnt/hidden_host..."
    mount -t ntfs3 -o ro,iocharset=utf8 /dev/vdc /mnt/hidden_host 2>/dev/null ||     mount -o ro /dev/vdc /mnt/hidden_host 2>/dev/null || true
    echo "[init] Host disk /dev/vdc mounted ro globally at /mnt/hidden_host."
fi

# Automated Test Hook: Network & DNS Verification (SPEC Task 11)
if grep -q "cartilage_test_net=1" /proc/cmdline; then
    echo "============================================================"
    echo "[TEST] Network & DNS Verification Suite (SPEC Task 11)"
    echo "============================================================"
    echo "==> Step 1: Waiting up to 10s for IP lease on \${ETH_DEV:-none}..."
    HAS_IP=0
    for i in \$(seq 1 10); do
        if [[ -n "\$ETH_DEV" ]] && ip addr show "\$ETH_DEV" 2>/dev/null | grep -q "inet "; then
            HAS_IP=1
            echo "[TEST-INFO] IP lease acquired on \$ETH_DEV at \${i}s:"
            ip addr show "\$ETH_DEV" | grep "inet "
            break
        fi
        sleep 1
    done

    if [[ \$HAS_IP -eq 0 ]]; then
        echo "[TEST-FAIL] Failed to obtain IP address on \$ETH_DEV within 10s!" >&2
        ip addr show 2>/dev/null || true
        sync
        poweroff -f || reboot -f
        exit 1
    fi

    echo "==> Step 2: Testing direct IP connectivity (https://1.1.1.1)..."
    if curl -k -s -I --connect-timeout 5 https://1.1.1.1 | head -n 5; then
        echo "[TEST-PASS] Direct IP connectivity (1.1.1.1) successful."
    else
        echo "[TEST-FAIL] Connection to https://1.1.1.1 failed!" >&2
        sync
        poweroff -f || reboot -f
        exit 1
    fi

    echo "==> Step 3: Testing DNS lookup & HTTP connection (archlinux.org)..."
    DNS_OK=0
    if getent hosts archlinux.org >/dev/null 2>&1; then
        DNS_OK=1
    elif curl -k -s -I --connect-timeout 5 https://archlinux.org >/dev/null 2>&1; then
        DNS_OK=1
    fi

    if [[ \$DNS_OK -eq 1 ]]; then
        echo "[TEST-PASS] DNS lookup for archlinux.org successful."
    else
        echo "[TEST-FAIL] DNS resolution failed!" >&2
        echo "resolv.conf:"
        cat /etc/resolv.conf 2>/dev/null || true
        sync
        poweroff -f || reboot -f
        exit 1
    fi

    echo "[PASS] Network & DNS verification successful"
    sync
    poweroff -f || reboot -f
    exit 0
fi

# Automated Test Hook: App Verification Hook
if grep -q "cartilage_test=verify_app" /proc/cmdline; then
    echo "============================================================"
    echo "[TEST] Cartridge Verification Hook: ${APP_EXEC}"
    echo "============================================================"
    echo "==> Verifying application binary exists and is executable..."
    if command -v "${APP_EXEC}" >/dev/null 2>&1 || [[ -x "/usr/bin/${APP_EXEC}" ]]; then
        echo "[TEST-PASS] Application binary ${APP_EXEC} is present and executable at $(command -v "${APP_EXEC}" 2>/dev/null || echo "/usr/bin/${APP_EXEC}")."
    else
        echo "[TEST-FAIL] Binary ${APP_EXEC} not found in PATH!" >&2
        poweroff -f || reboot -f
        exit 1
    fi
    echo "==> Verifying Wayland compositor cage is present..."
    if command -v cage >/dev/null 2>&1; then
        echo "[TEST-PASS] Compositor cage is present at $(command -v cage)."
    else
        echo "[TEST-FAIL] cage compositor not found!" >&2
        poweroff -f || reboot -f
        exit 1
    fi
    echo "==> Verifying seatd is present..."
    if command -v seatd >/dev/null 2>&1; then
        echo "[TEST-PASS] seatd is present at $(command -v seatd)."
    else
        echo "[TEST-FAIL] seatd not found!" >&2
        poweroff -f || reboot -f
        exit 1
    fi
    echo "[TEST] CARTRIDGE VERIFICATION FOR ${APP_EXEC} SUCCEEDED."
    sync
    poweroff -f || reboot -f
    exit 0
fi

# Automated Test Hook: Debug Console Verification (SPEC Task 8)
if grep -q "cartilage_test=verify_debug_console" /proc/cmdline; then
    echo "============================================================"
    echo "[TEST] Debug Console Verification Suite (SPEC Task 8)"
    echo "============================================================"
    echo "==> Check 1: Verifying Developer Passcode Gate on Debug Console..."
    if verify_developer_passcode; then
        echo "[TEST-PASS] Developer Passcode accepted."
    else
        echo "[TEST-FAIL] Developer Passcode rejected!" >&2
        poweroff -f || reboot -f
        exit 1
    fi

    echo "==> Check 2: Executing diagnostic command: dmesg | tail -5..."
    dmesg | tail -5
    echo "[TEST-PASS] dmesg output produced successfully."

    echo "==> Check 3: Executing diagnostic command: ip link show..."
    ip link show
    echo "[TEST-PASS] ip link show produced successfully."

    echo "==> Check 4: Executing diagnostic command: free -h..."
    free -h
    echo "[TEST-PASS] free -h produced successfully."

    echo "==> Check 5: Verifying App Sandbox Isolation & Masking..."
    unshare -m /bin/bash << 'SANDBOX_ISOLATION_EOF'
set -uo pipefail
mount --make-rprivate /
umount -l /mnt/hidden_host 2>/dev/null || true
mount --bind /dev/null /bin/bash 2>/dev/null || true
mount --bind /dev/null /bin/sh 2>/dev/null || true

echo "==> [Inside App Sandbox] Testing execution of /bin/bash..."
if /bin/bash -c "echo fail" 2>/dev/null; then
    echo "[TEST-FAIL] App namespace was able to execute /bin/bash!" >&2
    exit 1
else
    echo "[TEST-PASS] App sandbox cannot execute /bin/bash (masked with /dev/null)."
fi

echo "==> [Inside App Sandbox] Checking /mnt/hidden_host invisibility..."
if ls /mnt/hidden_host 2>/dev/null | grep -q .; then
    echo "[TEST-FAIL] /mnt/hidden_host visible inside app sandbox!" >&2
    exit 1
else
    echo "[TEST-PASS] Isolation verified: /mnt/hidden_host is unmounted/inaccessible in app sandbox."
fi
SANDBOX_ISOLATION_EOF
    STATUS=\$?
    if [[ \$STATUS -eq 0 ]]; then
        echo "[TEST] ALL DEBUG CONSOLE CHECKS COMPLETED SUCCESSFULLY."
    else
        echo "[TEST] DEBUG CONSOLE CHECKS FAILED with status \$STATUS" >&2
    fi
    sync
    poweroff -f || reboot -f
    exit \$STATUS
fi

# Automated Test Hook: Debug Console Rejection Test
if grep -q "cartilage_test=debug_auth_fail" /proc/cmdline; then
    echo "============================================================"
    echo "[TEST] Debug Console Passcode Rejection Test"
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

# Launch background VT2 Debug Console gated by Developer Passcode
(
    while true; do
        if [[ -c /dev/tty2 ]]; then
            exec </dev/tty2 >/dev/tty2 2>&1
            echo ""
            echo "============================================================"
            echo "Cartilage OS — Physical Debug Console (VT2)"
            echo "============================================================"
            if verify_developer_passcode; then
                echo "Access granted. Launching debug shell (/bin/bash)..."
                echo "Use 'exit' to log out."
                /bin/bash --login || true
            else
                echo "Authentication failed. Re-prompting..."
                sleep 2
            fi
        else
            sleep 1
        fi
    done
) &

# Wayland & Desktop environment variables for unprivileged user cartilage (UID 1000)
export XDG_RUNTIME_DIR=/run/user/1000
mkdir -p "\$XDG_RUNTIME_DIR"
chown 1000:1000 "\$XDG_RUNTIME_DIR" 2>/dev/null || true
chmod 0700 "\$XDG_RUNTIME_DIR"
mkdir -p /home/cartilage 2>/dev/null || true
mount -t tmpfs tmpfs /home/cartilage -o mode=0700,uid=1000,gid=1000 2>/dev/null || true
chown -R 1000:1000 /data 2>/dev/null || true
export HOME=/home/cartilage
export WLR_BACKENDS=drm,libinput
export WLR_LIBINPUT_NO_DEVICES=1
export WLR_RENDERER_ALLOW_SOFTWARE=1
export SEATD_LOGLEVEL=info

echo "[init] Starting seatd for user cartilage..."
seatd -u cartilage &
sleep 0.5
chmod 0777 /run/seatd.sock 2>/dev/null || true

echo "[init] Launching cage -- ${APP_EXEC} as unprivileged user cartilage (UID 1000)..."
unshare -m /bin/bash << APP_LAUNCH_EOF &
export HOME=/home/cartilage
export XDG_RUNTIME_DIR=/run/user/1000
mount --make-rprivate /
umount -l /mnt/hidden_host 2>/dev/null || true
mount --bind /dev/null /bin/bash 2>/dev/null || true
exec runuser -u cartilage -- cage -s -- ${APP_EXEC}
APP_LAUNCH_EOF
CAGE_PID=\$!

# Automated Benchmark Hook (SPEC Task 9)
if grep -q "cartilage_benchmark=1" /proc/cmdline; then
    (
        echo "[benchmark] Waiting 10s post-launch to measure idle RAM..."
        sleep 10
        echo "============================================================"
        echo "[BENCHMARK] Idle RAM usage (10s post-launch):"
        echo "============================================================"
        free -h
        echo "============================================================"
        echo "[BENCHMARK] Monotonic uptime at measurement: \$(cat /proc/uptime 2>/dev/null | cut -d' ' -f1)s"
        echo "============================================================"
        sync
        poweroff -f || reboot -f
    ) &
fi

# Automated Screenshot Hook
if grep -q "cartilage_screenshot=1" /proc/cmdline; then
    (
        echo "[screenshot] Waiting 4s for Wayland compositor and application to draw..."
        sleep 4
        mkdir -p /mnt/screendisk
        mount /dev/vdb /mnt/screendisk 2>/dev/null || mount /dev/sdb /mnt/screendisk 2>/dev/null || true
        export XDG_RUNTIME_DIR=/run/user/0
        export WAYLAND_DISPLAY=wayland-0
        echo "[screenshot] Capturing frame with grim..."
        grim /mnt/screendisk/shot.png 2>&1 || true
        echo "[screenshot] Frame capture complete: \$(ls -lh /mnt/screendisk/shot.png 2>/dev/null)"
        sync
        poweroff -f || reboot -f
    ) &
fi

wait \$CAGE_PID || true

echo "[init] cage terminated. Executing hard reboot..."
sync
reboot -f
INIT_EOF

chmod +x "${STAGING_DIR}/init"

echo "==> Step 6: Sanitization pass (cleaning firmware, boot, headers, man, docs, pacman cache)..."
if [[ ! -f "${STAGING_DIR}/bin/bash" ]]; then
    echo "Fatal: /bin/bash missing before sanitization!" >&2
    exit 1
fi

rm -rf "${STAGING_DIR}/usr/lib/firmware" "${STAGING_DIR}/boot" "${STAGING_DIR}/usr/include"
rm -rf "${STAGING_DIR}/usr/share/man" "${STAGING_DIR}/usr/share/doc" "${STAGING_DIR}/usr/share/info"
rm -rf "${STAGING_DIR}/usr/share/locale" "${STAGING_DIR}/usr/share/i18n" "${STAGING_DIR}/usr/share/gir-1.0"
rm -rf "${STAGING_DIR}/var/cache/pacman/pkg/"* "${STAGING_DIR}/var/lib/pacman/sync/"*
find "${STAGING_DIR}" -name '*.a' -delete 2>/dev/null || true

echo "==> Setting up persistent symlink /etc/resolv.conf -> /run/resolv.conf per ARCHITECTURE.md §10.1..."
rm -f "${STAGING_DIR}/etc/resolv.conf"
ln -sf /run/resolv.conf "${STAGING_DIR}/etc/resolv.conf"

echo "==> Stripping unneeded binary symbols..."
find "${STAGING_DIR}/usr/bin" "${STAGING_DIR}/usr/lib" -type f -exec strip --strip-unneeded {} + 2>/dev/null || true

echo "==> Verifying shell preservation per ARCHITECTURE.md §6..."
if [[ ! -f "${STAGING_DIR}/bin/bash" ]]; then
    echo "Fatal: /bin/bash was stripped or removed!" >&2
    exit 1
fi
echo "Preserved: ${STAGING_DIR}/bin/bash"

echo "==> Step 7: Packing into EROFS image (${OUTPUT_IMG}) with lz4 compression..."
rm -f "${OUTPUT_IMG}"
mkfs.erofs -z lz4 "${OUTPUT_IMG}" "${STAGING_DIR}"

echo "==> Generated Cartridge Image: $(ls -lh "${OUTPUT_IMG}")"

echo "==> Step 8: Loop-mount verification..."
TEST_MNT="/mnt/cartridge_verify_$$"
mkdir -p "${TEST_MNT}"
mount -o loop,ro "${OUTPUT_IMG}" "${TEST_MNT}"
if [[ -x "${TEST_MNT}/init" ]]; then
    echo "[PASS] Loop-mount verified: /init is present and executable."
else
    echo "Error: /init not executable in mounted image!" >&2
    umount "${TEST_MNT}"
    rmdir "${TEST_MNT}"
    exit 1
fi
umount "${TEST_MNT}"
rmdir "${TEST_MNT}"

BUILD_ELAPSED=$(( SECONDS - BUILD_START ))
echo "============================================================"
echo "Cartilage OS — Build finished successfully for ${APP_NAME} in ${BUILD_ELAPSED}s!"
echo "Output: ${OUTPUT_IMG}"
echo "============================================================"
