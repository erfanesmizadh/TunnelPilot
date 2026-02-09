#!/usr/bin/env bash
# TunnelPilot Ultra PRO 3.5 — GOD MODE

RED='\033[0;31m'
GREEN='\033[1;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[1;36m'
WHITE='\033[1;37m'
NC='\033[0m'

SERVER_IP=$(curl -s ipv4.icanhazip.com)

CONF_DIR="/etc/tunnelpilot"
GRE_DB="$CONF_DIR/gre.conf"
VXLAN_DB="$CONF_DIR/vxlan.conf"
GENEVE_DB="$CONF_DIR/geneve.conf"

mkdir -p $CONF_DIR
touch $GRE_DB $VXLAN_DB $GENEVE_DB

default_mtu(){
case $1 in
gre) echo 1476 ;;
vxlan) echo 1450 ;;
geneve) echo 1450 ;;
*) echo 1450 ;;
esac
}

rand_name(){ echo "$1$(shuf -i1000-9999 -n1)"; }

peer_ipv4(){ echo $1 | sed 's/1\/30/2/;s/2\/30/1/'; }
peer_ipv6(){ echo $1 | sed 's/::1/::2/;s/::2/::1/'; }

peer_test(){

IP4=$1
IP6=$2

PEER4=$(peer_ipv4 $IP4)
PEER6=$(peer_ipv6 $IP6)

echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${WHITE} Tunnel Connectivity ${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

echo -e "${GREEN}Local IPv4:${NC} $IP4"
echo -e "${GREEN}Peer  IPv4:${NC} $PEER4"

echo -e "${GREEN}Local IPv6:${NC} $IP6"
echo -e "${GREEN}Peer  IPv6:${NC} $PEER6"

ping -c1 -W1 $PEER4 >/dev/null && echo -e "${GREEN}✔ IPv4 OK${NC}" || echo -e "${RED}✖ IPv4 FAIL${NC}"
ping6 -c1 -W1 $PEER6 >/dev/null && echo -e "${GREEN}✔ IPv6 OK${NC}" || echo -e "${RED}✖ IPv6 FAIL${NC}"

echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

smart_best_peer(){

PEERS=$1
BEST=9999
BESTIP=""

for REMOTE in ${PEERS//,/ }; do

LAT=$(ping -c1 -W1 $REMOTE | awk -F'/' 'END{print $5}')
[ -z "$LAT" ] && continue

LAT_INT=${LAT%.*}

if (( LAT_INT < BEST )); then
BEST=$LAT_INT
BESTIP=$REMOTE
fi

done

echo $BESTIP
}

enable_stealth(){

echo -e "${CYAN}Enabling Tunnel Stealth Mode...${NC}"

sysctl -w net.core.default_qdisc=fq
sysctl -w net.ipv4.tcp_congestion_control=bbr

sysctl -w net.ipv4.tcp_timestamps=1
sysctl -w net.ipv4.tcp_low_latency=1
sysctl -w net.ipv4.tcp_no_metrics_save=1
sysctl -w net.ipv4.tcp_mtu_probing=1

iptables -t mangle -A POSTROUTING -j TTL --ttl-set 64

echo -e "${GREEN}✔ Stealth Mode Activated${NC}"
}

enable_jitter(){

echo -e "${CYAN}Enabling Gaming Jitter Stabilizer...${NC}"

tc qdisc replace dev eth0 root fq_codel
sysctl -w net.ipv4.tcp_fastopen=3
sysctl -w net.ipv4.tcp_slow_start_after_idle=0

echo -e "${GREEN}✔ Jitter Stabilizer Active${NC}"
}

header(){

clear
echo -e "${BLUE}====================================="
echo "   TunnelPilot Ultra PRO 3.5 GOD"
echo "=====================================${NC}"
echo "Server IP: $SERVER_IP"

}

menu(){

header

echo "1) Update & Upgrade Server"
echo "2) Create GRE / GRE+IPSec"
echo "3) Create VXLAN"
echo "4) Create Geneve TCP"
echo "5) Remove Tunnel"
echo "6) Edit / Remove Private IP"
echo "7) List Tunnels"
echo "8) Enable BBR / BBR2 / Cubic"
echo "9) Backup / Restore Tunnels"
echo "10) Auto-Failover Check"
echo "11) 🔥 Enable Tunnel Stealth Mode"
echo "12) 🎮 Enable Jitter Stabilizer"
echo "0) Exit"

read -rp "Select: " CHOICE

}

create_gre(){

read -rp "Tunnel name: " NAME
NAME=${NAME:-$(rand_name gre)}

read -rp "Peer Public IP (comma separated): " PEERS
read -rp "Private IPv4: " IP4
read -rp "Private IPv6: " IP6

read -rp "MTU [auto]: " MTU
MTU=${MTU:-$(default_mtu gre)}

BEST=$(smart_best_peer "$PEERS")

ip tunnel add $NAME mode gre local $SERVER_IP remote $BEST ttl 255 2>/dev/null

ip link set $NAME mtu $MTU
ip addr add $IP4 dev $NAME 2>/dev/null
ip addr add $IP6 dev $NAME 2>/dev/null
ip link set $NAME up

echo "$NAME $SERVER_IP $PEERS $IP4 $IP6 $MTU" >> $GRE_DB

echo -e "${GREEN}GRE Created → Active Peer: $BEST${NC}"

peer_test $IP4 $IP6
}

create_vxlan(){

read -rp "Tunnel name: " NAME
NAME=${NAME:-$(rand_name vx)}

read -rp "Peer Public IP (comma separated): " PEERS
read -rp "VNI (Enter=random): " VNI
VNI=${VNI:-$((RANDOM%5000+100))}

read -rp "Private IPv4: " IP4
read -rp "Private IPv6: " IP6

read -rp "MTU [auto]: " MTU
MTU=${MTU:-$(default_mtu vxlan)}

BEST=$(smart_best_peer "$PEERS")

ip link add $NAME type vxlan id $VNI local $SERVER_IP remote $BEST dstport 4789

ip link set $NAME mtu $MTU
ip addr add $IP4 dev $NAME 2>/dev/null
ip addr add $IP6 dev $NAME 2>/dev/null
ip link set $NAME up

echo "$NAME $SERVER_IP $PEERS $VNI $IP4 $IP6 $MTU" >> $VXLAN_DB

echo -e "${GREEN}VXLAN Created → Active Peer: $BEST${NC}"

peer_test $IP4 $IP6
}

create_geneve(){

read -rp "Tunnel name: " NAME
NAME=${NAME:-$(rand_name geneve)}

read -rp "Peer Public IP (comma separated): " PEERS
read -rp "VNI (Enter=random): " VNI
VNI=${VNI:-$((RANDOM%5000+100))}

read -rp "Private IPv4: " IP4
read -rp "Private IPv6: " IP6

read -rp "MTU [auto]: " MTU
MTU=${MTU:-$(default_mtu geneve)}

BEST=$(smart_best_peer "$PEERS")

ip link add $NAME type geneve id $VNI remote $BEST dstport 6081

ip link set $NAME mtu $MTU
ip addr add $IP4 dev $NAME 2>/dev/null
ip addr add $IP6 dev $NAME 2>/dev/null
ip link set $NAME up

echo "$NAME $SERVER_IP $PEERS $VNI $IP4 $IP6 $MTU" >> $GENEVE_DB

echo -e "${GREEN}Geneve Created → Active Peer: $BEST${NC}"

peer_test $IP4 $IP6
}

auto_failover(){

echo -e "${YELLOW}Smart Auto Failover Running...${NC}"

for f in $GRE_DB $VXLAN_DB $GENEVE_DB; do

while read LINE; do

[ -z "$LINE" ] && continue

NAME=$(echo $LINE | awk '{print $1}')
PEERS=$(echo $LINE | awk '{print $3}')

BEST=$(smart_best_peer "$PEERS")

echo -e "${CYAN}$NAME Best Peer → $BEST${NC}"

ip tunnel change $NAME remote $BEST 2>/dev/null

done < $f

done
}

enable_bbr(){

echo "1) BBR"
echo "2) BBR2"
echo "3) Cubic"

read -rp "Select: " OPT

echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf

case $OPT in
1) sysctl -w net.ipv4.tcp_congestion_control=bbr ;;
2) sysctl -w net.ipv4.tcp_congestion_control=bbr2 ;;
3) sysctl -w net.ipv4.tcp_congestion_control=cubic ;;
esac

sysctl -p

}

while true; do

menu

case $CHOICE in

1) apt update && apt upgrade -y ;;
2) create_gre ;;
3) create_vxlan ;;
4) create_geneve ;;
8) enable_bbr ;;
10) auto_failover ;;
11) enable_stealth ;;
12) enable_jitter ;;
0) exit ;;

esac

read -p "Press Enter..."

done
