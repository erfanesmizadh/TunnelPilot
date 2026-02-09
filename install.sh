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
echo -e "Server IP: ${YELLOW}$SERVER_IP${NC}"
}

# ===============================
enable_forwarding(){
grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf || echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
grep -q "net.ipv6.conf.all.forwarding=1" /etc/sysctl.conf || echo "net.ipv6.conf.all.forwarding=1" >> /etc/sysctl.conf
sysctl -w net.ipv4.ip_forward=1 >/dev/null
sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null
sysctl -p >/dev/null
echo -e "${GREEN}✔ IP Forwarding Enabled${NC}"
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

read -rp "Private IPv4 [$IP4]: " IN4
read -rp "Private IPv6 [$IP6]: " IN6
IP4=${IN4:-$IP4}
IP6=${IN6:-$IP6}
}

clean_ip(){ echo "${1%%/*}"; }

test_ping(){
IP4C=$(clean_ip "$IP4")
IP6C=$(clean_ip "$IP6")
ping -c2 -W1 $IP4C && echo -e "${GREEN}✔ IPv4 OK${NC}" || echo -e "${RED}✖ IPv4 FAIL${NC}"
ping6 -c2 -W1 $IP6C && echo -e "${GREEN}✔ IPv6 OK${NC}" || echo -e "${RED}✖ IPv6 FAIL${NC}"
}

# ===============================
create_gre(){

echo "1) GRE Normal"
echo "2) GRE + IPSec"
read -rp "Select Mode: " MODE

read -rp "Tunnel name: " NAME
read -rp "Peer Public IP: " REMOTE

smart_private
MTU=1450

ip link del $NAME 2>/dev/null
ip tunnel add $NAME mode gre local $SERVER_IP remote $REMOTE ttl 255
ip link set $NAME mtu $MTU
ip addr add $IP4 dev $NAME
ip addr add $IP6 dev $NAME
ip link set $NAME up

if [ "$MODE" == "2" ]; then
  KEY1=$(openssl rand -hex 16)
  KEY2=$(openssl rand -hex 16)

  ip xfrm state add src $SERVER_IP dst $REMOTE proto esp spi 0x100 mode transport auth sha256 enc aes $KEY1
  ip xfrm state add src $REMOTE dst $SERVER_IP proto esp spi 0x200 mode transport auth sha256 enc aes $KEY2
  ip xfrm policy add src $SERVER_IP dst $REMOTE dir out tmpl proto esp mode transport
  ip xfrm policy add src $REMOTE dst $SERVER_IP dir in tmpl proto esp mode transport
fi

echo "$NAME $REMOTE $IP4 $IP6 $MTU $MODE" >> $GRE_DB

echo -e "${GREEN}✔ GRE Created${NC}"
[ "$MODE" == "2" ] && echo -e "${CYAN}✔ IPSec Enabled${NC}"
test_ping
}

# ===============================
create_vxlan(){

read -rp "Tunnel name: " NAME
read -rp "Peer Public IP: " REMOTE
read -rp "VNI: " VNI

smart_private
MTU=1450

ip link del $NAME 2>/dev/null
ip link add $NAME type vxlan id $VNI local $SERVER_IP remote $REMOTE dstport 4789
ip link set $NAME mtu $MTU
ip addr add $IP4 dev $NAME
ip addr add $IP6 dev $NAME
ip link set $NAME up

echo "$NAME $REMOTE $VNI $IP4 $IP6 $MTU" >> $VXLAN_DB
echo -e "${GREEN}✔ VXLAN Created${NC}"
test_ping
}

# ===============================
create_geneve(){

read -rp "Tunnel name: " NAME
read -rp "Peer Public IP: " REMOTE
read -rp "VNI: " VNI

smart_private
MTU=1450

ip link del $NAME 2>/dev/null
ip link add $NAME type geneve id $VNI remote $REMOTE dstport 6081
ip link set $NAME mtu $MTU
ip addr add $IP4 dev $NAME
ip addr add $IP6 dev $NAME
ip link set $NAME up

echo "$NAME $REMOTE $VNI $IP4 $IP6 $MTU" >> $GENEVE_DB
echo -e "${GREEN}✔ Geneve Created${NC}"
test_ping
}

# ===============================
restore_all(){

enable_forwarding

while read -r NAME REMOTE IP4 IP6 MTU MODE; do
  ip link del $NAME 2>/dev/null
  ip tunnel add $NAME mode gre local $SERVER_IP remote $REMOTE ttl 255
  ip link set $NAME mtu $MTU
  ip addr add $IP4 dev $NAME
  ip addr add $IP6 dev $NAME
  ip link set $NAME up
done < "$GRE_DB"

while read -r NAME REMOTE VNI IP4 IP6 MTU; do
  ip link del $NAME 2>/dev/null
  ip link add $NAME type vxlan id $VNI local $SERVER_IP remote $REMOTE dstport 4789
  ip link set $NAME mtu $MTU
  ip addr add $IP4 dev $NAME
  ip addr add $IP6 dev $NAME
  ip link set $NAME up
done < "$VXLAN_DB"

while read -r NAME REMOTE VNI IP4 IP6 MTU; do
  ip link del $NAME 2>/dev/null
  ip link add $NAME type geneve id $VNI remote $REMOTE dstport 6081
  ip link set $NAME mtu $MTU
  ip addr add $IP4 dev $NAME
  ip addr add $IP6 dev $NAME
  ip link set $NAME up
done < "$GENEVE_DB"

echo -e "${GREEN}✔ All tunnels restored${NC}"
}

# ===============================
remove_tunnel(){
ip -br link | nl
read -rp "Select interface: " N
NAME=$(ip -br link | awk '{print $1}' | sed -n "${N}p")
ip link del $NAME
sed -i "/^$NAME /d" $GRE_DB $VXLAN_DB $GENEVE_DB
echo -e "${GREEN}✔ $NAME Removed${NC}"
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
echo "2) 🌐 Create GRE / GRE+IPSec"
echo "3) 🛡 Create VXLAN"
echo "4) 🔗 Create Geneve"
echo "5) ❌ Remove Tunnel"
echo "6) ✏️ Edit Private IP (Manual)"
echo "7) 📄 Show Interfaces"
echo "8) 🚀 Enable BBR"
echo "9) 🔁 Enable IP Forwarding"
echo "10) 🔄 Restore All Tunnels"
echo "0) Exit"

read CH

case $CH in
1) apt update && apt upgrade -y ;;
2) create_gre ;;
3) create_vxlan ;;
4) create_geneve ;;
5) remove_tunnel ;;
6) echo "Use ip addr manually" ;;
7) ip -br link ;;
8) enable_bbr ;;
9) enable_forwarding ;;
10) restore_all ;;
0) exit ;;
esac

read -p "Press Enter..."
done
