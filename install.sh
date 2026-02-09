#!/usr/bin/env bash

# ===============================
# 🚀 TunnelPilot Ultra PRO MAX
# ===============================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

SERVER_IP=$(curl -s ipv4.icanhazip.com)

DB="/etc/tunnelpilot"
GRE_DB="$DB/gre.conf"
VXLAN_DB="$DB/vxlan.conf"
GENEVE_DB="$DB/geneve.conf"

mkdir -p $DB
touch $GRE_DB $VXLAN_DB $GENEVE_DB

# ===============================
header(){
clear
echo -e "${MAGENTA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}🚀 TunnelPilot Ultra PRO MAX${NC}"
echo -e "GRE / GRE+IPSec / VXLAN / Geneve"
echo -e "${MAGENTA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo "Server IP: $SERVER_IP"
}

# ===============================
smart_private(){

echo "Server Role:"
echo "1) IRAN 🇮🇷"
echo "2) OUTSIDE 🌍"
read ROLE

SUB=$((RANDOM%200+10))

if [ "$ROLE" == "1" ]; then
IP4="172.10.$SUB.1/30"
IP6="fd$(printf '%x' $SUB)::1/64"
else
IP4="172.10.$SUB.2/30"
IP6="fd$(printf '%x' $SUB)::2/64"
fi

echo "Private IPv4 [$IP4]"
read IN4
IP4=${IN4:-$IP4}

echo "Private IPv6 [$IP6]"
read IN6
IP6=${IN6:-$IP6}

}

clean_ip(){ echo "${1%%/*}"; }

test_ping(){

IP4C=$(clean_ip "$IP4")
IP6C=$(clean_ip "$IP6")

echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo " Tunnel Connectivity"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

ping -c2 -W1 $IP4C && echo -e "${GREEN}✔ IPv4 OK${NC}" || echo -e "${RED}✖ IPv4 FAIL${NC}"
ping6 -c2 -W1 $IP6C && echo -e "${GREEN}✔ IPv6 OK${NC}" || echo -e "${RED}✖ IPv6 FAIL${NC}"
}

# ===============================
create_gre(){

read -rp "Tunnel name: " NAME
read -rp "Peer Public IP: " REMOTE

smart_private

read -rp "MTU [1450]: " MTU
MTU=${MTU:-1450}

ip link del $NAME 2>/dev/null || true

ip tunnel add $NAME mode gre local $SERVER_IP remote $REMOTE ttl 255

ip link set $NAME mtu $MTU
ip addr add $IP4 dev $NAME
ip addr add $IP6 dev $NAME
ip link set $NAME up

echo "$NAME $REMOTE $IP4 $IP6" >> $GRE_DB

echo -e "${GREEN}GRE Created${NC}"

test_ping
}

# ===============================
create_vxlan(){

read -rp "Tunnel name: " NAME
read -rp "Peer Public IP: " REMOTE
read -rp "VNI: " VNI

smart_private

read -rp "MTU [1450]: " MTU
MTU=${MTU:-1450}

ip link del $NAME 2>/dev/null || true

ip link add $NAME type vxlan id $VNI local $SERVER_IP remote $REMOTE dstport 4789

ip link set $NAME mtu $MTU
ip addr add $IP4 dev $NAME
ip addr add $IP6 dev $NAME
ip link set $NAME up

echo "$NAME $REMOTE $IP4 $IP6" >> $VXLAN_DB

echo -e "${GREEN}VXLAN Created${NC}"

test_ping
}

# ===============================
create_geneve(){

read -rp "Tunnel name: " NAME
read -rp "Peer Public IP: " REMOTE
read -rp "VNI: " VNI

smart_private

read -rp "MTU [1450]: " MTU
MTU=${MTU:-1450}

ip link del $NAME 2>/dev/null || true

ip link add $NAME type geneve id $VNI remote $REMOTE dstport 6081

ip link set $NAME mtu $MTU
ip addr add $IP4 dev $NAME
ip addr add $IP6 dev $NAME
ip link set $NAME up

echo "$NAME $REMOTE $IP4 $IP6" >> $GENEVE_DB

echo -e "${GREEN}Geneve Created${NC}"

test_ping
}

# ===============================
remove_tunnel(){

echo "Select interface:"
ip -br link | nl

read NUM

NAME=$(ip -br link | awk '{print $1}' | sed -n "${NUM}p")

ip link del $NAME

sed -i "/^$NAME /d" $GRE_DB
sed -i "/^$NAME /d" $VXLAN_DB
sed -i "/^$NAME /d" $GENEVE_DB

echo -e "${GREEN}Deleted $NAME${NC}"
}

# ===============================
edit_ip(){

read -rp "Interface: " NAME

ip addr flush dev $NAME

read -rp "New IPv4: " N4
read -rp "New IPv6: " N6

ip addr add $N4 dev $NAME
ip addr add $N6 dev $NAME

echo -e "${GREEN}Updated${NC}"
}

# ===============================
enable_bbr(){

echo "1) BBR"
echo "2) BBR2"
echo "3) Cubic"

read OPT

echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf

case $OPT in
1) sysctl -w net.ipv4.tcp_congestion_control=bbr ;;
2) sysctl -w net.ipv4.tcp_congestion_control=bbr2 ;;
3) sysctl -w net.ipv4.tcp_congestion_control=cubic ;;
esac

sysctl -p
}

# ===============================
while true; do

header

echo "1) ⚡ Update Server"
echo "2) 🌐 Create GRE"
echo "3) 🛡 Create VXLAN"
echo "4) 🔗 Create Geneve"
echo "5) ❌ Remove Tunnel"
echo "6) ✏️ Edit Private IP"
echo "7) 📄 Show Interfaces"
echo "8) 🚀 Enable BBR"
echo "0) Exit"

read CH

case $CH in
1) apt update && apt upgrade -y ;;
2) create_gre ;;
3) create_vxlan ;;
4) create_geneve ;;
5) remove_tunnel ;;
6) edit_ip ;;
7) ip -br link ;;
8) enable_bbr ;;
0) exit ;;
esac

read -p "Press Enter..."

done
