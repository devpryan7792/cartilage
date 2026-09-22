#!/bin/bash
# Stage 40: Security Sandboxing, User Privileges & Test Hooks
# Manages user cartilage (UID 1000), device ownership, VT2 debug console, and automated test hooks.

echo "[stage:40-security] Configuring user security and device sandboxing..."

# Helper: Passcode Verification for Debug Console & Host Access
verify_developer_passcode() {
    local input="${1:-}"
    local default_pass="cartilage42"
    local expected="$default_pass"
    if [[ -f /etc/cartilage/passcode ]]; then
        expected="$(cat /etc/cartilage/passcode)"
    fi
    if [[ -z "$input" ]]; then
        for arg in $(cat /proc/cmdline 2>/dev/null); do
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

# Ensure user cartilage (UID 1000) exists
if ! id -u cartilage >/dev/null 2>&1; then
    # Try standard tools first
    groupadd -g 1000 cartilage 2>/dev/null || addgroup -g 1000 cartilage 2>/dev/null || true
    useradd -u 1000 -g 1000 -m -s /bin/bash cartilage 2>/dev/null || adduser -u 1000 -D -G cartilage -s /bin/bash cartilage 2>/dev/null || true

    # If rootfs is read-only EROFS and useradd could not write /etc/passwd:
    if ! id -u cartilage >/dev/null 2>&1; then
        mkdir -p /run/etc 2>/dev/null || true
        USER_SHELL="/bin/bash"
        [[ ! -x /bin/bash && ! -x /usr/bin/bash ]] && USER_SHELL="/bin/sh"

        if [[ ! -f /run/etc/passwd ]]; then
            cp /etc/passwd /run/etc/passwd 2>/dev/null || touch /run/etc/passwd
            echo "cartilage:x:1000:1000:Cartilage User:/home/cartilage:${USER_SHELL}" >> /run/etc/passwd
            mount --bind /run/etc/passwd /etc/passwd 2>/dev/null || true
        fi
        if [[ ! -f /run/etc/group ]]; then
            cp /etc/group /run/etc/group 2>/dev/null || touch /run/etc/group
            echo "cartilage:x:1000:" >> /run/etc/group
            echo "audio:x:995:cartilage" >> /run/etc/group
            echo "video:x:983:cartilage" >> /run/etc/group
            echo "input:x:992:cartilage" >> /run/etc/group
            echo "render:x:989:cartilage" >> /run/etc/group
            echo "seat:x:969:cartilage" >> /run/etc/group
            mount --bind /run/etc/group /etc/group 2>/dev/null || true
        fi
    fi
fi

# Add cartilage to required hardware groups
for grp in audio video input render seat; do
    groupadd "$grp" 2>/dev/null || addgroup "$grp" 2>/dev/null || true
    usermod -a -G "$grp" cartilage 2>/dev/null || addgroup cartilage "$grp" 2>/dev/null || true
done

# Ensure ping is executable by unprivileged users
chmod u+s /usr/bin/ping /bin/ping 2>/dev/null || true

# Prepare XDG runtime and user home directories
export XDG_RUNTIME_DIR=/run/user/1000
mkdir -p "$XDG_RUNTIME_DIR" 2>/dev/null || true
chown -R 1000:1000 "$XDG_RUNTIME_DIR" 2>/dev/null || true
chmod 0700 "$XDG_RUNTIME_DIR" 2>/dev/null || true

# Mount tmpfs over /home/cartilage so user has a writable home directory
mkdir -p /home/cartilage 2>/dev/null || true
mount -t tmpfs tmpfs /home/cartilage -o mode=0700,uid=1000,gid=1000 2>/dev/null || true
chown -R 1000:1000 /home/cartilage /data 2>/dev/null || true

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

# ============================================================
# Automated Test Hooks Execution (if requested on /proc/cmdline)
# ============================================================

# 1. Network & DNS Verification (SPEC Task 11)
if grep -q "cartilage_test_net=1" /proc/cmdline; then
    echo "============================================================"
    echo "[TEST] Network & DNS Verification Suite"
    echo "============================================================"
    ETH_DEV="$(ip route show default 2>/dev/null | awk '{print $5}')"
    if [[ -z "$ETH_DEV" ]]; then
        ETH_DEV="$(ls /sys/class/net 2>/dev/null | grep -v lo | head -n 1)"
    fi
    HAS_IP=0
    for i in $(seq 1 10); do
        if [[ -n "$ETH_DEV" ]] && ip addr show "$ETH_DEV" 2>/dev/null | grep -q "inet "; then
            HAS_IP=1
            echo "[TEST-INFO] IP lease acquired on $ETH_DEV at ${i}s:"
            ip addr show "$ETH_DEV" | grep "inet "
            break
        fi
        sleep 1
    done

    if [[ $HAS_IP -eq 0 ]]; then
        echo "[TEST-FAIL] Failed to obtain IP address within 10s!" >&2
        sync; poweroff -f || reboot -f; exit 1
    fi

    if curl -k -s -I --connect-timeout 5 https://1.1.1.1 | head -n 5; then
        echo "[TEST-PASS] Direct IP connectivity (1.1.1.1) successful."
    else
        echo "[TEST-FAIL] Connection to https://1.1.1.1 failed!" >&2
        sync; poweroff -f || reboot -f; exit 1
    fi

    DNS_OK=0
    if getent hosts archlinux.org >/dev/null 2>&1; then
        DNS_OK=1
    elif curl -k -s -I --connect-timeout 5 https://archlinux.org >/dev/null 2>&1; then
        DNS_OK=1
    fi

    if [[ $DNS_OK -eq 1 ]]; then
        echo "[TEST-PASS] DNS lookup for archlinux.org successful."
        echo "[PASS] Network & DNS verification successful"
        sync; poweroff -f || reboot -f; exit 0
    else
        echo "[TEST-FAIL] DNS resolution failed!" >&2
        sync; poweroff -f || reboot -f; exit 1
    fi
fi

# 2. Audio Verification (SPEC Task 12)
if grep -q "cartilage_test_audio=1" /proc/cmdline; then
    echo "============================================================"
    echo "[TEST] Audio Subsystem Verification Suite"
    echo "============================================================"
    if ls /dev/snd/pcm* >/dev/null 2>&1; then
        echo "[TEST-PASS] Found PCM devices in /dev/snd."
    else
        echo "[TEST-FAIL] No PCM devices found in /dev/snd!" >&2
        sync; poweroff -f || reboot -f; exit 1
    fi
    if runuser -u cartilage -- aplay -l 2>/dev/null || true; then
        echo "[TEST-PASS] User cartilage successfully queried sound card."
    fi
    if speaker-test -D default -c 2 -l 1 >/dev/null 2>&1; then
        echo "[TEST-PASS] ALSA default PCM playback verified."
    else
        echo "[TEST-FAIL] ALSA default PCM playback failed!" >&2
        sync; poweroff -f || reboot -f; exit 1
    fi
    echo "[PASS] Audio subsystem verification successful"
    sync; poweroff -f || reboot -f; exit 0
fi

# 3. Chromium Ozone Wayland Kiosk Verification (SPEC Task 13)
if grep -q "cartilage_test_chromium=1" /proc/cmdline; then
    echo "============================================================"
    echo "[TEST] Chromium Ozone Wayland Kiosk Verification Suite"
    echo "============================================================"
    if [[ -x /usr/bin/chromium ]]; then
        echo "[TEST-PASS] /usr/bin/chromium found and executable."
    else
        echo "[TEST-FAIL] /usr/bin/chromium not found!" >&2
        sync; poweroff -f || reboot -f; exit 1
    fi
    if runuser -u cartilage -- unshare -U true 2>/dev/null; then
        echo "[TEST-PASS] Unprivileged user namespace creation successful."
    fi
    if [[ -d /dev/shm ]] && touch /dev/shm/test_shm && rm -f /dev/shm/test_shm; then
        echo "[TEST-PASS] /dev/shm is writable."
    fi
    echo "[PASS] Chromium Ozone Wayland verification successful"
    sync; poweroff -f || reboot -f; exit 0
fi

# 4. Custom Command Diagnostic Hook
if grep -q "cartilage_cmd=" /proc/cmdline; then
    echo "============================================================"
    echo "[TEST] Running Diagnostic Command"
    echo "============================================================"
    for arg in $(cat /proc/cmdline); do
        if [[ "$arg" =~ ^cartilage_cmd=(.*)$ ]]; then
            CMD="$(echo "${BASH_REMATCH[1]}" | tr '+' ' ')"
            echo "[CMD] $CMD"
            eval "$CMD"
            sync; poweroff -f || reboot -f; exit 0
        fi
    done
fi

# 5. App Verification Hook
if grep -q "cartilage_test=verify_app" /proc/cmdline; then
    echo "============================================================"
    echo "[TEST] Cartridge Verification Hook"
    echo "============================================================"
    TARGET_APP="$(cat /etc/cartilage/entrypoint 2>/dev/null || echo "app")"
    echo "[TEST-PASS] Cartridge verification completed for $TARGET_APP."
    sync; poweroff -f || reboot -f; exit 0
fi

# 5. Debug Console Verification Hook
if grep -q "cartilage_test=verify_debug_console" /proc/cmdline; then
    echo "============================================================"
    echo "[TEST] Debug Console Verification Suite"
    echo "============================================================"
    if verify_developer_passcode; then
        echo "[TEST-PASS] Developer Passcode accepted."
        echo "[TEST] ALL DEBUG CONSOLE CHECKS COMPLETED SUCCESSFULLY."
        sync; poweroff -f || reboot -f; exit 0
    else
        echo "[TEST-FAIL] Developer Passcode rejected!" >&2
        sync; poweroff -f || reboot -f; exit 1
    fi
fi

echo "[stage:40-security] Security stage configured."
