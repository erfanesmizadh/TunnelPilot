#!/bin/bash
set -e

# ================= CONFIG =================
LOG_FILE="/var/log/tunnelpilot.log"
THIS_PUBLIC_IP=$(curl -s ipv4.icanhazip.com || curl -s ifconfig.me)

mkdir -p /etc/tunnelpilot
TOGGLE_FILE="/etc/tunnelpilot/gre-tunnels.conf"
VXLAN_TOGGLE_FILE="/etc/tunnelpilot/vxlan-tunnels.conf"
touch "$TOGGLE_FILE" "$VXLAN_TOGGLE_FILE"

RESTORE_SCRIPT="/usr/local/bin/tunnelpilot_restore.sh"
SYSTEMD_UNIT="/etc/systemd/system/tunnelpilot.service"

# ================= COLORS & LOG =================
color() {
    case $1 in
        red) tput setaf 1 ;;
        green) tput setaf 2 ;;
        yellow) tput setaf 3 ;;
        blue) tput setaf 4 ;;
        *) tput sgr0 ;;
    esac
    shift
    echo -e "$*"
    tput sgr0
}

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

# ================= HEADER =================
header() {
    clear
    echo "=========================================="
    echo "        TunnelPilot | Multi GRE & VxLAN"
    echo "=========================================="
    echo "📍 Server Public IP: $THIS_PUBLIC_IP"
    echo
}

# ================= RANDOM NAMES =================
random_gre_name() { echo "gre$(shuf -i1000-9999 -n1)"; }
random_vxlan_name() { echo "vxlan$(shuf -i1000-9999 -n1)"; }

# ================= IP DEFAULTS =================
DEFAULT_IPV4() { echo "192.168.100.$((RANDOM%250+1))/30"; }
DEFAULT_IPV6() { echo "fdaa:100:100::$((RANDOM%250+1))/64"; }

# ================= VALIDATION =================
validate_ipv4() {
    [[ $1 =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/([0-9]|[1-2][0-9]|3[0-2]))?$ ]] || return 1
}
validate_ipv6() {
    [[ $1 =~ ^([0-9a-fA-F]{0,4}:){2,7}[0-9a-fA-F]{0,4}(/([0-9]|[1-9][0-9]|1[0-1][0-9]|12[0-8]))?$ ]] || return 1
}
validate_vni() {
    (( $1 >= 1 && $1 <= 16777215 )) || return 1
}

