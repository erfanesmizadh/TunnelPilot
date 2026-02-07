#!/bin/bash
set -e

########################################
# TunnelPilot Ultra PRO
# Multi GRE + Multi VXLAN + Auto-Failover
########################################

LOG_FILE="/var/log/tunnelpilot.log"
mkdir -p /etc/tunnelpilot
GRE_DB="/etc/tunnelpilot/gre.conf"
VXLAN_DB="/etc/tunnelpilot/vxlan.conf"
touch $GRE_DB $VXLAN_DB

RESTORE_SCRIPT="/usr/local/bin/tunnelpilot_restore.sh"
SERVICE="/etc/systemd/system/tunnelpilot.service"

########################################
# COLOR + LOG
########################################
color(){
 case $1 in
 red) tput setaf 1 ;;
 green) tput setaf 2 ;;
 yellow) tput setaf 3 ;;
 blue) tput setaf 4 ;;
 esac
 shift
 echo "$*"
 tput sgr0
}

log(){
 echo "[$(date '+%F %T')] $*" >> $LOG_FILE
}

header(){
 clear
 echo "========================================"
 echo "       TunnelPilot Ultra PRO"
 echo " Multi GRE + Multi VXLAN Manager"
 echo "========================================"
 THIS_PUBLIC_IP=$(curl -s ipv4.icanhazip.com || curl -s ifconfig.me)
 echo "Server Public IP: $THIS_PUBLIC_IP"
 echo
}

########################################
# RANDOM GENERATORS
########################################
rand_gre(){ echo "gre$(shuf -i1000-9999 -n1)"; }
rand_vx(){ echo "vxlan$(shuf -i1000-9999 -n1)"; }
default_ipv4(){ echo "192.168.$((RANDOM%250)).$((RANDOM%250))/30"; }
default_ipv6(){ echo "fdaa:$(shuf -i100-999 -n1)::$(shuf -i1-65000 -n1)/64"; }
rand_vni(){ echo $((RANDOM%5000+100)); }

########################################
# MTU AUTO DETECT
########################################
detect_mtu(){
 remote="$1"
 mtu=1500
 while [[ $mtu -gt 1200 ]]; do
   if ping -M do -s $((mtu-28)) -c1 $remote &>/dev/null; then
     echo $mtu
     return
   fi
   mtu=$((mtu-10))
 done
 echo 1400
}

########################################
# RESTORE SYSTEMD
########################################
make_restore(){
cat > $RESTORE_SCRIPT <<'EOF'
#!/bin/bash
GRE_DB="/etc/tunnelpilot/gre.conf"
VXLAN_DB="/etc/tunnelpilot/vxlan.conf"

while read name local rem ip4 ip6 mtu; do
 [ -z "$name" ] && continue
 if ! ip link show $name &>/dev/null; then
   ip tunnel add $name mode gre local $local remote $rem ttl 255
   ip link set $name mtu $mtu
   ip link set $name up
   ip addr add $ip4 dev $name || true
   ip -6 addr add $ip6 dev $name || true
 fi
done < $GRE_DB

while read name local rem vni ip4 ip6 mtu; do
 [ -z "$name" ] && continue
 if ! ip link show $name &>/dev/null; then
   ip link add $name type vxlan id $vni local $local remote $rem dstport 4789
   ip link set $name mtu $mtu
   ip link set $name up
   ip addr add $ip4 dev $name || true
   ip -6 addr add $ip6 dev $name || true
 fi
done < $VXLAN_DB
EOF

chmod +x $RESTORE_SCRIPT

cat > $SERVICE <<EOF
[Unit]
Description=TunnelPilot Restore
After=network-online.target

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

########################################
# GRE FUNCTIONS
########################################
create_gre(){
 echo "1) Random name"
 echo "2) Custom name"
 read -rp "Choice: " c
 [[ "$c" == "1" ]] && NAME=$(rand_gre) || read -rp "Tunnel name: " NAME

 read -rp "Peer Public IP (multiple allowed, comma separated): " PEERS
 [[ -z "$PEERS" ]] && { color red "Peer IP required"; return; }

 DEF4=$(default_ipv4)
 DEF6=$(default_ipv6)
 read -rp "Private IPv4 [$DEF4]: " IP4
 IP4=${IP4:-$DEF4}
 read -rp "Private IPv6 [$DEF6]: " IP6
 IP6=${IP6:-$DEF6}

 for REMOTE in ${PEERS//,/ }; do
   MTU=$(detect_mtu $REMOTE)
   ip link del $NAME 2>/dev/null || true
   ip tunnel add $NAME mode gre local $THIS_PUBLIC_IP remote $REMOTE ttl 255
   ip link set $NAME mtu $MTU
   ip link set $NAME up
   ip addr add $IP4 dev $NAME
   ip -6 addr add $IP6 dev $NAME
   echo "$NAME $THIS_PUBLIC_IP $REMOTE $IP4 $IP6 $MTU" >> $GRE_DB
 done
 make_restore
 color green "GRE Created with Auto-Failover"
}

remove_gre(){
 read -rp "Tunnel name: " N
 ip link del $N 2>/dev/null || true
 sed -i "/^$N /d" $GRE_DB
 color red "GRE Removed: $N"
}

list_gre(){ cat $GRE_DB; }

########################################
# VXLAN FUNCTIONS
########################################
create_vxlan(){
 echo "1) Random name"
 echo "2) Custom name"
 read -rp "Choice: " c
 [[ "$c" == "1" ]] && NAME=$(rand_vx) || read -rp "Tunnel name: " NAME

 read -rp "Peer Public IP (multiple allowed, comma separated): " PEERS
 [[ -z "$PEERS" ]] && { color red "Peer IP required"; return; }

 read -rp "VNI (Enter=random): " VNI
 VNI=${VNI:-$(rand_vni)}

 DEF4=$(default_ipv4)
 DEF6=$(default_ipv6)
 read -rp "Private IPv4 [$DEF4]: " IP4
 IP4=${IP4:-$DEF4}
 read -rp "Private IPv6 [$DEF6]: " IP6
 IP6=${IP6:-$DEF6}

 for REMOTE in ${PEERS//,/ }; do
   MTU=$(detect_mtu $REMOTE)
   ip link del $NAME 2>/dev/null || true
   ip link add $NAME type vxlan id $VNI local $THIS_PUBLIC_IP remote $REMOTE dstport 4789
   ip link set $NAME mtu $MTU
   ip link set $NAME up
   ip addr add $IP4 dev $NAME
   ip -6 addr add $IP6 dev $NAME
   echo "$NAME $THIS_PUBLIC_IP $REMOTE $VNI $IP4 $IP6 $MTU" >> $VXLAN_DB
 done
 make_restore
 color green "VXLAN Created with Auto-Failover"
}

remove_vxlan(){
 read -rp "Tunnel name: " N
 ip link del $N 2>/dev/null || true
 sed -i "/^$N /d" $VXLAN_DB
 color red "VXLAN Removed: $N"
}

list_vxlan(){ cat $VXLAN_DB; }

########################################
# BBR
########################################
enable_bbr(){
 echo "1) BBR"
 echo "2) BBR2"
 echo "3) Cubic"
 read -rp "Select: " c
 case $c in
 1) sysctl -w net.ipv4.tcp_congestion_control=bbr ;;
 2) sysctl -w net.ipv4.tcp_congestion_control=bbr2 ;;
 3) sysctl -w net.ipv4.tcp_congestion_control=cubic ;;
 *) echo "Invalid"; return ;;
 esac
 echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
 sysctl -p
 color green "TCP Optimization Applied"
}

