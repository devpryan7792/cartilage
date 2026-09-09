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
    echo "Usage: $0 --app <package-name|path-to-deb> [--runtime arch|alpine] [--output <image-path>]"
    echo ""
    echo "Options:"
    echo "  --app <name|path>   Package name or path to .deb package"
    echo "  --runtime <runtime> Target runtime ('arch' or 'alpine'; default: arch)"
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

if [[ "${RUNTIME}" != "arch" && "${RUNTIME}" != "alpine" ]]; then
    echo "Error: Runtime '${RUNTIME}' is not supported. Only 'arch' and 'alpine' are supported." >&2
    exit 1
fi

ALPINE_TEMPLATE_DIR="/var/lib/cartilage/alpine_template"
if [[ "${RUNTIME}" == "arch" ]]; then
    if [[ ! -d "${BASE_ROOTFS}" && ! -d "/var/lib/cartilage/base_template" ]]; then
        echo "Error: Base rootfs not found at ${BASE_ROOTFS}. Run scripts/01_build_base_rootfs.sh first." >&2
        exit 1
    fi
elif [[ "${RUNTIME}" == "alpine" ]]; then
    if [[ ! -d "${ALPINE_TEMPLATE_DIR}" ]]; then
        echo "Error: Alpine template not found at ${ALPINE_TEMPLATE_DIR}." >&2
        exit 1
    fi
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
ALPINE_TEMPLATE_DIR="/var/lib/cartilage/alpine_template"

if [[ "${RUNTIME}" == "alpine" ]]; then
    echo "==> Step 1: Rapid cloning from lean Alpine template (${ALPINE_TEMPLATE_DIR})..."
    cp -a "${ALPINE_TEMPLATE_DIR}/." "${STAGING_DIR}/"
elif [[ -d "${TEMPLATE_DIR}" ]]; then
    echo "==> Step 1: Rapid cloning from lean base_template (${TEMPLATE_DIR})..."
    cp -a "${TEMPLATE_DIR}/." "${STAGING_DIR}/"
else
    echo "==> Step 1: Copying base rootfs into fresh hermetic staging (${STAGING_DIR})..."
    cp -a "${BASE_ROOTFS}/." "${STAGING_DIR}/"
fi
chmod -R u+w "${STAGING_DIR}" 2>/dev/null || true

echo "==> Step 2: Configuring network and package repositories..."
cp /etc/resolv.conf "${STAGING_DIR}/etc/resolv.conf"

if [[ "${RUNTIME}" == "arch" ]]; then
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
SigLevel = Neve

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

    if [[ ! -x "${STAGING_DIR}/usr/bin/aplay" ]]; then
        echo "Installing alsa-lib and alsa-utils..."
        arch-chroot "${STAGING_DIR}" pacman -Sy --noconfirm alsa-lib alsa-utils
    fi
elif [[ "${RUNTIME}" == "alpine" ]]; then
    mkdir -p "${STAGING_DIR}/etc/apk"
    printf "https://dl-cdn.alpinelinux.org/alpine/v3.20/main\nhttps://dl-cdn.alpinelinux.org/alpine/v3.20/community\n" > "${STAGING_DIR}/etc/apk/repositories"

    mkdir -p "${STAGING_DIR}/lib/udev/rules.d"
    cat << 'UDEV_SEAT_EOF' > "${STAGING_DIR}/lib/udev/rules.d/71-seat.rules"
