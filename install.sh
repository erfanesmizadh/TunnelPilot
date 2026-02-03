 #!/bin/bash
set -e

LOG_FILE="/var/log/tunnelpilot.log"
THIS_PUBLIC_IP=$(curl -s ipv4.icanhazip.com || curl -s ifconfig.me)

# ============================
# Utils
# ============================
function header() {
    clear
    echo "=========================================="
    echo "        TunnelPilot | Multi GRE Manager"
    echo "=========================================="
    echo "📍 This Server Public IP: $THIS_PUBLIC_IP"
    echo
}

function random_gre_name() {
    echo "gre$(tr -dc '0-9' </dev/urandom | head -c 4)"
}

# ============================
# TCP BBR / BBR2 / Cubic
# ============================
function enable_bbr() {
    echo "🔧 Select TCP Congestion Control:"
    echo "1) BBR"
    echo "2) BBR2"
    echo "3) Cubic"
    read -rp "Your choice: " bbr

    case $bbr in
        1) algo="bbr" ;;
        2) algo="bbr2" ;;
        3) algo="cubic" ;;
        *) echo "❌ Invalid choice"; sleep 1; return ;;
    esac

    if ! sysctl net.ipv4.tcp_available_congestion_control | grep -qw "$algo"; then
        echo "❌ $algo not supported by kernel"
        sleep 1
        return
    fi

    sed -i '/net.core.default_qdisc/d;/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf

    cat >> /etc/sysctl.conf <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=$algo
EOF

    sysctl -p >/dev/null
    echo "✅ TCP congestion set to $algo"
    echo "$(date) | TCP $algo" >> $LOG_FILE
}

# ============================
# Detect Optimal MTU
# ============================
function detect_mtu() {
    REMOTE_IP="$1"
    mtu=1500
    while [[ $mtu -gt 1200 ]]; do
        if ping -M do -s $((mtu-28)) -c 1 "$REMOTE_IP" &>/dev/null; then
            echo $mtu
            return
        fi
        mtu=$((mtu-10))
    done
    echo 1400
}

# ============================
# GRE Tunnel
# ============================
function create_gre() {
    echo "🆔 Tunnel name:"
    echo "1) Random"
    echo "2) Custom"
    read -rp "Choice: " name_choice

    if [[ "$name_choice" == "1" ]]; then
        GRE_NAME=$(random_gre_name)
    else
        read -rp "Enter tunnel name (e.g. gre-iran1): " GRE_NAME
    fi

    echo "🌐 Peer Public IP:"
    read -rp "> " REMOTE_PUBLIC_IP

    echo "🔹 Private IPv4 (e.g. 10.50.60.1/30):"
    read -rp "> " PRIVATE_IPV4

    echo "🔹 Private IPv6 (e.g. fd00:50:60::1/126):"
    read -rp "> " PRIVATE_IPV6

    # Auto detect MTU
    DETECTED_MTU=$(detect_mtu "$REMOTE_PUBLIC_IP")
    echo "⚡ Detected optimal MTU to $REMOTE_PUBLIC_IP: $DETECTED_MTU"
    read -rp "MTU [$DETECTED_MTU]: " MTU
    MTU=${MTU:-$DETECTED_MTU}

    echo
    echo "📋 Summary"
    echo "Tunnel name : $GRE_NAME"
    echo "Local IP   : $THIS_PUBLIC_IP"
    echo "Remote IP  : $REMOTE_PUBLIC_IP"
    echo "IPv4       : $PRIVATE_IPV4"
    echo "IPv6       : $PRIVATE_IPV6"
    echo "MTU        : $MTU"
    read -rp "Continue? (y/n): " c
    [[ "$c" != "y" ]] && return

    modprobe ip_gre || true

    ip tunnel add "$GRE_NAME" mode gre \
        local "$THIS_PUBLIC_IP" \
        remote "$REMOTE_PUBLIC_IP" \
        ttl 255

    ip link set "$GRE_NAME" mtu "$MTU"
    ip link set "$GRE_NAME" up

    ip addr add "$PRIVATE_IPV4" dev "$GRE_NAME"
    ip -6 addr add "$PRIVATE_IPV6" dev "$GRE_NAME"

    sysctl -w net.ipv4.ip_forward=1 >/dev/null
    sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null

    iptables -C INPUT -p gre -j ACCEPT 2>/dev/null || \
        iptables -A INPUT -p gre -j ACCEPT

    echo "✅ GRE tunnel $GRE_NAME created with MTU $MTU"
    ip addr show "$GRE_NAME"

    echo "$(date) | ADD $GRE_NAME $REMOTE_PUBLIC_IP MTU:$MTU" >> $LOG_FILE
}

