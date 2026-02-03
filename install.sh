#!/bin/bash
set -e

LOG_FILE="/var/log/tunnelpilot.log"
THIS_PUBLIC_IP=$(curl -s ipv4.icanhazip.com || curl -s ifconfig.me)

# ============================
# Header
# ============================
function header() {
    clear
    echo "=========================================="
    echo "        TunnelPilot | GRE + WireGuard"
    echo "=========================================="
    echo "📍 This Server Public IP: $THIS_PUBLIC_IP"
    echo
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
# GRE Tunnel Functions
# ============================
function random_gre_name() {
    echo "gre$(tr -dc '0-9' </dev/urandom | head -c 4)"
}

function create_gre() {
    GRE_NAME=$(random_gre_name)
    echo "🌐 Peer Public IP:"
    read -rp "> " REMOTE_PUBLIC_IP
    echo "🔹 Local Private IPv4:"
    read -rp "> " LOCAL_IPV4
    echo "🔹 Remote Private IPv4:"
    read -rp "> " REMOTE_IPV4
    echo "🔹 Local Private IPv6:"
    read -rp "> " LOCAL_IPV6
    echo "🔹 Remote Private IPv6:"
    read -rp "> " REMOTE_IPV6

    mtu=1500
    while [[ $mtu -gt 1200 ]]; do
        if ping -M do -s $((mtu-28)) -c 1 "$REMOTE_PUBLIC_IP" &>/dev/null; then
            break
        fi
        mtu=$((mtu-10))
    done

    modprobe ip_gre || true
    ip tunnel add "$GRE_NAME" mode gre local "$THIS_PUBLIC_IP" remote "$REMOTE_PUBLIC_IP" ttl 255
    ip link set "$GRE_NAME" mtu "$mtu"
    ip link set "$GRE_NAME" up
    ip addr add "$LOCAL_IPV4" dev "$GRE_NAME"
    ip -6 addr add "$LOCAL_IPV6" dev "$GRE_NAME"
    sysctl -w net.ipv4.ip_forward=1 >/dev/null
    sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null
    iptables -C INPUT -p gre -j ACCEPT 2>/dev/null || iptables -A INPUT -p gre -j ACCEPT

    echo "✅ GRE tunnel $GRE_NAME created with MTU $mtu"
    echo "$(date) | GRE $GRE_NAME -> $REMOTE_PUBLIC_IP MTU:$mtu" >> $LOG_FILE
}

function list_gre() {
    tunnels=($(ip tunnel show | awk '{print $1}'))
    if [[ ${#tunnels[@]} -eq 0 ]]; then echo "— none —"; return; fi
    echo "📡 Active GRE tunnels:"
    for t in "${tunnels[@]}"; do
        IP4=$(ip addr show $t 2>/dev/null | grep "inet " | awk '{print $2}')
        IP6=$(ip addr show $t 2>/dev/null | grep "inet6 " | awk '{print $2}')
        echo "$t | IPv4: ${IP4:-—} | IPv6: ${IP6:-—}"
    done
}

function remove_gre() {
    tunnels=($(ip tunnel show | awk '{print $1}'))
    if [[ ${#tunnels[@]} -eq 0 ]]; then echo "— No GRE tunnels found —"; return; fi
    echo "📡 Active GRE tunnels:"
    for i in "${!tunnels[@]}"; do
        t="${tunnels[$i]}"
        echo "$((i+1))) $t"
    done
    read -rp "Enter number or name to remove: " sel
    if [[ "$sel" =~ ^[0-9]+$ ]]; then GRE_NAME="${tunnels[$((sel-1))]}"; else GRE_NAME="$sel"; fi
    if ip link show "$GRE_NAME" &>/dev/null; then
        ip addr flush dev "$GRE_NAME"
        ip tunnel del "$GRE_NAME"
        echo "🗑 $GRE_NAME removed"
        echo "$(date) | GRE $GRE_NAME removed" >> $LOG_FILE
    else
        echo "❌ Tunnel not found"
    fi
}

# ============================
# WireGuard Functions
# ============================
function install_wireguard() {
    if ! command -v wg &>/dev/null; then
        apt update
        apt install -y software-properties-common
        add-apt-repository -y ppa:wireguard/wireguard
        apt update
        apt install -y wireguard qrencode
        echo "✅ WireGuard installed"
    else
        echo "✅ WireGuard already installed"
    fi
}

function generate_wg_keys() {
    SERVER="$1"
    PRIV_KEY="/etc/wireguard/${SERVER}_private.key"
    PUB_KEY="/etc/wireguard/${SERVER}_public.key"

    wg genkey | tee "$PRIV_KEY" | wg pubkey > "$PUB_KEY"
    chmod 600 "$PRIV_KEY" "$PUB_KEY"
    echo "✅ WireGuard keys generated for $SERVER"
}

function create_wireguard_tunnel() {
    echo "🌐 Peer Public IP (Server Outside):"
    read -rp "> " PEER_PUBLIC
    echo "🔹 Local Private IPv4:"
    read -rp "> " LOCAL_IPV4
    echo "🔹 Remote Private IPv4:"
    read -rp "> " REMOTE_IPV4
    echo "🔹 Local Private IPv6:"
    read -rp "> " LOCAL_IPV6
    echo "🔹 Remote Private IPv6:"
    read -rp "> " REMOTE_IPV6

    WG_NAME="wg-$(tr -dc a-z0-9 </dev/urandom | head -c6)"
    WG_CONF="/etc/wireguard/$WG_NAME.conf"
    LOCAL_PRIV_KEY=$(cat /etc/wireguard/iran_private.key)
    REMOTE_PUB_KEY=$(cat /etc/wireguard/outside_public.key)

    cat > "$WG_CONF" <<EOF
[Interface]
Address = $LOCAL_IPV4,$LOCAL_IPV6
PrivateKey = $LOCAL_PRIV_KEY
ListenPort = 51820
SaveConfig = true

[Peer]
PublicKey = $REMOTE_PUB_KEY
Endpoint = $PEER_PUBLIC:51820
AllowedIPs = $REMOTE_IPV4/32,$REMOTE_IPV6/128
PersistentKeepalive = 25
EOF

    chmod 600 "$WG_CONF"
    systemctl enable "wg-quick@$WG_NAME"
    systemctl start "wg-quick@$WG_NAME"

    echo "✅ WireGuard tunnel $WG_NAME is up"
    echo "$(date) | WireGuard $WG_NAME -> $PEER_PUBLIC" >> $LOG_FILE
}

function remove_wireguard() {
    ls /etc/wireguard/*.conf 2>/dev/null | xargs -n1 basename | sed 's/.conf//'
    read -rp "Enter WireGuard tunnel name to remove: " WG_NAME
    systemctl stop "wg-quick@$WG_NAME"
    systemctl disable "wg-quick@$WG_NAME"
    rm -f "/etc/wireguard/$WG_NAME.conf"
    echo "🗑 WireGuard $WG_NAME removed"
    echo "$(date) | WireGuard $WG_NAME removed" >> $LOG_FILE
}

# ============================
# NAT / IPTables
# ============================
function create_nat() {
    read -rp "Enter local port to forward (e.g. 8880): " LOCAL_PORT
    read -rp "Enter remote destination IP (e.g. GRE private IPv4): " REMOTE_IP
    iptables -t nat -A PREROUTING -p tcp --dport "$LOCAL_PORT" -j DNAT --to-destination "$REMOTE_IP:$LOCAL_PORT"
    iptables -t nat -A POSTROUTING -j MASQUERADE
    echo "✅ NAT $LOCAL_PORT -> $REMOTE_IP:$LOCAL_PORT"
    echo "$(date) | NAT $LOCAL_PORT->$REMOTE_IP" >> $LOG_FILE
}

function remove_nat() {
    iptables -t nat -F
    echo "🗑 NAT rules cleared"
    echo "$(date) | NAT cleared" >> $LOG_FILE
}

# ============================
# Main Menu
# ============================
while true; do
    header
    echo "========== GRE Tunnels =========="
    echo "1) Create GRE Tunnel"
    echo "2) Remove GRE Tunnel"
    echo "3) List GRE Tunnels"
    echo "4) Remove GRE Private IPs"
    echo "======= WireGuard =========="
    echo "5) Install WireGuard & PreReq"
    echo "6) Generate WireGuard Keys (Iran)"
    echo "7) Generate WireGuard Keys (Outside)"
    echo "8) Create WireGuard Site-to-Site Tunnel"
    echo "9) Remove WireGuard Tunnel"
    echo "========== NAT / IPTables =========="
    echo "10) Create NAT Tunnel"
    echo "11) Remove NAT Tunnel"
    echo "======= TCP Congestion =========="
    echo "12) Enable TCP BBR / BBR2 / Cubic"
    echo "0) Exit"
    echo
    read -rp "Select option: " opt

    case $opt in
        1) create_gre ;;
        2) remove_gre ;;
        3) list_gre ;;
        4) echo "Flushing GRE private IPs..."; ip addr flush dev $(ip tunnel show | awk '{print $1}') ;;
        5) install_wireguard ;;
        6) generate_wg_keys "iran" ;;
        7) generate_wg_keys "outside" ;;
        8) create_wireguard_tunnel ;;
        9) remove_wireguard ;;
        10) create_nat ;;
        11) remove_nat ;;
        12) enable_bbr ;;
        0) exit 0 ;;
        *) echo "❌ Invalid option"; sleep 1 ;;
    esac
    read -rp "Press Enter to continue..."
done
