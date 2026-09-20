#!/usr/bin/env bash
set -euo pipefail

for arg in "$@"; do
    if [[ "$arg" == "-h" || "$arg" == "--help" ]]; then
        echo "Usage: $0 --app <package-name|path-to-deb> [--runtime arch|alpine] [--output <image-path>]"
        exit 0
    fi
done

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
        echo "==> Alpine template not found at ${ALPINE_TEMPLATE_DIR}. Bootstrapping..."
        mkdir -p "${ALPINE_TEMPLATE_DIR}"
        ALPINE_TAR="/var/lib/cartilage/alpine_cache/alpine-minirootfs.tar.gz"
        if [[ ! -f "${ALPINE_TAR}" ]]; then
            mkdir -p /var/lib/cartilage/alpine_cache
            curl -fsSL https://dl-cdn.alpinelinux.org/alpine/v3.20/releases/x86_64/alpine-minirootfs-3.20.3-x86_64.tar.gz -o "${ALPINE_TAR}"
        fi
        tar -xzf "${ALPINE_TAR}" -C "${ALPINE_TEMPLATE_DIR}"
        cp /etc/resolv.conf "${ALPINE_TEMPLATE_DIR}/etc/resolv.conf" 2>/dev/null || true
        mkdir -p "${ALPINE_TEMPLATE_DIR}/etc/apk"
        cat << 'ALPINE_REPO_EOF' > "${ALPINE_TEMPLATE_DIR}/etc/apk/repositories"
https://dl-cdn.alpinelinux.org/alpine/v3.20/main
https://dl-cdn.alpinelinux.org/alpine/v3.20/community
ALPINE_REPO_EOF
        chroot "${ALPINE_TEMPLATE_DIR}" apk update
        chroot "${ALPINE_TEMPLATE_DIR}" apk add --no-cache cage seatd mesa eudev libinput kmod ttf-dejavu util-linux bash mousepad
        chroot "${ALPINE_TEMPLATE_DIR}" adduser -D -u 1000 -s /bin/bash cartilage 2>/dev/null || true
        chroot "${ALPINE_TEMPLATE_DIR}" addgroup cartilage video 2>/dev/null || true
        chroot "${ALPINE_TEMPLATE_DIR}" addgroup cartilage input 2>/dev/null || true
        chroot "${ALPINE_TEMPLATE_DIR}" addgroup cartilage audio 2>/dev/null || true
        mkdir -p "${ALPINE_TEMPLATE_DIR}/lib/udev/rules.d"
        cat << 'UDEV_EOF' > "${ALPINE_TEMPLATE_DIR}/lib/udev/rules.d/71-seat.rules"
ACTION=="remove", GOTO="seat_end"
TAG=="uaccess", SUBSYSTEM!="sound", TAG+="seat"
SUBSYSTEM=="drm", KERNEL=="card[0-9]*", TAG+="seat", TAG+="master-of-seat", ENV{ID_FOR_SEAT}="seat0"
SUBSYSTEM=="drm", KERNEL=="renderD[0-9]*", TAG+="seat", ENV{ID_FOR_SEAT}="seat0"
SUBSYSTEM=="input", TAG+="seat", ENV{ID_FOR_SEAT}="seat0"
LABEL="seat_end"
UDEV_EOF
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
    OUTPUT_IMG="${BUILD_DIR}/cartridge_${APP_NAME}_${RUNTIME}.img"
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

# Detect exact kernel version from base rootfs to prevent kernel/module mismatch
KERNEL_VER=$(ls "${BASE_ROOTFS}/usr/lib/modules" 2>/dev/null | head -n 1)

