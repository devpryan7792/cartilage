#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LINUX_LAUNCHERS="${SCRIPT_DIR}/launchers/linux"

usage() {
    echo "============================================================"
    echo "Cartilage OS — Appliance Runner"
    echo "Usage: ./run.sh <appliance>"
    echo "============================================================"
    echo "Available appliances:"
    echo "  dillo          Dillo Web Browser (Arch glibc, Xwayland, ultra-fast)"
    echo "  chromium [url] Chromium Web Browser (Ozone Wayland, tabs, address bar)"
    echo "  alpine         Mousepad Text Editor (Alpine musl, 44.8MB lean)"
    echo "  mousepad       Mousepad Text Editor (Arch glibc)"
    echo "  menu           Unified Multi-Boot UEFI Menu"
    echo ""
    echo "Example: ./run.sh chromium"
    echo "         ./run.sh chromium https://duckduckgo.com"
    exit 0
}

TARGET="${1:-}"
shift || true

case "${TARGET}" in
    dillo)
        exec "${LINUX_LAUNCHERS}/run_dillo.sh" "$@"
        ;;
    chromium)
        exec "${LINUX_LAUNCHERS}/run_chromium.sh" "$@"
        ;;
    alpine|mousepad-alpine)
        exec "${LINUX_LAUNCHERS}/run_alpine.sh" "$@"
        ;;
    mousepad)
        exec "${LINUX_LAUNCHERS}/run_mousepad.sh" "$@"
        ;;
    menu|boot_menu)
        exec "${LINUX_LAUNCHERS}/run_boot_menu.sh" "$@"
        ;;
    -h|--help|"")
        usage
        ;;
    *)
        echo "Error: Unknown appliance '${TARGET}'" >&2
        echo ""
        usage
        ;;
esac
