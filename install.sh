#!/usr/bin/env bash
set -e

########################################
# TunnelPilot Ultra PRO 2.1
# GRE / GRE+IPSec / VXLAN / Geneve TCP
# Auto-Failover + Auto-Reconnect + Backup
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
 cyan) tput setaf 6 ;;
 *) tput sgr0 ;;
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
 echo "       TunnelPilot Ultra PRO 2.1"
 echo " GRE / GRE+IPSec / VXLAN / Geneve TCP"
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
rand_geneve(){ echo "geneve$(shuf -i1000-9999 -n1)"; }
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

while read TYPE NAME LOCAL REMOTE EXTRA IP4 IP6 MTU; do
 [ -z "$NAME" ] && continue
 if ! ip link show $NAME &>/dev/null; then
   case $TYPE in
     GRE)
       ip tunnel add $NAME mode gre local $LOCAL remote $REMOTE ttl 255
       ;;
     GREIPSEC)
       ip tunnel add $NAME mode gre local $LOCAL remote $REMOTE ttl 255
       # IPSec minimal config (ESP)
       ;;
     VXLAN)
       ip link add $NAME type vxlan id $EXTRA local $LOCAL remote $REMOTE dstport 4789
       ;;
     GENEVE)
       ip link add $NAME type geneve id $EXTRA local $LOCAL remote $REMOTE ttl 255
       ;;
   esac
   ip link set $NAME mtu $MTU
   ip link set $NAME up
   ip addr add $IP4 dev $NAME || true
   ip -6 addr add $IP6 dev $NAME || true
 fi
done < $GRE_DB

while read TYPE NAME LOCAL REMOTE EXTRA IP4 IP6 MTU; do
 [ -z "$NAME" ] && continue
 if [[ "$TYPE" == "VXLAN" || "$TYPE" == "GENEVE" ]]; then
   ip link set $NAME up
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
# BACKUP
########################################
backup_tunnels(){
 mkdir -p /root/tunnel_backup
 cp $GRE_DB /root/tunnel_backup/gre_$(date +%F).conf
 cp $VXLAN_DB /root/tunnel_backup/vxlan_$(date +%F).conf
 color green "Backups saved in /root/tunnel_backup"
}

