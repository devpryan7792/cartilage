#!/bin/bash
# Stage 20: Network & DNS Subsystem
# Configures loopback, detects primary ethernet interface, requests DHCP lease, and seeds Anycast DNS.

echo "[stage:20-network] Initializing Network & DNS..."

# Enable ICMP ping sockets for unprivileged users (fixes ping: Operation not permitted)
sysctl -w net.ipv4.ping_group_range="0 2147483647" 2>/dev/null || true

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
        echo "[stage:20-network] Requesting DHCPv4 lease on $ETH_DEV..."
        # Use -C resolv.conf to strictly prevent dhcpcd hooks from mangling our curated nameservers
        dhcpcd -4 --clientid -q -C resolv.conf "$ETH_DEV" 2>/dev/null || dhcpcd -b -q -C resolv.conf "$ETH_DEV" 2>/dev/null || true
        for i in $(seq 1 15); do
            if ip addr show "$ETH_DEV" 2>/dev/null | grep -q "inet "; then
                echo "[stage:20-network] Network lease acquired: $(ip addr show "$ETH_DEV" 2>/dev/null | grep "inet " | awk '{print $2}')"
                break
            fi
            sleep 0.2
        done
    elif command -v udhcpc >/dev/null 2>&1; then
        udhcpc -b -i "$ETH_DEV" 2>/dev/null || true
    fi
else
    echo "[stage:20-network] No ethernet interface detected (offline mode)."
fi

mkdir -p /run /run/systemd/resolve
# Seed DNS: Prioritize ultra-fast Anycast (1.1.1.1 & 8.8.8.8), integrate DHCP lease DNS, and fallback to QEMU slirp (10.0.2.3)
DHCP_DNS=""
if [[ -n "$ETH_DEV" ]] && command -v dhcpcd >/dev/null 2>&1; then
    DHCP_DNS="$(dhcpcd -U "$ETH_DEV" 2>/dev/null | grep -E '^domain_name_servers=' | cut -d'=' -f2 | tr -d "'" | tr -d '"')"
fi

{
    echo "nameserver 1.1.1.1"
    echo "nameserver 8.8.8.8"
    for srv in $DHCP_DNS; do
        if [[ "$srv" != "1.1.1.1" && "$srv" != "8.8.8.8" && "$srv" != "10.0.2.3" ]]; then
            echo "nameserver $srv"
        fi
    done
    echo "nameserver 10.0.2.3"
    echo "nameserver 9.9.9.9"
    echo "options timeout:2 attempts:2 rotate"
} > /run/resolv.conf

cp -f /run/resolv.conf /run/systemd/resolve/stub-resolv.conf 2>/dev/null || true
cp -f /run/resolv.conf /run/systemd/resolve/resolv.conf 2>/dev/null || true
chmod 0644 /run/resolv.conf /run/systemd/resolve/*.conf 2>/dev/null || true
mount --bind /run/resolv.conf /etc/resolv.conf 2>/dev/null || true

echo "[stage:20-network] Network initialization completed."
