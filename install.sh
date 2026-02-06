#!/bin/bash
set -e

LOG_FILE="/var/log/tunnelpilot.log"
THIS_PUBLIC_IP=$(curl -s ipv4.icanhazip.com || curl -s ifconfig.me)

# پوشه و فایل ذخیره تونل‌ها
mkdir -p /etc/tunnelpilot
TOGGLE_FILE="/etc/tunnelpilot/gre-tunnels.conf"
touch "$TOGGLE_FILE"

VXLAN_TOGGLE_FILE="/etc/tunnelpilot/vxlan-tunnels.conf"
touch "$VXLAN_TOGGLE_FILE"

# مسیر اسکریپت restore و systemd
RESTORE_SCRIPT="/usr/local/bin/tunnelpilot_restore.sh"
SYSTEMD_UNIT="/etc/systemd/system/tunnelpilot.service"

# ============================
# Utils
# ============================
function header() {
    clear
    echo "=========================================="
    echo "        TunnelPilot | Multi GRE & VxLAN"
    echo "=========================================="
    echo "📍 This Server Public IP: $THIS_PUBLIC_IP"
    echo
}

function random_gre_name() {
    echo "gre$(tr -dc '0-9' </dev/urandom | head -c 4)"
}

function random_vxlan_name() {
    echo "vxlan$(tr -dc '0-9' </dev/urandom | head -c 4)"
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

function detect_vxlan_mtu() {
    REMOTE_IP="$1"
    mtu=1450
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
# Create restore script + systemd (if not exist)
# ============================
function create_restore_systemd() {
    # Restore script
    cat > "$RESTORE_SCRIPT" <<'EOF'
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
[[ -f "$VXLAN_TOGGLE_FILE" ]] && while read -r VXLAN_NAME LOCAL_IP REMOTE_IP VNI MTU; do
    if ! ip link show "$VXLAN_NAME" &>/dev/null; then
        ip link add "$VXLAN_NAME" type vxlan id "$VNI" local "$LOCAL_IP" remote "$REMOTE_IP" dstport 4789
        ip link set "$VXLAN_NAME" mtu "$MTU"
        ip link set "$VXLAN_NAME" up
        echo "$(date) | RESTORE VxLAN $VXLAN_NAME $REMOTE_IP VNI:$VNI MTU:$MTU" >> $LOG_FILE
    fi
done < "$VXLAN_TOGGLE_FILE"
EOF

    chmod +x "$RESTORE_SCRIPT"

    # systemd unit
    cat > "$SYSTEMD_UNIT" <<EOF
[Unit]
Description=TunnelPilot GRE & VxLAN Restore Service
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

# ============================
# Restore GRE + VxLAN
# ============================
function restore_gre_tunnels() {
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
}

function restore_vxlan_tunnels() {
    [[ -f "$VXLAN_TOGGLE_FILE" ]] && while read -r VXLAN_NAME LOCAL_IP REMOTE_IP VNI MTU; do
        if ! ip link show "$VXLAN_NAME" &>/dev/null; then
            ip link add "$VXLAN_NAME" type vxlan id "$VNI" local "$LOCAL_IP" remote "$REMOTE_IP" dstport 4789
            ip link set "$VXLAN_NAME" mtu "$MTU"
            ip link set "$VXLAN_NAME" up
            echo "$(date) | RESTORE VxLAN $VXLAN_NAME $REMOTE_IP VNI:$VNI MTU:$MTU" >> $LOG_FILE
        fi
    done < "$VXLAN_TOGGLE_FILE"
}

# ============================
# Create Multi GRE
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

    echo "$GRE_NAME $THIS_PUBLIC_IP $REMOTE_PUBLIC_IP $PRIVATE_IPV4 $PRIVATE_IPV6 $MTU" >> "$TOGGLE_FILE"
    echo "$(date) | ADD GRE $GRE_NAME $REMOTE_PUBLIC_IP MTU:$MTU" >> $LOG_FILE

    [[ ! -f "$RESTORE_SCRIPT" || ! -f "$SYSTEMD_UNIT" ]] && create_restore_systemd
}

# ============================
# Create VxLAN
# ============================
function create_vxlan() {
    echo "🆔 VxLAN name:"
    echo "1) Random"
    echo "2) Custom"
    read -rp "Choice: " name_choice

    if [[ "$name_choice" == "1" ]]; then
        VXLAN_NAME=$(random_vxlan_name)
    else
        read -rp "Enter VxLAN name (e.g. vxlan-iran1): " VXLAN_NAME
    fi

    echo "🌐 Remote IP (IPv4 or IPv6):"
    read -rp "> " REMOTE_IP

    echo "🔹 Local IP (IPv4 or IPv6):"
    read -rp "> " LOCAL_IP

    echo "🔹 VxLAN ID (VNI, e.g. 100):"
    read -rp "> " VNI

    DETECTED_MTU=$(detect_vxlan_mtu "$REMOTE_IP")
    echo "⚡ Detected optimal MTU: $DETECTED_MTU"
    read -rp "MTU [$DETECTED_MTU]: " MTU
    MTU=${MTU:-$DETECTED_MTU}

    echo
    echo "📋 Summary"
    echo "VxLAN name : $VXLAN_NAME"
    echo "Local IP   : $LOCAL_IP"
    echo "Remote IP  : $REMOTE_IP"
    echo "VNI        : $VNI"
    echo "MTU        : $MTU"
    read -rp "Continue? (y/n): " c
    [[ "$c" != "y" ]] && return

    ip link add "$VXLAN_NAME" type vxlan id "$VNI" local "$LOCAL_IP" remote "$REMOTE_IP" dstport 4789
    ip link set "$VXLAN_NAME" mtu "$MTU"
    ip link set "$VXLAN_NAME" up

    echo "✅ VxLAN $VXLAN_NAME created with VNI $VNI and MTU $MTU"
    ip addr show "$VXLAN_NAME"

    echo "$VXLAN_NAME $LOCAL_IP $REMOTE_IP $VNI $MTU" >> "$VXLAN_TOGGLE_FILE"
    echo "$(date) | ADD VxLAN $VXLAN_NAME $REMOTE_IP VNI:$VNI MTU:$MTU" >> $LOG_FILE

    [[ ! -f "$RESTORE_SCRIPT" || ! -f "$SYSTEMD_UNIT" ]] && create_restore_systemd
}

# ============================
# List / Remove
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

function remove_gre() {
    tunnels=($(ip tunnel show | awk '{print $1}'))
    if [[ ${#tunnels[@]} -eq 0 ]]; then
        echo "— No GRE tunnels found —"
        return
    fi
    list_gre
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
        sed -i "/^$GRE_NAME /d" "$TOGGLE_FILE"
        echo "🗑 $GRE_NAME removed"
        echo "$(date) | DEL GRE $GRE_NAME" >> $LOG_FILE
    else
        echo "❌ Tunnel not found"
    fi
}

function list_vxlan() {
    echo "📡 Active VxLAN tunnels:"
    if [[ ! -f "$VXLAN_TOGGLE_FILE" || ! -s "$VXLAN_TOGGLE_FILE" ]]; then
        echo "— none —"
        return
    fi
    while read -r NAME LOCAL REMOTE VNI MTU; do
        echo "$NAME | Local: $LOCAL | Remote: $REMOTE | VNI: $VNI | MTU: $MTU"
    done < "$VXLAN_TOGGLE_FILE"
}

function remove_vxlan() {
    if [[ ! -f "$VXLAN_TOGGLE_FILE" || ! -s "$VXLAN_TOGGLE_FILE" ]]; then
        echo "— No VxLAN tunnels found —"
        return
    fi
    list_vxlan
    read -rp "Enter VxLAN name to remove: " VXLAN_NAME
    if ip link show "$VXLAN_NAME" &>/dev/null; then
        read -rp "⚠️ Are you sure you want to delete $VXLAN_NAME? (y/n): " confirm
        [[ "$confirm" != "y" ]] && echo "Cancelled" && return
        ip link del "$VXLAN_NAME"
        sed -i "/^$VXLAN_NAME /d" "$VXLAN_TOGGLE_FILE"
        echo "🗑 $VXLAN_NAME removed"
        echo "$(date) | DEL VxLAN $VXLAN_NAME" >> $LOG_FILE
    else
        echo "❌ VxLAN not found"
    fi
}

# ============================
# NAT Tunnel
# ============================
function create_iptables_tunnel() {
    echo "🌐 Remote GRE IP (IPv4 or IPv6) of remote server:"
    read -rp "> " REMOTE_IP

    echo "🔹 Local port (port users connect to on this server, e.g., 2096):"
    read -rp "> " LOCAL_PORT

    echo "🔹 Remote port (port Xray listens on remote server, e.g., 2096):"
    read -rp "> " REMOTE_PORT

    if [[ "$REMOTE_IP" == *:* ]]; then
        IPT_CMD="ip6tables"
        SYSCTL_KEY="net.ipv6.conf.all.forwarding"
    else
        IPT_CMD="iptables"
        SYSCTL_KEY="net.ipv4.ip_forward"
    fi

    sysctl -w $SYSCTL_KEY=1 >/dev/null

    $IPT_CMD -t nat -D PREROUTING -p tcp --dport "$LOCAL_PORT" -j DNAT --to-destination "$REMOTE_IP:$REMOTE_PORT" 2>/dev/null || true
    $IPT_CMD -t nat -D POSTROUTING -j MASQUERADE 2>/dev/null || true

    $IPT_CMD -t nat -A PREROUTING -p tcp --dport "$LOCAL_PORT" -j DNAT --to-destination "$REMOTE_IP:$REMOTE_PORT"
    $IPT_CMD -t nat -A POSTROUTING -j MASQUERADE

    echo "✅ NAT created: $LOCAL_PORT → $REMOTE_IP:$REMOTE_PORT"
    echo "$(date) | NAT $LOCAL_PORT->$REMOTE_IP:$REMOTE_PORT" >> $LOG_FILE
}

function remove_iptables_tunnel() {
    iptables -t nat -F
    ip6tables -t nat -F
    echo "🗑 NAT rules cleared"
    echo "$(date) | NAT
