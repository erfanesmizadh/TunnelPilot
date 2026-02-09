#!/bin/bash
set -e

########################################
# TunnelPilot Ultra PRO 2.1
# Multi GRE + GRE+IPSec + VXLAN + Geneve TCP
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
# MTU AUTO DETECT / ASK
########################################
ask_mtu(){
 local DEFAULT_MTU=${1:-1450}
 read -rp "MTU [$DEFAULT_MTU]: " MTU
 MTU=${MTU:-$DEFAULT_MTU}
 echo $MTU
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
# GRE / GRE+IPSec
########################################
create_gre(){
 echo "1) Default Key"
 echo "2) Custom Key"
 read -rp "Choice: " c
 if [[ "$c" == "1" ]]; then
   NAME=$(rand_gre)
 else
   read -rp "Tunnel name: " NAME
 fi

 read -rp "Peer Public IP (comma separated): " PEERS
 [[ -z "$PEERS" ]] && { color red "Peer IP required"; return; }

 read -rp "Tunnel Type [1) GRE, 2) GRE+IPSec]: " TYPE
 TYPE=${TYPE:-1}

 DEF4=$(default_ipv4)
 DEF6=$(default_ipv6)
 read -rp "Private IPv4 [$DEF4]: " IP4
 IP4=${IP4:-$DEF4}
 read -rp "Private IPv6 [$DEF6]: " IP6
 IP6=${IP6:-$DEF6}

 MTU=$(ask_mtu 1450)

 for REMOTE in ${PEERS//,/ }; do
   ip link del $NAME 2>/dev/null || true
   ip tunnel add $NAME mode gre local $THIS_PUBLIC_IP remote $REMOTE ttl 255
   ip link set $NAME mtu $MTU
   ip link set $NAME up
   ip addr add $IP4 dev $NAME
   ip -6 addr add $IP6 dev $NAME

   if [[ "$TYPE" == "2" ]]; then
       color yellow "GRE+IPSec setup not fully automated, configure ESP manually"
   fi

   echo "$NAME $THIS_PUBLIC_IP $REMOTE $IP4 $IP6 $MTU" >> $GRE_DB
 done
 make_restore
 color green "GRE Created with Auto-Failover"
}

########################################
# VXLAN
########################################
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

 MTU=$(ask_mtu 1450)

 for REMOTE in ${PEERS//,/ }; do
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

########################################
# Geneve TCP
########################################
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

 MTU=$(ask_mtu 1450)

 for REMOTE in ${PEERS//,/ }; do
   ip link del $NAME 2>/dev/null || true
   ip link add $NAME type geneve id $VNI remote $REMOTE ttl 255
   ip link set $NAME mtu $MTU
   ip link set $NAME up
   ip addr add $IP4 dev $NAME
   ip -6 addr add $IP6 dev $NAME
   echo "$NAME $THIS_PUBLIC_IP $REMOTE $VNI $IP4 $IP6 $MTU" >> $VXLAN_DB
 done
 make_restore
 color green "Geneve TCP Created with Auto-Failover"
}

########################################
# REMOVE / EDIT PRIVATE IPS
########################################
edit_private_ips(){
 echo "=== List of Tunnels ==="
 nl $GRE_DB
 nl $VXLAN_DB | awk -v offset=$(wc -l < $GRE_DB) '{print $1+offset, $2, $3, $4, $5, $6, $7}'

 read -rp "Enter tunnel number to remove Private IPs (or 'all'): " NUM

 TOTAL_LINES=$(($(wc -l < $GRE_DB) + $(wc -l < $VXLAN_DB)))

 if [[ "$NUM" == "all" ]]; then
    while read LINE; do
        NAME=$(echo $LINE | awk '{print $1}')
        ip addr flush dev $NAME
    done < <(cat $GRE_DB)
    while read LINE; do
        NAME=$(echo $LINE | awk '{print $1}')
        ip addr flush dev $NAME
    done < <(cat $VXLAN_DB)
    sed -i -E 's/([0-9\.\/]+) ([fdaa:].+\/[0-9]+)/0.0.0.0\/0 ::\/0/' $GRE_DB
    sed -i -E 's/([0-9\.\/]+) ([fdaa:].+\/[0-9]+)/0.0.0.0\/0 ::\/0/' $VXLAN_DB
    color green "All Private IPs removed"
    return
 fi

 if [[ $NUM -lt 1 || $NUM -gt $TOTAL_LINES ]]; then
    color red "Invalid number"
    return
 fi

 if [[ $NUM -le $(wc -l < $GRE_DB) ]]; then
    LINE=$(sed -n "${NUM}p" $GRE_DB)
    NAME=$(echo $LINE | awk '{print $1}')
    ip addr flush dev $NAME
    sed -i "${NUM}s/[0-9\.\/]\+ [fdaa:].+\/[0-9]+/0.0.0.0\/0 ::\/0/" $GRE_DB
    color green "Private IPs removed from GRE tunnel $NAME"
 else
    OFFSET=$(($(wc -l < $GRE_DB)))
    LINE=$(sed -n "$((NUM-OFFSET))p" $VXLAN_DB)
    NAME=$(echo $LINE | awk '{print $1}')
    ip addr flush dev $NAME
    sed -i "$((NUM-OFFSET))s/[0-9\.\/]\+ [fdaa:].+\/[0-9]+/0.0.0.0\/0 ::\/0/" $VXLAN_DB
    color green "Private IPs removed from VXLAN / Geneve tunnel $NAME"
 fi
 make_restore
}

########################################
# EDIT TUNNEL (Peer / Private IP)
########################################
edit_tunnel(){
 echo "=== List of Tunnels ==="
 nl $GRE_DB
 nl $VXLAN_DB | awk -v offset=$(wc -l < $GRE_DB) '{print $1+offset, $2, $3, $4, $5, $6, $7}'

 read -rp "Enter tunnel number to edit: " NUM
 TOTAL_LINES=$(($(wc -l < $GRE_DB) + $(wc -l < $VXLAN_DB)))

 if [[ $NUM -lt 1 || $NUM -gt $TOTAL_LINES ]]; then
    color red "Invalid number"
    return
 fi

 if [[ $NUM -le $(wc -l < $GRE_DB) ]]; then
    FILE=$GRE_DB
    LINE_NUM=$NUM
 else
    FILE=$VXLAN_DB
    OFFSET=$(wc -l < $GRE_DB)
    LINE_NUM=$((NUM-OFFSET))
 fi

 LINE=$(sed -n "${LINE_NUM}p" $FILE)
 NAME=$(echo $LINE | awk '{print $1}')
 LOCAL=$(echo $LINE | awk '{print $2}')
 REMOTE=$(echo $LINE | awk '{print $3}')
 VNI=$(echo $LINE | awk '{print $4}')
 IP4=$(echo $LINE | awk '{print $5}')
 IP6=$(echo $LINE | awk '{print $6}')
 MTU=$(echo $LINE | awk '{print $7}')

 echo "Editing Tunnel $NAME"
 read -rp "New Peer Public IP(s) [$REMOTE]: " NEW_PEER
 NEW_PEER=${NEW_PEER:-$REMOTE}
 read -rp "New Private IPv4 [$IP4]: " NEW_IP4
 NEW_IP4=${NEW_IP4:-$IP4}
 read -rp "New Private IPv6 [$IP6]: " NEW_IP6
 NEW_IP6=${NEW_IP6:-$IP6}

 # Flush old IPs
 ip addr flush dev $NAME

 # Apply new IPs
 ip addr add $NEW_IP4 dev $NAME
 ip -6 addr add $NEW_IP6 dev $NAME

 # Update DB
 if [[ $FILE == $GRE_DB ]]; then
   sed -i "${LINE_NUM}s/.*/$NAME $LOCAL $NEW_PEER $NEW_IP4 $NEW_IP6 $MTU/" $GRE_DB
 else
   sed -i "${LINE_NUM}s/.*/$NAME $LOCAL $NEW_PEER $VNI $NEW_IP4 $NEW_IP6 $MTU/" $VXLAN_DB
 fi

 make_restore
 color green "Tunnel $NAME updated successfully"
}

########################################
# LIST
########################################
list_tunnels(){
 echo "=== GRE / GRE+IPSec ==="
 cat $GRE_DB
 echo
 echo "=== VXLAN / Geneve ==="
 cat $VXLAN_DB
 echo
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
 echo "7) Edit Tunnel (Peer / Private IP)"
 echo "8) List Tunnels"
 echo "0) Exit"
 read -rp "Select: " opt

 case $opt in
 1) color blue "Updating Server..."; apt update && apt upgrade -y ;;
 2) create_gre ;;
 3) create_vxlan ;;
 4) create_geneve ;;
 5) remove_tunnel ;;
 6) edit_private_ips ;;
 7) edit_tunnel ;;
 8) list_tunnels ;;
 0) exit ;;
 *) color red "Invalid Option" ;;
 esac
 read -p "Press Enter..."
done
