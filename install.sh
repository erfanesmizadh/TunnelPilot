#!/bin/bash
set -e

LOG_FILE="/var/log/tunnelpilot.log"
THIS_PUBLIC_IP=$(curl -s ipv4.icanhazip.com || curl -s ifconfig.me)

mkdir -p /etc/tunnelpilot

TOGGLE_FILE="/etc/tunnelpilot/gre-tunnels.conf"
VXLAN_TOGGLE_FILE="/etc/tunnelpilot/vxlan-tunnels.conf"

touch "$TOGGLE_FILE"
touch "$VXLAN_TOGGLE_FILE"

RESTORE_SCRIPT="/usr/local/bin/tunnelpilot_restore.sh"
SYSTEMD_UNIT="/etc/systemd/system/tunnelpilot.service"

# ================= HEADER =================
header() {
clear
echo "=========================================="
echo "        TunnelPilot | Multi GRE & VxLAN"
echo "=========================================="
echo "📍 Server Public IP: $THIS_PUBLIC_IP"
echo
}

random_gre_name() { echo "gre$(shuf -i1000-9999 -n1)"; }
random_vxlan_name() { echo "vxlan$(shuf -i1000-9999 -n1)"; }

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
read -rp "Private IPv4 Local (x.x.x.x/30): " PRIVATE_IPV4_LOCAL
read -rp "Private IPv6 Local: " PRIVATE_IPV6_LOCAL

MTU=$(detect_mtu "$REMOTE_PUBLIC_IP")

modprobe ip_gre || true

ip tunnel add "$GRE_NAME" mode gre local "$THIS_PUBLIC_IP" remote "$REMOTE_PUBLIC_IP" ttl 255
ip link set "$GRE_NAME" mtu "$MTU"
ip link set "$GRE_NAME" up

ip addr add "$PRIVATE_IPV4_LOCAL" dev "$GRE_NAME"
ip -6 addr add "$PRIVATE_IPV6_LOCAL" dev "$GRE_NAME"

echo "$GRE_NAME $THIS_PUBLIC_IP $REMOTE_PUBLIC_IP $PRIVATE_IPV4_LOCAL dummy $PRIVATE_IPV6_LOCAL dummy $MTU" >> "$TOGGLE_FILE"

create_restore_systemd

echo "✅ GRE Created"
}

remove_gre() {
read -rp "Tunnel name: " GRE_NAME
ip link del "$GRE_NAME" 2>/dev/null || true
sed -i "/^$GRE_NAME /d" "$TOGGLE_FILE"
echo "❌ GRE Removed"
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

VXLAN_NAME=$(random_vxlan_name)

MTU=$(detect_mtu "$REMOTE_IP")

ip link add "$VXLAN_NAME" type vxlan id "$VNI" local "$LOCAL_IP" remote "$REMOTE_IP" dstport 4789
ip link set "$VXLAN_NAME" mtu "$MTU"
ip link set "$VXLAN_NAME" up

echo "$VXLAN_NAME $LOCAL_IP $REMOTE_IP $VNI dummy dummy dummy dummy $MTU" >> "$VXLAN_TOGGLE_FILE"

create_restore_systemd

echo "✅ VxLAN Created"
}

remove_vxlan() {
read -rp "VxLAN name: " NAME
ip link del "$NAME" 2>/dev/null || true
sed -i "/^$NAME /d" "$VXLAN_TOGGLE_FILE"
echo "❌ VxLAN Removed"
}

list_vxlan() {
echo "=== VXLAN LIST ==="
cat "$VXLAN_TOGGLE_FILE"
}

# ================= MENU =================
while true; do

header

echo "1) Create GRE Tunnel"
echo "2) Remove GRE Tunnel"
echo "3) List GRE"
echo "7) Create VxLAN"
echo "8) List VxLAN"
echo "9) Remove VxLAN"
echo "0) Exit"

read -rp "Select: " opt

case $opt in
1) create_gre ;;
2) remove_gre ;;
3) list_gre ;;
7) create_vxlan ;;
8) list_vxlan ;;
9) remove_vxlan ;;
0) exit ;;
esac

read -rp "Enter to continue..."

done