# ============================
# List GRE Tunnels
# ============================
function list_gre() {
    echo "📡 Active GRE tunnels:"
    tunnels=($(ip tunnel show | awk '{print $1}'))
    if [[ ${#tunnels[@]} -eq 0 ]]; then
        echo "— none —"
        return
    fi

    for t in "${tunnels[@]}"; do
        IP4=$(ip addr show $t 2>/dev/null | grep "inet " | awk '{print $2}')
        IP6=$(ip addr show $t 2>/dev/null | grep "inet6 " | awk '{print $2}')
        echo "$t | IPv4: ${IP4:-—} | IPv6: ${IP6:-—}"
    done
}

# ============================
# Remove GRE
# ============================
function remove_gre() {
    tunnels=($(ip tunnel show | awk '{print $1}'))

    if [[ ${#tunnels[@]} -eq 0 ]]; then
        echo "— No GRE tunnels found —"
        return
    fi

    echo "📡 Active GRE tunnels:"
    for i in "${!tunnels[@]}"; do
        t="${tunnels[$i]}"
        IP4=$(ip addr show $t 2>/dev/null | grep "inet " | awk '{print $2}')
        IP6=$(ip addr show $t 2>/dev/null | grep "inet6 " | awk '{print $2}')
        echo "$((i+1))) $t | IPv4: ${IP4:-—} | IPv6: ${IP6:-—}"
    done

    echo
    read -rp "Enter tunnel number or name to remove: " sel

    if [[ "$sel" =~ ^[0-9]+$ ]]; then
        if (( sel >= 1 && sel <= ${#tunnels[@]} )); then
            GRE_NAME="${tunnels[$((sel-1))]}"
        else
            echo "❌ Invalid number"
            return
        fi
    else
        GRE_NAME="$sel"
    fi

    if ip link show "$GRE_NAME" &>/dev/null; then
        read -rp "⚠️ Are you sure you want to delete $GRE_NAME? (y/n): " confirm
        [[ "$confirm" != "y" ]] && echo "Cancelled" && return

        ip addr flush dev "$GRE_NAME"
        ip tunnel del "$GRE_NAME"
        echo "🗑 $GRE_NAME removed"
        echo "$(date) | DEL $GRE_NAME" >> $LOG_FILE
    else
        echo "❌ Tunnel not found"
    fi
}

# ============================
# WireGuard Site-to-Site
# ============================
function create_wireguard_tunnel() {
    echo "🆔 WireGuard tunnel name (e.g. wg-iran):"
    read -rp "> " WG_NAME
    WG_NAME=${WG_NAME:-wg-iran}

    echo "🌐 Peer Public IP (Server Outside):"
    read -rp "> " PEER_PUBLIC

    echo "🔹 Local Private IPv4 (e.g. 10.200.200.1/24):"
    read -rp "> " LOCAL_IPV4

    echo "🔹 Remote Private IPv4 (e.g. 10.200.200.2/24):"
    read -rp "> " REMOTE_IPV4

    echo "🔹 Local Private IPv6 (e.g. fd50::1/64):"
    read -rp "> " LOCAL_IPV6

    echo "🔹 Remote Private IPv6 (e.g. fd50::2/64):"
    read -rp "> " REMOTE_IPV6

    if ! command -v wg &>/dev/null; then
        echo "🔧 Installing WireGuard..."
        apt update && apt install -y wireguard
    fi

    WG_PRIVATE=$(wg genkey)
    WG_PUBLIC=$(echo $WG_PRIVATE | wg pubkey)

    WG_CONF="/etc/wireguard/$WG_NAME.conf"
    cat > $WG_CONF <<EOF
[Interface]
Address = $LOCAL_IPV4,$LOCAL_IPV6
PrivateKey = $WG_PRIVATE
ListenPort = 51820
SaveConfig = true

[Peer]
PublicKey = PLACEHOLDER_PEER_PUBLIC_KEY
Endpoint = $PEER_PUBLIC:51820
AllowedIPs = $REMOTE_IPV4/32,$REMOTE_IPV6/128
PersistentKeepalive = 25
EOF

    chmod 600 $WG_CONF
    systemctl enable "wg-quick@$WG_NAME"
    systemctl start "wg-quick@$WG_NAME"

    echo "✅ WireGuard tunnel $WG_NAME is up"
    echo "Config: $WG_CONF"
    echo "$(date) | WireGuard $WG_NAME -> $PEER_PUBLIC" >> $LOG_FILE
    echo "⚠️ Don't forget to set Peer public key on server outside"
}

# ============================
# Main Menu
# ============================
while true; do
    header
    echo "1) Create GRE Tunnel (Multi)"
    echo "2) Remove GRE Tunnel"
    echo "3) List GRE Tunnels"
    echo "4) Enable TCP BBR / BBR2 / Cubic"
    echo "5) Create NAT Tunnel (only on Iran server)"
    echo "6) Remove NAT Tunnel"
    echo "7) Create WireGuard Site-to-Site Tunnel"
    echo "0) Exit"
    echo
    read -rp "Select option: " opt

    case $opt in
        1) create_gre ;;
        2) remove_gre ;;
        3) list_gre ;;
        4) enable_bbr ;;
        5) create_iptables_tunnel ;;
        6) remove_iptables_tunnel ;;
        7) create_wireguard_tunnel ;;
        0) exit 0 ;;
        *) echo "❌ Invalid option"; sleep 1 ;;
    esac

    echo
    read -rp "Press Enter to continue..."
done
