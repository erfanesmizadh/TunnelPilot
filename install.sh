#!/bin/bash
set -e

LOG_FILE="/var/log/tunnelpilot.log"
THIS_PUBLIC_IP=$(curl -s ipv4.icanhazip.com || curl -s ifconfig.me)

# پوشه و فایل ذخیره تونل‌ها
mkdir -p /etc/tunnelpilot
TOGGLE_FILE="/etc/tunnelpilot/gre-tunnels.conf"
VXLAN_TOGGLE_FILE="/etc/tunnelpilot/vxlan-tunnels.conf"
touch "$TOGGLE_FILE"
touch "$VXLAN_TOGGLE_FILE"

RESTORE_SCRIPT="/usr/local/bin/tunnelpilot_restore.sh"
SYSTEMD_UNIT="/etc/systemd/system/tunnelpilot.service"

function header() {
    clear
    echo "=========================================="
    echo "        TunnelPilot | Multi GRE & VxLAN"
    echo "=========================================="
    echo "📍 Server Public IP: $THIS_PUBLIC_IP"
    echo
}

function random_gre_name() { echo "gre$(tr -dc '0-9' </dev/urandom | head -c 4)"; }
function random_vxlan_name() { echo "vxlan$(tr -dc '0-9' </dev/urandom | head -c 4)"; }

function enable_bbr() {
    echo "Select TCP Congestion Control:"
    echo "1) BBR"; echo "2) BBR2"; echo "3) Cubic"
    read -rp "Choice: " bbr
    case $bbr in 1) algo="bbr";; 2) algo="bbr2";; 3) algo="cubic";; *) echo "Invalid"; return;; esac
    if ! sysctl net.ipv4.tcp_available_congestion_control | grep -qw "$algo"; then echo "Not supported"; return; fi
    sed -i '/net.core.default_qdisc/d;/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
    cat >> /etc/sysctl.conf <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=$algo
EOF
    sysctl -p >/dev/null
    echo "$(date) | TCP $algo" >> $LOG_FILE
}

function detect_mtu() {
    REMOTE_IP="$1"; mtu=1500
    while [[ $mtu -gt 1200 ]]; do
        if ping -M do -s $((mtu-28)) -c 1 "$REMOTE_IP" &>/dev/null; then echo $mtu; return; fi
        mtu=$((mtu-10))
    done
    echo 1400
}

function create_restore_systemd() {
cat > "$RESTORE_SCRIPT" <<'RESTORE_EOF'
#!/bin/bash
TOGGLE_FILE="/etc/tunnelpilot/gre-tunnels.conf"
VXLAN_TOGGLE_FILE="/etc/tunnelpilot/vxlan-tunnels.conf"
LOG_FILE="/var/log/tunnelpilot.log"

# Restore GRE
[[ -f "$TOGGLE_FILE" ]] && while read -r GRE_NAME LOCAL_IP REMOTE_IP IPV4 IPV6 MTU; do
    if ! ip link show "$GRE_NAME" &>/dev/null; then
        modprobe ip_gre || true
        ip tunnel add "$GRE_NAME" mode gre local "$LOCAL_IP" remote "$REMOTE_IP" ttl 255
        ip link set "$GRE_NAME" mtu "$MTU"
        ip link set "$GRE_NAME" up
        ip addr add "$IPV4" dev "$GRE_NAME"
        ip -6 addr add "$IPV6" dev "$GRE_NAME"
        echo "$(date) | RESTORE GRE $GRE_NAME $REMOTE_IP MTU:$MTU" >> $LOG_FILE
    fi
done < "$TOGGLE_FILE"

# Restore VxLAN
[[ -f "$VXLAN_TOGGLE_FILE" ]] && while read -r VXLAN_NAME LOCAL_IP REMOTE_IP VNI IPV4_LOCAL IPV4_REMOTE IPV6_LOCAL IPV6_REMOTE MTU; do
    if ! ip link show "$VXLAN_NAME" &>/dev/null; then
        ip link add "$VXLAN_NAME" type vxlan id "$VNI" local "$LOCAL_IP" remote "$REMOTE_IP" dstport 4789
        ip link set "$VXLAN_NAME" mtu "$MTU"
        ip link set "$VXLAN_NAME" up
        ip addr add "$IPV4_LOCAL" dev "$VXLAN_NAME"
        ip -6 addr add "$IPV6_LOCAL" dev "$VXLAN_NAME"
        echo "$(date) | RESTORE VxLAN $VXLAN_NAME $REMOTE_IP VNI:$VNI MTU:$MTU" >> $LOG_FILE
    fi
done < "$VXLAN_TOGGLE_FILE"
RESTORE_EOF

chmod +x "$RESTORE_SCRIPT"

cat > "$SYSTEMD_UNIT" <<EOF
[Unit]
Description=TunnelPilot GRE & VxLAN Restore
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
systemctl start tunnelpilot.service
}

[[ -f "$TOGGLE_FILE" ]] && bash "$RESTORE_SCRIPT"
[[ -f "$VXLAN_TOGGLE_FILE" ]] && bash "$RESTORE_SCRIPT"