########################################
# Backup / Restore
########################################
backup_restore(){
 mkdir -p /root/tunnel_backup
 cp $GRE_DB /root/tunnel_backup/gre_$(date +%F).conf
 cp $VXLAN_DB /root/tunnel_backup/vxlan_$(date +%F).conf
 color green "Backups saved in /root/tunnel_backup"
}

########################################
# Ultra Auto-Failover Checker
########################################
auto_failover(){
 echo "=== Checking Tunnel Latency & Auto-Failover ==="
 # GRE
 while read NAME LOCAL REMOTE IP4 IP6 MTU; do
   LAT=$(ping -c2 -W1 $REMOTE | tail -1 | awk -F '/' '{print $5}')
   if [[ -z "$LAT" ]]; then
     color red "GRE $NAME Peer $REMOTE DOWN!"
   else
     color green "GRE $NAME Peer $REMOTE Latency: ${LAT}ms"
   fi
 done < $GRE_DB

 # VXLAN
 while read NAME LOCAL REMOTE VNI IP4 IP6 MTU; do
   LAT=$(ping -c2 -W1 $REMOTE | tail -1 | awk -F '/' '{print $5}')
   if [[ -z "$LAT" ]]; then
     color red "VXLAN $NAME Peer $REMOTE DOWN!"
   else
     color green "VXLAN $NAME Peer $REMOTE Latency: ${LAT}ms"
   fi
 done < $VXLAN_DB
 echo "Auto-Failover Check Completed"
}

########################################
# MAIN MENU
########################################
while true; do
 header
 echo "1) Update & Upgrade Server"
 echo "2) Create GRE"
 echo "3) Remove GRE"
 echo "4) List GRE"
 echo "5) Create VXLAN"
 echo "6) Remove VXLAN"
 echo "7) List VXLAN"
 echo "8) Enable BBR / BBR2 / Cubic"
 echo "9) Backup / Restore Tunnels"
 echo "10) Auto-Failover Check"
 echo "0) Exit"
 read -rp "Select: " opt

 case $opt in
 1) color blue "Updating Server..."; apt update && apt upgrade -y ;;
 2) create_gre ;;
 3) remove_gre ;;
 4) list_gre ;;
 5) create_vxlan ;;
 6) remove_vxlan ;;
 7) list_vxlan ;;
 8) enable_bbr ;;
 9) backup_restore ;;
 10) auto_failover ;;
 0) exit ;;
 *) color red "Invalid Option" ;;
 esac
 read -p "Press Enter..."
done
