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
# GRE Functions
# ============================
function random_gre_name() {
    echo "gre$(tr -dc '0-9' </dev/urandom | head -c 4)"
}

function create_gre() {
    echo "🆔 Tunnel name (Random or Custom)?"
    echo "1) Random"
    echo "2) Custom"
    read -rp "Choice: " choice
    [[ "$choice" == "1" ]] && GRE_NAME=$(random_gre_name) || read -rp "Enter tunnel name: " GRE_NAME

    read -rp "🌐 Peer Public IP: " REMOTE_PUBLIC
    read -rp "🔹 Private IPv4 (e.g. 172.21.31.1/30): " PRIVATE_IPV4
    read -rp "🔹 Private IPv6 (e.g. fd5a:40cb:954c::1/64): " PRIVATE_IPV6
    read -rp "MTU [1400]: " MTU
    MTU=${MTU:-1400}

    modprobe ip_gre || true
    ip tunnel add "$GRE_NAME" mode gre local "$THIS_PUBLIC_IP" remote "$REMOTE_PUBLIC" ttl 255
    ip link set "$GRE_NAME" mtu "$MTU"
    ip link set "$GRE_NAME" up
    ip addr add "$PRIVATE_IPV4" dev "$GRE_NAME"
    ip -6 addr add "$PRIVATE_IPV6" dev "$GRE_NAME"

    sysctl -w net.ipv4.ip_forward=1 >/dev/null
    sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null
    iptables -C INPUT -p gre -j ACCEPT 2>/dev/null || iptables -A INPUT -p gre -j ACCEPT

    echo "✅ GRE tunnel $GRE_NAME created | MTU: $MTU"
    echo "$(date) | GRE $GRE_NAME -> $REMOTE_PUBLIC" >> $LOG_FILE
}

function list_gre() {
    echo "📡 Active GRE tunnels:"
    ip tunnel show | awk '{print $1}' | while read t; do
        IP4=$(ip addr show $t | grep "inet " | awk '{print $2}')
        IP6=$(ip addr show $t | grep "inet6 " | awk '{print $2}')
        echo "$t | IPv4: ${IP4:-—} | IPv6: ${IP6:-—}"
    done
}

function remove_gre() {
    list_gre
    read -rp "Enter GRE name to remove: " GRE_NAME
    ip addr flush dev "$GRE_NAME" 2>/dev/null || true
    ip tunnel del "$GRE_NAME" 2>/dev/null || true
    echo "🗑 GRE $GRE_NAME removed"
    echo "$(date) | DEL GRE $GRE_NAME" >> $LOG_FILE
}

# ============================
# WireGuard Functions
# ============================
function wg_install() {
    apt update && apt install -y wireguard qrencode
}

function wg_generate_keys() {
    WG_PRIVATE=$(wg genkey)
    WG_PUBLIC=$(echo $WG_PRIVATE | wg pubkey)
    echo "$WG_PRIVATE" > /etc/wireguard/${1}_private.key
    echo "$WG_PUBLIC" > /etc/wireguard/${1}_public.key
    chmod 600 /etc/wireguard/${1}_*.key
    echo "✅ WireGuard keys generated for $1"
    echo "Private Key: $WG_PRIVATE"
    echo "Public Key:  $WG_PUBLIC"
}

function create_wireguard() {
    read -rp "🆔 WireGuard tunnel name [wg-iran]: " WG_NAME
    WG_NAME=${WG_NAME:-wg-iran}
    read -rp "🌐 Peer Public IP (Server Outside): " PEER_PUBLIC
    read -rp "🔹 Local Private IPv4 (e.g. 10.200.200.1/24): " LOCAL_IPV4
    read -rp "🔹 Remote Private IPv4 (e.g. 10.200.200.2/24): " REMOTE_IPV4
    read -rp "🔹 Local Private IPv6 (e.g. fd50::1/64): " LOCAL_IPV6
    read -rp "🔹 Remote Private IPv6 (e.g. fd50::2/64): " REMOTE_IPV6

    wg_install

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
    echo "$(date) | WireGuard $WG_NAME -> $PEER_PUBLIC" >> $LOG_FILE
}

function remove_wireguard() {
    read -rp "Enter WireGuard tunnel name to remove: " WG_NAME
    wg-quick down "$WG_NAME" 2>/dev/null || true
    rm -f /etc/wireguard/$WG_NAME.conf
    echo "🗑 WireGuard $WG_NAME removed"
    echo "$(date) | DEL WireGuard $WG_NAME" >> $LOG_FILE
}

# ============================
# NAT / IPTables
# ============================
function create_nat() {
    read -rp "🌐 Remote GRE IP: " REMOTE_IP
    read -rp "🔹 Local port (e.g. 443-99999): " LOCAL_PORT
    read -rp "🔹 Remote port (on server outside, e.g. 8880): " REMOTE_PORT

    sysctl -w net.ipv4.ip_forward=1 >/dev/null

    iptables -t nat -D PREROUTING -p tcp --dport "$LOCAL_PORT" -j DNAT --to-destination "$REMOTE_IP:$REMOTE_PORT" 2>/dev/null || true
    iptables -t nat -D POSTROUTING -j MASQUERADE 2>/dev/null || true

    iptables -t nat -A PREROUTING -p tcp --dport "$LOCAL_PORT" -j DNAT --to-destination "$REMOTE_IP:$REMOTE_PORT"
    iptables -t nat -A POSTROUTING -j MASQUERADE

    echo "✅ NAT created: $LOCAL_PORT → $REMOTE_IP:$REMOTE_PORT"
    echo "$(date) | NAT $LOCAL_PORT->$REMOTE_IP:$REMOTE_PORT" >> $LOG_FILE
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
    echo
    echo "======= WireGuard =========="
    echo "5) Install WireGuard & PreReq"
    echo "6) Generate WireGuard Keys (Iran)"
    echo "7) Generate WireGuard Keys (Outside)"
    echo "8) Create WireGuard Site-to-Site Tunnel"
    echo "9) Remove WireGuard Tunnel"
    echo
    echo "========== NAT / IPTables =========="
    echo "10) Create NAT Tunnel"
    echo "11) Remove NAT Tunnel"
    echo "0) Exit"
    echo
    read -rp "Select option: " opt

    case $opt in
        1) create_gre ;;
        2) remove_gre ;;
        3) list_gre ;;
        4) echo "Flushing GRE private IPs..."
           ip addr flush dev $(ip tunnel show | awk '{print $1}') 2>/dev/null
           echo "✅ GRE private IPs removed" ;;
        5) wg_install ;;
        6) wg_generate_keys "iran" ;;
        7) wg_generate_keys "outside" ;;
        8) create_wireguard ;;
        9) remove_wireguard ;;
        10) create_nat ;;
        11) remove_nat ;;
        0) exit 0 ;;
        *) echo "❌ Invalid option"; sleep 1 ;;
    esac

    echo
    read -rp "Press Enter to continue..."
done