# ============================
# GRE
# ============================
function create_gre() {
    echo "Tunnel name:"; echo "1) Random"; echo "2) Custom"
    read -rp "Choice: " name_choice
    [[ "$name_choice" == "1" ]] && GRE_NAME=$(random_gre_name) || read -rp "Enter tunnel name: " GRE_NAME
    read -rp "Peer Public IP: " REMOTE_PUBLIC_IP
    read -rp "Private IPv4 Local: " PRIVATE_IPV4_LOCAL
    read -rp "Private IPv4 Remote: " PRIVATE_IPV4_REMOTE
    read -rp "Private IPv6 Local: " PRIVATE_IPV6_LOCAL
    read -rp "Private IPv6 Remote: " PRIVATE_IPV6_REMOTE
    DETECTED_MTU=$(detect_mtu "$REMOTE_PUBLIC_IP")
    read -rp "MTU [$DETECTED_MTU]: " MTU
    MTU=${MTU:-$DETECTED_MTU}

    modprobe ip_gre || true
    ip tunnel add "$GRE_NAME" mode gre local "$THIS_PUBLIC_IP" remote "$REMOTE_PUBLIC_IP" ttl 255
    ip link set "$GRE_NAME" mtu "$MTU"; ip link set "$GRE_NAME" up
    ip addr add "$PRIVATE_IPV4_LOCAL" dev "$GRE_NAME"
    ip -6 addr add "$PRIVATE_IPV6_LOCAL" dev "$GRE_NAME"
    iptables -C INPUT -p gre -j ACCEPT 2>/dev/null || iptables -A INPUT -p gre -j ACCEPT

    echo "$GRE_NAME $THIS_PUBLIC_IP $REMOTE_PUBLIC_IP $PRIVATE_IPV4_LOCAL $PRIVATE_IPV4_REMOTE $PRIVATE_IPV6_LOCAL $PRIVATE_IPV6_REMOTE $MTU" >> "$TOGGLE_FILE"
    [[ ! -f "$RESTORE_SCRIPT" || ! -f "$SYSTEMD_UNIT" ]] && create_restore_systemd
}

# ============================
# VxLAN
# ============================
function create_vxlan() {
    echo "VxLAN name:"; echo "1) Random"; echo "2) Custom"
    read -rp "Choice: " name_choice
    [[ "$name_choice" == "1" ]] && VXLAN_NAME=$(random_vxlan_name) || read -rp "Enter VxLAN name: " VXLAN_NAME
    read -rp "Remote IP (Public): " REMOTE_IP
    read -rp "Local IP (Public): " LOCAL_IP
    read -rp "Private IPv4 Local: " IPV4_LOCAL
    read -rp "Private IPv4 Remote: " IPV4_REMOTE
    read -rp "Private IPv6 Local: " IPV6_LOCAL
    read -rp "Private IPv6 Remote: " IPV6_REMOTE
    read -rp "VxLAN ID (VNI): " VNI
    DETECTED_MTU=$(detect_mtu "$REMOTE_IP")
    read -rp "MTU [$DETECTED_MTU]: " MTU
    MTU=${MTU:-$DETECTED_MTU}

    ip link add "$VXLAN_NAME" type vxlan id "$VNI" local "$LOCAL_IP" remote "$REMOTE_IP" dstport 4789
    ip link set "$VXLAN_NAME" mtu "$MTU"; ip link set "$VXLAN_NAME" up
    ip addr add "$IPV4_LOCAL" dev "$VXLAN_NAME"
    ip -6 addr add "$IPV6_LOCAL" dev "$VXLAN_NAME"

    echo "$VXLAN_NAME $LOCAL_IP $REMOTE_IP $VNI $IPV4_LOCAL $IPV4_REMOTE $IPV6_LOCAL $IPV6_REMOTE $MTU" >> "$VXLAN_TOGGLE_FILE"
    [[ ! -f "$RESTORE_SCRIPT" || ! -f "$SYSTEMD_UNIT" ]] && create_restore_systemd
}

# ============================
# Main Menu
# ============================
while true; do
    header
    echo "1) Create GRE Tunnel"
    echo "2) Remove GRE Tunnel"
    echo "3) List GRE Tunnels"
    echo "4) Enable TCP BBR / BBR2 / Cubic"
    echo "5) Create NAT Tunnel"
    echo "6) Remove NAT Tunnel"
    echo "7) Create VxLAN Tunnel"
    echo "8) List VxLAN Tunnels"
    echo "9) Remove VxLAN Tunnel"
    echo "0) Exit"
    read -rp "Select option: " opt
    case $opt in
        1) create_gre ;;
        2) remove_gre ;;
        3) list_gre ;;
        4) enable_bbr ;;
        5) create_iptables_tunnel ;;
        6) remove_iptables_tunnel ;;
        7) create_vxlan ;;
        8) list_vxlan ;;
        9) remove_vxlan ;;
        0) exit 0 ;;
        *) echo "Invalid"; sleep 1 ;;
    esac
    echo; read -rp "Press Enter to continue..."
done