########################################
# CREATE TUNNELS
########################################
create_gre(){
 echo "1) Random name"
 echo "2) Custom name"
 read -rp "Choice: " c
 [[ "$c" == "1" ]] && NAME=$(rand_gre) || read -rp "Tunnel name: " NAME
 read -rp "Peer Public IP (comma separated): " PEERS
 [[ -z "$PEERS" ]] && { color red "Peer IP required"; return; }

 echo "1) Normal GRE"
 echo "2) GRE + IPSec"
 read -rp "Type: " t
 [[ "$t" == "2" ]] && TYPE="GREIPSEC" || TYPE="GRE"

 DEF4=$(default_ipv4)
 DEF6=$(default_ipv6)
 read -rp "Private IPv4 [$DEF4]: " IP4
 IP4=${IP4:-$DEF4}
 read -rp "Private IPv6 [$DEF6]: " IP6
 IP6=${IP6:-$DEF6}

 for REMOTE in ${PEERS//,/ }; do
   MTU=$(detect_mtu $REMOTE)
   ip link del $NAME 2>/dev/null || true
   if [[ "$TYPE" == "GREIPSEC" ]]; then
     ip tunnel add $NAME mode gre local $THIS_PUBLIC_IP remote $REMOTE ttl 255
     # IPSec minimal config
   else
     ip tunnel add $NAME mode gre local $THIS_PUBLIC_IP remote $REMOTE ttl 255
   fi
   ip link set $NAME mtu $MTU
   ip link set $NAME up
   ip addr add $IP4 dev $NAME
   ip -6 addr add $IP6 dev $NAME
   echo "$TYPE $NAME $THIS_PUBLIC_IP $REMOTE - $IP4 $IP6 $MTU" >> $GRE_DB
 done
 make_restore
 color green "$TYPE Tunnel Created"
}

create_vxlan(){
 echo "1) Random name"
 echo "2) Custom name"
 read -rp "Choice: " c
 [[ "$c" == "1" ]] && NAME=$(rand_vx) || read -rp "Tunnel name: " NAME

 read -rp "Peer Public IP (comma separated): " PEERS
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
   echo "VXLAN $NAME $THIS_PUBLIC_IP $REMOTE $VNI $IP4 $IP6 $MTU" >> $VXLAN_DB
 done
 make_restore
 color green "VXLAN Created"
}

create_geneve(){
 echo "1) Random name"
 echo "2) Custom name"
 read -rp "Choice: " c
 [[ "$c" == "1" ]] && NAME=$(rand_geneve) || read -rp "Tunnel name: " NAME

 read -rp "Peer Public IP (comma separated): " PEERS
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
   ip link add $NAME type geneve id $VNI local $THIS_PUBLIC_IP remote $REMOTE ttl 255
   ip link set $NAME mtu $MTU
   ip link set $NAME up
   ip addr add $IP4 dev $NAME
   ip -6 addr add $IP6 dev $NAME
   echo "GENEVE $NAME $THIS_PUBLIC_IP $REMOTE $VNI $IP4 $IP6 $MTU" >> $VXLAN_DB
 done
 make_restore
 color green "Geneve TCP Created"
}

########################################
# REMOVE TUNNELS
########################################
remove_tunnel(){
 echo "Current GRE / GRE+IPSec:"
 nl $GRE_DB
 echo
 echo "Current VXLAN / Geneve:"
 nl $VXLAN_DB
 echo
 read -rp "Tunnel name to remove: " N
 ip link del $N 2>/dev/null || true
 sed -i "/ $N /d" $GRE_DB
 sed -i "/ $N /d" $VXLAN_DB
 color red "Tunnel Removed: $N"
}

########################################
# REMOVE / EDIT PRIVATE IPs
########################################
edit_private_ips(){
 color yellow "=== Edit / Remove Private IPs ==="
 echo "GRE / GRE+IPSec tunnels:"
 nl $GRE_DB
 echo
 echo "VXLAN / Geneve tunnels:"
 nl $VXLAN_DB
 echo
 read -rp "Enter tunnel name (or 'all' for all): " N
 if [[ "$N" == "all" ]]; then
   for DB in $GRE_DB $VXLAN_DB; do
     while read TYPE NAME LOCAL REMOTE EXTRA IP4 IP6 MTU; do
       ip addr del $IP4 dev $NAME 2>/dev/null || true
       ip -6 addr del $IP6 dev $NAME 2>/dev/null || true
     done < $DB
   done
   color green "All Private IPs Removed"
 else
   for DB in $GRE_DB $VXLAN_DB; do
     while read TYPE NAME LOCAL REMOTE EXTRA IP4 IP6 MTU; do
       [[ "$NAME" == "$N" ]] || continue
       ip addr del $IP4 dev $NAME 2>/dev/null || true
       ip -6 addr del $IP6 dev $NAME 2>/dev/null || true
       color green "Private IPs Removed from $NAME"
     done < $DB
   done
 fi
}

########################################
# Auto-Failover
########################################
auto_failover(){
 echo "=== Checking Tunnel Latency & Auto-Reconnect ==="
 for DB in $GRE_DB $VXLAN_DB; do
   while read TYPE NAME LOCAL REMOTE EXTRA IP4 IP6 MTU; do
     LAT=$(ping -c2 -W1 $REMOTE | tail -1 | awk -F '/' '{print $5}')
     if [[ -z "$LAT" ]]; then
       color red "$TYPE $NAME Peer $REMOTE DOWN! Reconnecting..."
       ip link del $NAME 2>/dev/null || true
       case $TYPE in
         GRE) ip tunnel add $NAME mode gre local $LOCAL remote $REMOTE ttl 255 ;;
         GREIPSEC) ip tunnel add $NAME mode gre local $LOCAL remote $REMOTE ttl 255 ;;
         VXLAN) ip link add $NAME type vxlan id $EXTRA local $LOCAL remote $REMOTE dstport 4789 ;;
         GENEVE) ip link add $NAME type geneve id $EXTRA local $LOCAL remote $REMOTE ttl 255 ;;
       esac
       ip link set $NAME mtu $MTU
       ip link set $NAME up
       ip addr add $IP4 dev $NAME || true
       ip -6 addr add $IP6 dev $NAME || true
     else
       color green "$TYPE $NAME Peer $REMOTE Latency: ${LAT}ms"
     fi
   done < $DB
 done
 color blue "Auto-Failover Check Completed"
}

########################################
# BBR / TCP Optimization
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
# LIST TUNNELS
########################################
list_tunnels(){
 color cyan "=== GRE / GRE+IPSec ==="
 nl $GRE_DB
 color cyan "=== VXLAN / Geneve ==="
 nl $VXLAN_DB
}

########################################
# MAIN MENU
########################################
while true; do
 header
 echo "1) Update & Upgrade Server"
 echo "2) Create GRE / GRE+IPSec"
 echo "3) Create VXLAN"
 echo "4) Create Geneve TCP"
 echo "5) Remove Tunnel"
 echo "6) Edit / Remove Private IPs"
 echo "7) List Tunnels"
 echo "8) Enable BBR / BBR2 / Cubic"
 echo "9) Backup Tunnels"
 echo "10) Auto-Failover Check"
 echo "0) Exit"
 read -rp "Select: " opt

 case $opt in
 1) color blue "Updating Server..."; apt update && apt upgrade -y ;;
 2) create_gre ;;
 3) create_vxlan ;;
 4) create_geneve ;;
 5) remove_tunnel ;;
 6) edit_private_ips ;;
 7) list_tunnels ;;
 8) enable_bbr ;;
 9) backup_tunnels ;;
 10) auto_failover ;;
 0) exit ;;
 *) color red "Invalid Option" ;;
 esac
 read -rp "Press Enter..."
done