if [[ "${RUNTIME}" == "alpine" ]]; then
    echo "==> Step 1: Rapid cloning from lean Alpine template (${ALPINE_TEMPLATE_DIR})..."
    cp -a "${ALPINE_TEMPLATE_DIR}/." "${STAGING_DIR}/"
    mkdir -p "${STAGING_DIR}/usr/lib"

    # Copy kernel modules directly from BASE_ROOTFS to guarantee 100% version match with vmlinuz-linux
    if [[ -d "${BASE_ROOTFS}/usr/lib/modules" ]]; then
        cp -a "${BASE_ROOTFS}/usr/lib/modules" "${STAGING_DIR}/usr/lib/"
    elif [[ -d "${TEMPLATE_DIR}/usr/lib/modules" ]]; then
        cp -a "${TEMPLATE_DIR}/usr/lib/modules" "${STAGING_DIR}/usr/lib/"
    fi

    # Alpine kmod searches /lib/modules/$(uname -r). Alpine is not merged-usr, so symlink /lib/modules -> usr/lib/modules
    mkdir -p "${STAGING_DIR}/lib"
    rm -rf "${STAGING_DIR}/lib/modules"
    ln -sf ../usr/lib/modules "${STAGING_DIR}/lib/modules"

    # Prune massive unused modules to keep Alpine image < 50MB
    rm -f "${STAGING_DIR}"/usr/lib/modules/*/vmlinuz
    rm -rf "${STAGING_DIR}"/usr/lib/modules/*/build
    find "${STAGING_DIR}/usr/lib/modules" -type f -name '*.ko.zst' | grep -vE 'virtio|drm/(drm|drm_kms_helper|drm_display_helper|drm_ttm_helper|ttm|virtio_gpu)|zram|overlay|evdev|sound/(core|hda|pci/hda|virtio)' | xargs rm -f 2>/dev/null || true

    # Regenerate module dependency index for the pruned modules
    if [[ -n "${KERNEL_VER}" ]]; then
        depmod -b "${STAGING_DIR}" -a "${KERNEL_VER}" 2>/dev/null || true
        chroot "${STAGING_DIR}" depmod -a "${KERNEL_VER}" 2>/dev/null || true
    fi
elif [[ -d "${TEMPLATE_DIR}" ]]; then
    # Verify template modules match the active kernel version
    if [[ -n "${KERNEL_VER}" && ! -d "${TEMPLATE_DIR}/usr/lib/modules/${KERNEL_VER}" ]]; then
        echo "==> Warning: Template kernel modules mismatch with active kernel ${KERNEL_VER}. Refreshing from base rootfs..."
        rm -rf "${TEMPLATE_DIR}"
        echo "==> Step 1: Copying base rootfs into fresh hermetic staging (${STAGING_DIR})..."
        cp -a "${BASE_ROOTFS}/." "${STAGING_DIR}/"
    else
        echo "==> Step 1: Rapid cloning from lean base_template (${TEMPLATE_DIR})..."
        cp -a "${TEMPLATE_DIR}/." "${STAGING_DIR}/"
    fi
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
SUBSYSTEM=="input", TAG+="seat", ENV{ID_FOR_SEAT}="seat0"
LABEL="seat_end"
UDEV_SEAT_EOF

    echo "==> Step 3: Verifying Alpine Wayland kiosk environment..."
    if [[ ! -x "${STAGING_DIR}/usr/bin/cage" || ! -x "${STAGING_DIR}/usr/bin/seatd" || ! -x "${STAGING_DIR}/usr/bin/Xwayland" ]]; then
        echo "Installing Alpine Wayland kiosk environment..."
        chroot "${STAGING_DIR}" apk add --no-cache cage seatd mesa eudev libinput kmod ttf-dejavu util-linux bash xwayland
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
if [[ "${RUNTIME}" == "arch" ]]; then
    arch-chroot "${STAGING_DIR}" fc-cache -fv 2>/dev/null || true
else
    chroot "${STAGING_DIR}" fc-cache -fv 2>/dev/null || true
fi

