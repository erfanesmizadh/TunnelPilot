#!/bin/bash
set -e

GRE_NAME="gre1"
LOG_FILE="/var/log/tunnelpilot.log"
THIS_PUBLIC_IP=$(curl -s ipv4.icanhazip.com)

# ============================
# Function: Header
# ============================
function header() {
    clear
    echo "=========================================="
    echo "          TunnelPilot | GRE Manager"
    echo "=========================================="
    echo -e "📍 This Server Public IP: $THIS_PUBLIC_IP"
    echo
}

# ============================
# Function: Enable TCP BBR / BBR2 / Cubic
# ============================
function enable_bbr() {
    echo "🔧 Select TCP Congestion Control:"
    echo "1) BBR (recommended)"
    echo "2) BBR2"
    echo "3) Cubic (default Linux)"
    read -rp "Your choice: " bbr

    case $bbr in
        1) algo="bbr" ;;
        2) algo="bbr2" ;;
        3) algo="cubic" ;;
        *) echo -e "\033[0;31m❌ Invalid choice\033[0m"; return ;;
    esac

    if ! sysctl net.ipv4.tcp_available_congestion_control | grep -qw "$algo"; then
        echo -e "\033[0;31m❌ $algo is not available on this system\033[0m"
        return
    fi

    sed -i '/net.core.default_qdisc/d;/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf

    cat >> /etc/sysctl.conf <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=$algo
EOF

    sysctl -p >/dev/null
    echo -e "\033[0;32m✅ TCP Congestion Control set to $algo\033[0m"
    echo "$(date) - TCP set to $algo" >> $LOG_FILE
}

# ============================
# Function: Create / Rebuild GRE Tunnel
# ============================
function create_gre() {
    echo "🌐 Enter Public IP of the peer server:"
    read -rp "> " REMOTE_PUBLIC_IP

    echo "🔹 Enter Private IPv4 for this server (e.g., 10.50.60.1/30):"
    read -rp "> " PRIVATE_IPV4

    echo "🔹 Enter Private IPv6 for this server (e.g., fd00:50:60::1/126):"
    read -rp "> " PRIVATE_IPV6

    echo "🔹 Enter MTU (recommended: 1400):"
    read -rp "> " MTU
    MTU=${MTU:-1400}

    echo
    echo "📋 Configuration Summary:"
    echo "This server      : $THIS_PUBLIC_IP"
    echo "Peer server      : $REMOTE_PUBLIC_IP"
    echo "Private IPv4     : $PRIVATE_IPV4"
    echo "Private IPv6     : $PRIVATE_IPV6"
    echo "MTU              : $MTU"
    echo
    read -rp "Continue? (y/n): " c
    [[ "$c" != "y" ]] && return

    echo "🚀 Creating GRE Tunnel..."
    modprobe ip_gre || true
    ip tunnel del $GRE_NAME 2>/dev/null || true

    ip tunnel add $GRE_NAME mode gre \
        local $THIS_PUBLIC_IP \
        remote $REMOTE_PUBLIC_IP \
        ttl 255

    ip link set $GRE_NAME up
    ip link set $GRE_NAME mtu $MTU

    ip addr add $PRIVATE_IPV4 dev $GRE_NAME
    ip -6 addr add $PRIVATE_IPV6 dev $GRE_NAME

    sysctl -w net.ipv4.ip_forward=1 >/dev/null
    sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null

    iptables -C INPUT -p gre -j ACCEPT 2>/dev/null || iptables -A INPUT -p gre -j ACCEPT

    echo -e "\033[0;32m✅ GRE Tunnel is UP\033[0m"
    ip addr show $GRE_NAME
    echo "$(date) - GRE Tunnel created for $REMOTE_PUBLIC_IP" >> $LOG_FILE

    # Ping test
    LOCAL_IPV4=$(echo $PRIVATE_IPV4 | cut -d/ -f1)
    LOCAL_IPV6=$(echo $PRIVATE_IPV6 | cut -d/ -f1)
    echo
    echo "🔍 Testing connectivity..."
    ping -c 3 $LOCAL_IPV4 >/dev/null 2>&1 && echo -e "\033[0;32m✅ IPv4 reachable\033[0m" || echo -e "\033[0;31m❌ IPv4 test failed\033[0m"
    ping6 -c 3 $LOCAL_IPV6 >/dev/null 2>&1 && echo -e "\033[0;32m✅ IPv6 reachable\033[0m" || echo -e "\033[0;31m❌ IPv6 test failed\033[0m"
}

# ============================
# Function: Remove GRE Tunnel
# ============================
function remove_gre() {
    echo "⚠ Removing GRE Tunnel..."
    if ip link show $GRE_NAME >/dev/null 2>&1; then
        ip addr flush dev $GRE_NAME
        ip tunnel del $GRE_NAME
        echo -e "\033[0;33m🗑 GRE Tunnel removed\033[0m"
        echo "$(date) - GRE Tunnel removed" >> $LOG_FILE
    else
        echo -e "\033[0;31m❌ GRE Tunnel not found\033[0m"
    fi
}

# ============================
# Function: Create iptables NAT Tunnel
# ============================
function create_iptables_tunnel() {
    echo "🌐 Enter Remote Server IP for NAT Tunnel:"
    read -rp "> " REMOTE_IP

    echo "🔹 Enter local port to forward (e.g., 8080):"
    read -rp "> " LOCAL_PORT

    echo "🔹 Enter remote port to forward to (e.g., 80):"
    read -rp "> " REMOTE_PORT

    sysctl -w net.ipv4.ip_forward=1 >/dev/null

    iptables -t nat -A PREROUTING -p tcp --dport $LOCAL_PORT -j DNAT --to-destination $REMOTE_IP:$REMOTE_PORT
    iptables -t nat -A POSTROUTING -j MASQUERADE

    echo -e "\033[0;32m✅ NAT Tunnel created: $LOCAL_PORT → $REMOTE_IP:$REMOTE_PORT\033[0m"
    echo "$(date) - iptables NAT $LOCAL_PORT → $REMOTE_IP:$REMOTE_PORT" >> $LOG_FILE
}

# ============================
# Function: Remove iptables NAT
# ============================
function remove_iptables_tunnel() {
    echo "⚠ Removing iptables NAT Tunnel..."
    iptables -t nat -F
    echo -e "\033[0;33m🗑 iptables NAT cleared\033[0m"
    echo "$(date) - iptables NAT cleared" >> $LOG_FILE
}

# ============================
# Main Menu
# ============================
while true; do
    header
    echo "1) Create / Rebuild GRE Tunnel"
    echo "2) Remove GRE Tunnel"
    echo "3) Enable TCP BBR / BBR2"
    echo "4) Create IP-based NAT Tunnel (iptables)"
    echo "5) Remove IP-based NAT Tunnel"
    echo "0) Exit"
    echo
    read -rp "Select an option: " opt

    case $opt in
        1) create_gre ;;
        2) remove_gre ;;
        3) enable_bbr ;;
        4) create_iptables_tunnel ;;
        5) remove_iptables_tunnel ;;
        0) exit 0 ;;
        *) echo -e "\033[0;31m❌ Invalid option\033[0m"; sleep 1 ;;
    esac

    echo
    read -rp "Press Enter to continue..."
done