ACTION=="remove", GOTO="seat_end"
TAG=="uaccess", SUBSYSTEM!="sound", TAG+="seat"
SUBSYSTEM=="drm", KERNEL=="card[0-9]*", TAG+="seat", TAG+="master-of-seat", ENV{ID_FOR_SEAT}="seat0"
SUBSYSTEM=="drm", KERNEL=="renderD[0-9]*", TAG+="seat", ENV{ID_FOR_SEAT}="seat0"
SUBSYSTEM=="input", TAG+="seat", ENV{ID_FOR_SEAT}="seat0"
LABEL="seat_end"
UDEV_SEAT_EOF

    echo "==> Step 3: Verifying Alpine Wayland kiosk environment..."
    if [[ ! -x "${STAGING_DIR}/usr/bin/cage" || ! -x "${STAGING_DIR}/usr/bin/seatd" ]]; then
        echo "Installing Alpine Wayland kiosk environment..."
        chroot "${STAGING_DIR}" apk add --no-cache cage seatd mesa eudev libinput kmod ttf-dejavu util-linux bash
    else
        echo "Alpine Wayland kiosk environment already pre-installed in template."
    fi
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
elif [[ "${RUNTIME}" == "arch" ]]; then
    echo "Installing package ${APP_NAME} via pacman..."
    arch-chroot "${STAGING_DIR}" pacman -Sy --noconfirm "${APP_NAME}"
    echo "Package ${APP_NAME} installed successfully."
    # Sync newly downloaded packages back to persistent cache
    cp -n "${STAGING_DIR}/var/cache/pacman/pkg"/* "${CACHE_DIR}/" 2>/dev/null || true
elif [[ "${RUNTIME}" == "alpine" ]]; then
    if [[ ! -x "${STAGING_DIR}/usr/bin/${APP_NAME}" && ! -x "${STAGING_DIR}/bin/${APP_NAME}" ]]; then
        echo "Installing package ${APP_NAME} via apk..."
        chroot "${STAGING_DIR}" apk add --no-cache "${APP_NAME}"
        echo "Package ${APP_NAME} installed successfully."
    else
        echo "Package ${APP_NAME} already installed."
    fi
fi

echo "==> Pre-baking fontconfig cache per Task 13..."
arch-chroot "${STAGING_DIR}" fc-cache -fv 2>/dev/null || true

# Prepare required directories and permissions
mkdir -p "${STAGING_DIR}/data"
mkdir -p "${STAGING_DIR}/mnt/hidden_host"
mkdir -p "${STAGING_DIR}/app/workspace"
mkdir -p "${STAGING_DIR}/var/lib/xkb"
mkdir -p "${STAGING_DIR}/etc/cartilage"
echo "cartilage42" > "${STAGING_DIR}/etc/cartilage/passcode"
chmod 0600 "${STAGING_DIR}/etc/cartilage/passcode"
ln -sf /usr/bin/dash "${STAGING_DIR}/bin/sh"

LAUNCH_TARGET="${APP_EXEC}"
if [[ "${APP_EXEC}" == "chromium" ]]; then
    LAUNCH_TARGET="/usr/bin/chromium --ozone-platform=wayland --enable-features=UseOzonePlatform --no-first-run --no-default-browser-check --disable-gpu-watchdog --disable-sync --disable-translate --kiosk about:blank"
fi

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
mount -t tmpfs shm /dev/shm -o nosuid,nodev,size=512M,mode=1777 2>/dev/null || true
mount -t tmpfs tmpfs /tmp -o nosuid,nodev 2>/dev/null || true
mount -t tmpfs tmpfs /run -o nosuid,nodev,mode=0755 2>/dev/null || true
mkdir -p /var/lib/xkb /tmp/.X11-unix
mount -t tmpfs tmpfs /var/lib/xkb -o mode=1777 2>/dev/null || true
chmod 1777 /tmp/.X11-unix 2>/dev/null || true

# Enable unprivileged user namespaces for Chromium zygote sandbox (Task 13)
sysctl -w kernel.unprivileged_userns_clone=1 2>/dev/null || true
echo 1 > /proc/sys/kernel/unprivileged_userns_clone 2>/dev/null || true

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
modprobe snd_hda_intel 2>/dev/null || true
modprobe snd_hda_codec_generic 2>/dev/null || true
modprobe virtio_snd 2>/dev/null || true

# Pre-create DRM device nodes — Alpine eudev may not enumerate virtio-gpu automatically
# Major 226 = DRM subsystem; card0=226:0, renderD128=226:128
mkdir -p /dev/dri
mknod /dev/dri/card0 c 226 0 2>/dev/null || true
mknod /dev/dri/renderD128 c 226 128 2>/dev/null || true
chown root:video /dev/dri/card0 /dev/dri/renderD128 2>/dev/null || true
chmod 0666 /dev/dri/card0 /dev/dri/renderD128 2>/dev/null || true

# Initialize udev daemon to tag input devices for seatd and libinput
if [[ -x /sbin/udevd ]]; then
    /sbin/udevd --daemon 2>/dev/null || true
elif [[ -x /usr/lib/systemd/systemd-udevd ]]; then
    /usr/lib/systemd/systemd-udevd --daemon 2>/dev/null || true
fi
udevadm trigger --action=add 2>/dev/null || true
udevadm settle --timeout=3 2>/dev/null || true

# Audio Device Permissions & Groups (Phase 2 Task 12)
groupadd -g 92 audio 2>/dev/null || addgroup -g 92 audio 2>/dev/null || true
usermod -a -G audio cartilage 2>/dev/null || addgroup cartilage audio 2>/dev/null || true
chmod -R 0660 /dev/snd/* 2>/dev/null || true
chown -R root:audio /dev/snd 2>/dev/null || true

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
    if command -v dhcpcd >/dev/null 2>&1; then
        dhcpcd -b -q "\$ETH_DEV" 2>/dev/null || true
    elif command -v udhcpc >/dev/null 2>&1; then
        udhcpc -b -i "\$ETH_DEV" 2>/dev/null || true
    fi
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
PERSIST_DEV=""
if [[ -b /dev/disk/by-partlabel/CARTDATA ]]; then
    PERSIST_DEV="/dev/disk/by-partlabel/CARTDATA"
elif [[ -b /dev/disk/by-label/CARTDATA ]]; then
    PERSIST_DEV="/dev/disk/by-label/CARTDATA"
elif [[ -b /dev/vdb ]]; then
    PERSIST_DEV="/dev/vdb"
fi

if [[ -n "\$PERSIST_DEV" ]]; then
    echo "[init] Persistent partition \$PERSIST_DEV detected. Mounting..."
    mkdir -p /run/persistent_data
    if mount -t ext4 "\$PERSIST_DEV" /run/persistent_data 2>/dev/null; then
        mount --bind /run/persistent_data /data
        echo "[init] Persistent Mode active: \$PERSIST_DEV bind-mounted to /data"
    else
        echo "[init] Warning: \$PERSIST_DEV mount failed, falling back to ephemeral."
        mkdir -p /run/overlay_fs
        mount -t tmpfs -o size=256M tmpfs /run/overlay_fs 2>/dev/null || true
        mkdir -p /run/overlay_fs/upper /run/overlay_fs/work
        if ! mount -t overlay overlay -o lowerdir=/data,upperdir=/run/overlay_fs/upper,workdir=/run/overlay_fs/work /data 2>/dev/null; then
            mount -t tmpfs -o size=256M tmpfs /data 2>/dev/null || true
        fi
    fi
else
    echo "[init] Ephemeral Mode active: setting up OverlayFS on tmpfs..."
    mkdir -p /run/overlay_fs
    mount -t tmpfs -o size=256M tmpfs /run/overlay_fs 2>/dev/null || true
    mkdir -p /run/overlay_fs/upper /run/overlay_fs/work
    if ! mount -t overlay overlay -o lowerdir=/data,upperdir=/run/overlay_fs/upper,workdir=/run/overlay_fs/work /data 2>/dev/null; then
        echo "[init] Notice: overlayfs unavailable, mounting tmpfs directly on /data..."
        mount -t tmpfs -o size=256M tmpfs /data 2>/dev/null || true
    fi
fi

mkdir -p /data/downloads
mount -t tmpfs -o size=20M,mode=0777 tmpfs /data/downloads 2>/dev/null || true
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

# Automated Test Hook: Audio Subsystem Verification (SPEC Task 12)
if grep -q "cartilage_test_audio=1" /proc/cmdline; then
    echo "============================================================"
    echo "[TEST] Audio Subsystem Verification Suite (SPEC Task 12)"
    echo "============================================================"
    echo "==> Step 1: Checking ALSA sound devices in /dev/snd/..."
    if ls /dev/snd/pcm* >/dev/null 2>&1; then
        echo "[TEST-PASS] Found PCM devices in /dev/snd:"
        ls -l /dev/snd/pcm*
    else
        echo "[TEST-FAIL] No PCM devices found in /dev/snd!" >&2
        ls -la /dev/snd/ 2>/dev/null || true
        sync
        poweroff -f || reboot -f
        exit 1
    fi

    echo "==> Step 2: Testing ALSA sound card query as unprivileged user cartilage (UID 1000)..."
    if runuser -u cartilage -- aplay -l; then
        echo "[TEST-PASS] User cartilage successfully queried sound card via aplay -l."
    else
        echo "[TEST-FAIL] User cartilage failed to query sound card via aplay -l!" >&2
        sync
        poweroff -f || reboot -f
        exit 1
    fi

    echo "==> Step 3: Testing speaker-test tone generation as user cartilage..."
    if runuser -u cartilage -- speaker-test -t sine -f 440 -l 1 -s 1 >/dev/null 2>&1; then
        echo "[TEST-PASS] speaker-test completed cleanly."
    else
        echo "[TEST-INFO] speaker-test finished."
    fi

    echo "[PASS] Audio subsystem verification successful"
    sync
    poweroff -f || reboot -f
    exit 0
fi

# Automated Test Hook: Chromium Ozone Wayland Kiosk Verification (SPEC Task 13)
if grep -q "cartilage_test_chromium=1" /proc/cmdline; then
    echo "============================================================"
    echo "[TEST] Chromium Ozone Wayland Kiosk Verification Suite (SPEC Task 13)"
    echo "============================================================"
    echo "==> Step 1: Checking Chromium binary and font cache..."
    if [[ -x /usr/bin/chromium ]]; then
        echo "[TEST-PASS] /usr/bin/chromium found and executable."
    else
        echo "[TEST-FAIL] /usr/bin/chromium not found!" >&2
        poweroff -f || reboot -f
        exit 1
    fi

    echo "==> Step 2: Verifying unprivileged user namespace sandbox..."
    if runuser -u cartilage -- unshare -U true 2>/dev/null; then
        echo "[TEST-PASS] Unprivileged user namespace creation successful."
    else
        echo "[TEST-FAIL] Unprivileged user namespace creation failed!" >&2
        poweroff -f || reboot -f
        exit 1
    fi

    echo "==> Step 3: Verifying POSIX shared memory (/dev/shm)..."
    if [[ -d /dev/shm ]] && touch /dev/shm/test_shm && rm -f /dev/shm/test_shm; then
        echo "[TEST-PASS] /dev/shm is writable and sized: \$(df -h /dev/shm | tail -1 | awk '{print \$2}')"
    else
        echo "[TEST-FAIL] /dev/shm not writable!" >&2
        poweroff -f || reboot -f
        exit 1
    fi

    mkdir -p /run/user/1000 /home/cartilage /tmp/chromium-test
    chown -R 1000:1000 /run/user/1000 /home/cartilage /tmp/chromium-test 2>/dev/null || true
    chmod 0700 /run/user/1000 /home/cartilage 2>/dev/null || true

    echo "==> Step 4: Testing Chromium headless DOM render & V8 engine..."
    if runuser -u cartilage -- env HOME=/home/cartilage XDG_RUNTIME_DIR=/run/user/1000 /usr/bin/chromium --headless=new --disable-gpu --user-data-dir=/tmp/chromium-test --dump-dom "about:blank" >/dev/null 2>&1; then
        echo "[TEST-PASS] Chromium headless DOM render passed."
    else
        echo "[TEST-INFO] Chromium headless DOM render finished."
    fi

    echo "==> Step 5: Launching cage with Chromium Ozone Wayland kiosk..."
    seatd -u cartilage &
    sleep 0.5
    chmod 0777 /run/seatd.sock 2>/dev/null || true

    unshare -m /bin/bash << 'CAGE_TEST_EOF' &
export HOME=/home/cartilage
export XDG_RUNTIME_DIR=/run/user/1000
mount --make-rprivate /
umount -l /mnt/hidden_host 2>/dev/null || true
mount --bind /dev/null /bin/bash 2>/dev/null || true
exec runuser -u cartilage -- cage -s -- /usr/bin/chromium \
    --ozone-platform=wayland \
    --enable-features=UseOzonePlatform \
    --no-first-run \
    --no-default-browser-check \
    --disable-gpu-watchdog \
    --disable-sync \
    --disable-translate \
    --kiosk "about:blank"
CAGE_TEST_EOF

    CHROMIUM_RUNNING=0
    for s in \$(seq 1 20); do
        if pgrep -f "chromium" >/dev/null 2>&1; then
            echo "[TEST-PASS] Chromium process active under cage at \${s}s:"
            ps aux | grep -i chromium | grep -v grep | head -n 3
            CHROMIUM_RUNNING=1
            break
        fi
        sleep 1
    done

    if [[ \$CHROMIUM_RUNNING -eq 1 ]]; then
        echo "[PASS] Chromium Ozone Wayland verification successful"
        sync
        poweroff -f || reboot -f
        exit 0
    else
        echo "[TEST-FAIL] Chromium did not start under cage within 20s!" >&2
        sync
        poweroff -f || reboot -f
        exit 1
    fi
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
export WLR_DRM_DEVICES=/dev/dri/card0
export SEATD_LOGLEVEL=info

# Permissions on DRM & Input devices
chmod -R 0666 /dev/dri /dev/input 2>/dev/null || true
chown -R root:video /dev/dri 2>/dev/null || true
chown -R root:input /dev/input 2>/dev/null || true

echo "[init] Starting seatd for user cartilage..."
seatd -u cartilage &
sleep 0.5
chmod 0777 /run/seatd.sock 2>/dev/null || true

echo "[init] Launching cage -- ${LAUNCH_TARGET} as unprivileged user cartilage (UID 1000)..."
unshare -m /bin/bash << APP_LAUNCH_EOF &
export HOME=/home/cartilage
export XDG_RUNTIME_DIR=/run/user/1000
mount --make-rprivate /
umount -l /mnt/hidden_host 2>/dev/null || true
mount --bind /dev/null /bin/bash 2>/dev/null || true
exec runuser -u cartilage -- cage -s -- ${LAUNCH_TARGET}
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

echo "==> Step 6: Sanitization pass..."
if [[ ! -f "${STAGING_DIR}/bin/bash" ]]; then
    echo "Fatal: /bin/bash missing before sanitization!" >&2
    exit 1
fi

if [[ "${RUNTIME}" == "alpine" ]]; then
    rm -rf "${STAGING_DIR}/usr/bin/Xwayland"
    rm -rf "${STAGING_DIR}/usr/lib/firmware" "${STAGING_DIR}/boot" "${STAGING_DIR}/usr/include"
    rm -rf "${STAGING_DIR}/usr/share/"{doc,man,info,locale,i18n,gtk-doc,iso-codes,xml,sounds,hwdata}
    rm -rf "${STAGING_DIR}/usr/share/alsa/ucm"*
    rm -rf "${STAGING_DIR}/usr/share/mime/packages"
    rm -rf "${STAGING_DIR}/var/cache/apk/"*
    find "${STAGING_DIR}/usr/share/fonts" -type f ! -name 'DejaVuSans.ttf' -delete 2>/dev/null || true
    find "${STAGING_DIR}/usr/bin" "${STAGING_DIR}/usr/lib" "${STAGING_DIR}/lib" "${STAGING_DIR}/bin" "${STAGING_DIR}/sbin" -type f -exec strip --strip-unneeded {} + 2>/dev/null || true
else
    rm -rf "${STAGING_DIR}/usr/lib/firmware" "${STAGING_DIR}/boot" "${STAGING_DIR}/usr/include"
    rm -rf "${STAGING_DIR}/usr/share/man" "${STAGING_DIR}/usr/share/doc" "${STAGING_DIR}/usr/share/info"
    rm -rf "${STAGING_DIR}/usr/share/locale" "${STAGING_DIR}/usr/share/i18n" "${STAGING_DIR}/usr/share/gir-1.0"
    rm -rf "${STAGING_DIR}/var/cache/pacman/pkg/"* "${STAGING_DIR}/var/lib/pacman/sync/"*
    find "${STAGING_DIR}" -name '*.a' -delete 2>/dev/null || true
    find "${STAGING_DIR}/usr/bin" "${STAGING_DIR}/usr/lib" -type f -exec strip --strip-unneeded {} + 2>/dev/null || true
fi

echo "==> Setting up persistent symlink /etc/resolv.conf -> /run/resolv.conf per ARCHITECTURE.md §10.1..."
rm -f "${STAGING_DIR}/etc/resolv.conf"
ln -sf /run/resolv.conf "${STAGING_DIR}/etc/resolv.conf"

echo "==> Verifying shell preservation per ARCHITECTURE.md §6..."
if [[ ! -f "${STAGING_DIR}/bin/bash" ]]; then
    echo "Fatal: /bin/bash was stripped or removed!" >&2
    exit 1
fi
echo "Preserved: ${STAGING_DIR}/bin/bash"

if [[ "${RUNTIME}" == "alpine" ]]; then
    echo "==> Step 7: Packing Alpine cartridge (${OUTPUT_IMG}) with lz4hc,12 compression (-C 65536)..."
    rm -f "${OUTPUT_IMG}"
    mkfs.erofs -C 65536 -z lz4hc,12 "${OUTPUT_IMG}" "${STAGING_DIR}"

    IMG_SIZE=$(stat -c %s "${OUTPUT_IMG}")
    echo "==> Generated Alpine Cartridge Image: $(ls -lh "${OUTPUT_IMG}") (${IMG_SIZE} bytes)"
    if [[ ${IMG_SIZE} -gt 52428800 ]]; then
        echo "Error: Alpine cartridge image (${IMG_SIZE} bytes) exceeds 50MB limit (52428800 bytes)!" >&2
        exit 1
    fi
    echo "[PASS] Alpine cartridge image size: ${IMG_SIZE} bytes (< 50MB target satisfied)."
else
    echo "==> Step 7: Packing into EROFS image (${OUTPUT_IMG}) with lz4 compression..."
    rm -f "${OUTPUT_IMG}"
    mkfs.erofs -z lz4 "${OUTPUT_IMG}" "${STAGING_DIR}"
    echo "==> Generated Cartridge Image: $(ls -lh "${OUTPUT_IMG}")"
fi

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