# Prepare required directories and permissions
mkdir -p "${STAGING_DIR}/data"
mkdir -p "${STAGING_DIR}/mnt/hidden_host"
mkdir -p "${STAGING_DIR}/app/workspace"
mkdir -p "${STAGING_DIR}/var/lib/xkb"
mkdir -p "${STAGING_DIR}/etc/cartilage"
echo "cartilage42" > "${STAGING_DIR}/etc/cartilage/passcode"
chmod 0600 "${STAGING_DIR}/etc/cartilage/passcode"

if [[ "${RUNTIME}" == "arch" ]]; then
    ln -sf /usr/bin/dash "${STAGING_DIR}/bin/sh"
else
    if [[ ! -e "${STAGING_DIR}/bin/sh" ]]; then
        ln -sf /bin/busybox "${STAGING_DIR}/bin/sh" 2>/dev/null || ln -sf /bin/bash "${STAGING_DIR}/bin/sh"
    fi
fi

LAUNCH_TARGET="${APP_EXEC}"
if [[ "${APP_EXEC}" == "chromium" ]]; then
    LAUNCH_TARGET="/usr/bin/chromium --ozone-platform=wayland --enable-features=UseOzonePlatform --start-maximized --no-first-run --no-default-browser-check --disable-gpu --disable-gpu-watchdog --disable-sync --disable-translate https://duckduckgo.com"
fi

ALPINE_RENDERER="WLR_RENDERER=pixman"


echo "==> Step 5: Installing modular PID 1 /init and /init.d/ stage runner..."
mkdir -p "${STAGING_DIR}/init.d" "${STAGING_DIR}/etc/cartilage"
cp "${REPO_ROOT}/stages/init" "${STAGING_DIR}/init"
chmod +x "${STAGING_DIR}/init"
cp "${REPO_ROOT}/stages/"*.sh "${STAGING_DIR}/init.d/"
chmod +x "${STAGING_DIR}/init.d/"*.sh

# Write appliance entrypoint and arguments
echo "${APP_EXEC}" > "${STAGING_DIR}/etc/cartilage/entrypoint"
if [[ -x "${STAGING_DIR}/usr/bin/${APP_EXEC}" ]]; then
    echo "/usr/bin/${APP_EXEC}" > "${STAGING_DIR}/etc/cartilage/entrypoint"
fi

rm -f "${STAGING_DIR}/etc/cartilage/args"
if [[ "${APP_EXEC}" == "chromium" ]]; then
    cat << 'ARGS_EOF' > "${STAGING_DIR}/etc/cartilage/args"
--ozone-platform=wayland
--enable-features=UseOzonePlatform
--start-maximized
--no-first-run
--no-default-browser-check
--disable-gpu
--disable-gpu-watchdog
--disable-sync
--disable-translate
https://duckduckgo.com
ARGS_EOF
fi


echo "==> Step 6: Sanitization pass..."
if [[ ! -f "${STAGING_DIR}/bin/bash" ]]; then
    echo "Fatal: /bin/bash missing before sanitization!" >&2
    exit 1
fi

if [[ "${RUNTIME}" == "alpine" ]]; then
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

# Ensure backwards-compatible aliases (both with and without _arch suffix)
ALIAS_IMG="${BUILD_DIR}/cartridge_${APP_NAME}.img"
ARCH_ALIAS_IMG="${BUILD_DIR}/cartridge_${APP_NAME}_arch.img"
if [[ "${OUTPUT_IMG}" == "${ARCH_ALIAS_IMG}" && ! -e "${ALIAS_IMG}" ]]; then
    ln -sf "$(basename "${OUTPUT_IMG}")" "${ALIAS_IMG}" 2>/dev/null || true
elif [[ "${OUTPUT_IMG}" == "${ALIAS_IMG}" && ! -e "${ARCH_ALIAS_IMG}" ]]; then
    ln -sf "$(basename "${OUTPUT_IMG}")" "${ARCH_ALIAS_IMG}" 2>/dev/null || true
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