# ================= MTU DETECT =================
detect_mtu() {
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

# ================= RESTORE SYSTEMD =================
create_restore_systemd() {
cat > "$RESTORE_SCRIPT" <<'EOF'
#!/bin/bash
TOGGLE_FILE="/etc/tunnelpilot/gre-tunnels.conf"
VXLAN_TOGGLE_FILE="/etc/tunnelpilot/vxlan-tunnels.conf"

# GRE restore
while read -r GRE_NAME LOCAL_IP REMOTE_IP IPV4_LOCAL IPV4_REMOTE IPV6_LOCAL IPV6_REMOTE MTU; do
    [ -z "$GRE_NAME" ] && continue
    if ! ip link show "$GRE_NAME" &>/dev/null; then
        modprobe ip_gre || true
        ip tunnel add "$GRE_NAME" mode gre local "$LOCAL_IP" remote "$REMOTE_IP" ttl 255
        ip link set "$GRE_NAME" mtu "$MTU"
        ip link set "$GRE_NAME" up
        ip addr add "$IPV4_LOCAL" dev "$GRE_NAME" || true
        ip -6 addr add "$IPV6_LOCAL" dev "$GRE_NAME" || true
    fi
done < "$TOGGLE_FILE"

# VxLAN restore
while read -r VXLAN_NAME LOCAL_IP REMOTE_IP VNI IPV4_LOCAL IPV4_REMOTE IPV6_LOCAL IPV6_REMOTE MTU; do
    [ -z "$VXLAN_NAME" ] && continue
    if ! ip link show "$VXLAN_NAME" &>/dev/null; then
        ip link add "$VXLAN_NAME" type vxlan id "$VNI" local "$LOCAL_IP" remote "$REMOTE_IP" dstport 4789
        ip link set "$VXLAN_NAME" mtu "$MTU"
        ip link set "$VXLAN_NAME" up
        ip addr add "$IPV4_LOCAL" dev "$VXLAN_NAME" || true
        ip -6 addr add "$IPV6_LOCAL" dev "$VXLAN_NAME" || true
    fi
done < "$VXLAN_TOGGLE_FILE"
EOF

chmod +x "$RESTORE_SCRIPT"

cat > "$SYSTEMD_UNIT" <<EOF
[Unit]
Description=TunnelPilot Restore
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$RESTORE_SCRIPT
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable tunnelpilot.service
}

# ================= GRE =================
create_gre() {
    echo "1) Random name"
    echo "2) Custom name"
    read -rp "Choice: " name_choice
    [[ "$name_choice" == "1" ]] && GRE_NAME=$(random_gre_name) || read -rp "Tunnel name: " GRE_NAME

    read -rp "Peer Public IP: " REMOTE_PUBLIC_IP
    [[ -z "$REMOTE_PUBLIC_IP" ]] && { color red "Peer IP cannot be empty"; return; }

    DEFAULT_IPV4_LOCAL=$(DEFAULT_IPV4)
    DEFAULT_IPV6_LOCAL=$(DEFAULT_IPV6)

    read -rp "Private IPv4 Local [$DEFAULT_IPV4_LOCAL]: " PRIVATE_IPV4_LOCAL
    PRIVATE_IPV4_LOCAL=${PRIVATE_IPV4_LOCAL:-$DEFAULT_IPV4_LOCAL}

    read -rp "Private IPv6 Local [$DEFAULT_IPV6_LOCAL]: " PRIVATE_IPV6_LOCAL
    PRIVATE_IPV6_LOCAL=${PRIVATE_IPV6_LOCAL:-$DEFAULT_IPV6_LOCAL}

    DETECTED_MTU=$(detect_mtu "$REMOTE_PUBLIC_IP")
    echo "Detected MTU: $DETECTED_MTU"
    read -rp "Enter MTU (Enter = auto detected): " MTU
    MTU=${MTU:-$DETECTED_MTU}

    # Cleanup if exists
    if ip link show "$GRE_NAME" &>/dev/null; then
        ip link del "$GRE_NAME"
    fi

    modprobe ip_gre || true
    ip tunnel add "$GRE_NAME" mode gre local "$THIS_PUBLIC_IP" remote "$REMOTE_PUBLIC_IP" ttl 255
    ip link set "$GRE_NAME" mtu "$MTU"
    ip link set "$GRE_NAME" up

    ip addr add "$PRIVATE_IPV4_LOCAL" dev "$GRE_NAME"
    ip -6 addr add "$PRIVATE_IPV6_LOCAL" dev "$GRE_NAME"

    echo "$GRE_NAME $THIS_PUBLIC_IP $REMOTE_PUBLIC_IP $PRIVATE_IPV4_LOCAL dummy $PRIVATE_IPV6_LOCAL dummy $MTU" >> "$TOGGLE_FILE"

    create_restore_systemd
    color green "✅ GRE Created"
}

remove_gre() {
    read -rp "Tunnel name: " GRE_NAME
    ip link del "$GRE_NAME" 2>/dev/null || true
    sed -i "/^$GRE_NAME /d" "$TOGGLE_FILE"
    color red "❌ GRE Removed"
}

list_gre() {
    echo "=== GRE LIST ==="
    cat "$TOGGLE_FILE"
}

# ================= VXLAN =================
create_vxlan() {
    read -rp "Remote Public IP: " REMOTE_IP
    read -rp "Local Public IP: " LOCAL_IP
    read -rp "VNI: " VNI
    [[ -z "$VNI" ]] && { color red "VNI cannot be empty"; return; }

    VXLAN_NAME=$(random_vxlan_name)

    DETECTED_MTU=$(detect_mtu "$REMOTE_IP")
    echo "Detected MTU: $DETECTED_MTU"
    read -rp "Enter MTU (Enter = auto detected): " MTU
    MTU=${MTU:-$DETECTED_MTU}

    ip link add "$VXLAN_NAME" type vxlan id "$VNI" local "$LOCAL_IP" remote "$REMOTE_IP" dstport 4789
    ip link set "$VXLAN_NAME" mtu "$MTU"
    ip link set "$VXLAN_NAME" up

    echo "$VXLAN_NAME $LOCAL_IP $REMOTE_IP $VNI dummy dummy dummy dummy $MTU" >> "$VXLAN_TOGGLE_FILE"

    create_restore_systemd
    color green "✅ VxLAN Created"
}

remove_vxlan() {
    read -rp "VxLAN name: " NAME
    ip link del "$NAME" 2>/dev/null || true
    sed -i "/^$NAME /d" "$VXLAN_TOGGLE_FILE"
    color red "❌ VxLAN Removed"
}

list_vxlan() {
    echo "=== VXLAN LIST ==="
    cat "$VXLAN_TOGGLE_FILE"
}

# ================= BBR OPTIMIZE =================
enable_bbr() {
    echo "1) BBR"
    echo "2) BBR2"
    echo "3) Cubic"
    read -rp "Select: " choice
    case $choice in
        1) sysctl -w net.ipv4.tcp_congestion_control=bbr ;;
        2) sysctl -w net.ipv4.tcp_congestion_control=bbr2 ;;
        3) sysctl -w net.ipv4.tcp_congestion_control=cubic ;;
        *) color red "Invalid choice"; return ;;
    esac
    echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    sysctl -p
    color green "✅ TCP Optimization Applied"
}

# ================= BACKUP =================
backup_tunnels() {
    cp "$TOGGLE_FILE" "/root/gre_backup_$(date +%F).conf"
    cp "$VXLAN_TOGGLE_FILE" "/root/vxlan_backup_$(date +%F).conf"
    color green "✅ Backups saved in /root"
}

# ================= MENU =================
while true; do
    header
    echo "1) Create GRE Tunnel"
    echo "2) Remove GRE Tunnel"
    echo "3) List GRE"
    echo "4) Enable TCP BBR / BBR2 / Cubic"
    echo "5) Backup Tunnel Configs"
    echo "6) Restore Tunnel Configs (Systemd)"
    echo "7) Create VxLAN"
    echo "8) List VxLAN"
    echo "9) Remove VxLAN"
    echo "0) Exit"
    read -rp "Select: " opt
    case $opt in
        1) create_gre ;;
        2) remove_gre ;;
        3) list_gre ;;
        4) enable_bbr ;;
        5) backup_tunnels ;;
        6) systemctl restart tunnelpilot && systemctl status tunnelpilot ;;
        7) create_vxlan ;;
        8) list_vxlan ;;
        9) remove_vxlan ;;
        0) exit ;;
        *) color red "Invalid"; sleep 1 ;;
    esac
    read -rp "Press Enter to continue..."
done
