#!/bin/bash
set -e

LOG_FILE="/var/log/wireguard-menu.log"

# ============================
# Header
# ============================
function header() {
    clear
    echo "=========================================="
    echo "       WireGuard Tunnel Helper Menu"
    echo "=========================================="
}

# ============================
# Generate WireGuard Keys
# ============================
function generate_key() {
    read -rp "🌐 Server name (Iran/Outside): " SERVER
    PRIV_KEY=$(wg genkey)
    PUB_KEY=$(echo $PRIV_KEY | wg pubkey)

    mkdir -p /etc/wireguard
    echo "$PRIV_KEY" > /etc/wireguard/${SERVER}_private.key
    echo "$PUB_KEY" > /etc/wireguard/${SERVER}_public.key
    chmod 600 /etc/wireguard/${SERVER}_private.key

    echo "✅ Keys generated for $SERVER"
    echo "Private Key: $PRIV_KEY"
    echo "Public Key : $PUB_KEY"
    echo "$(date) | Keys $SERVER" >> $LOG_FILE
}

# ============================
# Setup Tunnel IPs
# ============================
function setup_tunnel_ip() {
    read -rp "🌐 Server name (Iran/Outside): " SERVER
    read -rp "🔹 Enter Private IPv4 (e.g. 10.200.200.X/30): " IPV4
    read -rp "🔹 Enter Private IPv6 (e.g. fd50::X/64): " IPV6

    mkdir -p /etc/wireguard
    echo "$IPV4" > /etc/wireguard/${SERVER}_ipv4.txt
    echo "$IPV6" > /etc/wireguard/${SERVER}_ipv6.txt

    echo "✅ IPs saved for $SERVER"
    echo "$(date) | IPs $SERVER: $IPV4 / $IPV6" >> $LOG_FILE
}

# ============================
# Delete Tunnel IPs
# ============================
function delete_tunnel_ip() {
    read -rp "🌐 Server name (Iran/Outside) to delete IPs: " SERVER
    rm -f /etc/wireguard/${SERVER}_ipv4.txt
    rm -f /etc/wireguard/${SERVER}_ipv6.txt

    echo "🗑 Tunnel IPs deleted for $SERVER"
    echo "$(date) | Deleted IPs $SERVER" >> $LOG_FILE
}

# ============================
# Install WireGuard & prerequisites
# ============================
function install_wireguard() {
    echo "🔧 Installing WireGuard and prerequisites..."
    apt update
    apt install -y wireguard iptables resolvconf qrencode
    echo "✅ WireGuard installed"
    echo "$(date) | WireGuard installed" >> $LOG_FILE
}

# ============================
# Setup iptables NAT for VLESS port
# ============================
function setup_iptables() {
    read -rp "🔹 Enter local port (e.g. 443-99999): " LOCAL_PORT
    read -rp "🔹 Enter remote private IPv4 (from tunnel): " REMOTE_IP
    read -rp "🔹 Enter remote port (VLESS port, e.g., 8880): " REMOTE_PORT

    sudo iptables -t nat -A PREROUTING -p tcp --dport "$LOCAL_PORT" -j DNAT --to-destination "$REMOTE_IP:$REMOTE_PORT"
    sudo iptables -t nat -A POSTROUTING -j MASQUERADE

    echo "✅ NAT created: $LOCAL_PORT → $REMOTE_IP:$REMOTE_PORT"
    echo "$(date) | NAT $LOCAL_PORT->$REMOTE_IP:$REMOTE_PORT" >> $LOG_FILE
}

# ============================
# Remove iptables NAT
# ============================
function remove_iptables() {
    sudo iptables -t nat -F
    echo "🗑 NAT rules cleared"
    echo "$(date) | NAT cleared" >> $LOG_FILE
}

# ============================
# Main Menu
# ============================
while true; do
    header
    echo "🔹 WireGuard Menu 🔹"
    echo "1) Generate WireGuard Keys (Iran or Outside)"
    echo "2) Set Private IPv4/IPv6 for Tunnel (Iran or Outside)"
    echo "3) Delete Private IPv4/IPv6 for Tunnel"
    echo "4) Install WireGuard & prerequisites"
    echo "5) Setup iptables NAT for VLESS port"
    echo "6) Remove iptables NAT"
    echo "0) Exit"
    echo
    read -rp "Select option: " opt

    case $opt in
        1) generate_key ;;
        2) setup_tunnel_ip ;;
        3) delete_tunnel_ip ;;
        4) install_wireguard ;;
        5) setup_iptables ;;
        6) remove_iptables ;;
        0) exit 0 ;;
        *) echo "❌ Invalid option"; sleep 1 ;;
    esac

    echo
    read -rp "Press Enter to continue..."
done
