#!/bin/bash
# Stage 20: Network & DNS Subsystem
# Configures loopback, detects primary ethernet interface, requests DHCP lease, and seeds Anycast DNS.

echo "[stage:20-network] Initializing Network & DNS..."

ip link set lo up 2>/dev/null || true

ETH_DEV=""
for iface in /sys/class/net/eth* /sys/class/net/ens* /sys/class/net/enp*; do
    if [[ -e "$iface" ]]; then
        ETH_DEV="$(basename "$iface")"
        break
    fi
done

if [[ -z "$ETH_DEV" ]]; then
    for iface in /sys/class/net/*; do
        dev="$(basename "$iface")"
        if [[ "$dev" != "lo" && -e "$iface" ]]; then
            ETH_DEV="$dev"
            break
        fi
    done
fi

if [[ -n "$ETH_DEV" ]]; then
    echo "[stage:20-network] Primary network interface detected: $ETH_DEV"
    ip link set "$ETH_DEV" up 2>/dev/null || true
    if command -v dhcpcd >/dev/null 2>&1; then
        dhcpcd -b -q "$ETH_DEV" 2>/dev/null || true
    elif command -v udhcpc >/dev/null 2>&1; then
        udhcpc -b -i "$ETH_DEV" 2>/dev/null || true
    fi
else
    echo "[stage:20-network] No ethernet interface detected (offline mode)."
fi

mkdir -p /run /run/systemd/resolve
printf "nameserver 1.1.1.1\nnameserver 9.9.9.9\nnameserver 8.8.8.8\n" > /run/resolv.conf
cp -f /run/resolv.conf /run/systemd/resolve/stub-resolv.conf 2>/dev/null || true
cp -f /run/resolv.conf /run/systemd/resolve/resolv.conf 2>/dev/null || true
chmod 0644 /run/resolv.conf /run/systemd/resolve/*.conf 2>/dev/null || true
mount --bind /run/resolv.conf /etc/resolv.conf 2>/dev/null || true

echo "[stage:20-network] Network initialization completed."
