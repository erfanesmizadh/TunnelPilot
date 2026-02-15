#!/usr/bin/env bash

# ===============================
# 🚀 TunnelPilot Ultra PRO MAX - Ultimate Edition
# ===============================

# -------------------------------
# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

# -------------------------------
# Root check
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}Please run as root${NC}"
    exit 1
fi

# -------------------------------
# Dependencies
for cmd in ip ping ping6 curl; do
    if ! command -v $cmd &>/dev/null; then
        echo -e "${YELLOW}Installing $cmd...${NC}"
        apt update && apt install -y ${cmd/iputils-ping/iputils-ping} ${cmd/curl/curl} ${cmd/ip/iproute2}
    fi
done

# -------------------------------
# Directories & DB files
DB="/etc/tunnelpilot"
GRE_DB="$DB/gre.conf"
VXLAN_DB="$DB/vxlan.conf"
GENEVE_DB="$DB/geneve.conf"
IPIP_DB="$DB/ipip.conf"
L2TP_DB="$DB/l2tp.conf"
GRETAB_DB="$DB/gretab.conf"
SIT_DB="$DB/sit.conf"

mkdir -p "$DB"
touch "$GRE_DB" "$VXLAN_DB" "$GENEVE_DB" "$IPIP_DB" "$L2TP_DB" "$GRETAB_DB" "$SIT_DB"

# -------------------------------
SERVER_IP=$(curl -s ipv4.icanhazip.com || echo "0.0.0.0")

# -------------------------------
header(){
clear
echo -e "${MAGENTA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}🚀 TunnelPilot Ultra PRO MAX${NC}"
echo -e "Ultimate Tunnel Manager - GRE/VXLAN/Geneve/IPIP/L2TP/GRETAB/SIT"
echo -e "${MAGENTA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo "Server Public IP: $SERVER_IP"
}

# -------------------------------
smart_private(){
echo "Server Role:"
echo "1) IRAN 🇮🇷"
echo "2) OUTSIDE 🌍"
read -rp "Choice: " ROLE

SUB=$((RANDOM%200+10))

if [ "$ROLE" == "1" ]; then
    IP4="172.10.$SUB.1/30"
    IP6="fd$(printf '%x' $SUB)::1/64"
else
    IP4="172.10.$SUB.2/30"
    IP6="fd$(printf '%x' $SUB)::2/64"
fi

echo "Private IPv4 [$IP4]: "
read IN4
IP4=${IN4:-$IP4}

echo "Private IPv6 [$IP6]: "
read IN6
IP6=${IN6:-$IP6}
}

clean_ip(){ echo "${1%%/*}"; }

# -------------------------------
test_ping(){
IP4C=$(clean_ip "$IP4")
IP6C=$(clean_ip "$IP6")

echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo "Tunnel Connectivity Test"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

ping -c2 -W1 $IP4C &>/dev/null && echo -e "${GREEN}✔ IPv4 OK${NC}" || echo -e "${RED}✖ IPv4 FAIL${NC}"
ping6 -c2 -W1 $IP6C &>/dev/null && echo -e "${GREEN}✔ IPv6 OK${NC}" || echo -e "${RED}✖ IPv6 FAIL${NC}"
}

# -------------------------------
enable_forwarding(){
grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.conf || echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
grep -q "^net.ipv6.conf.all.forwarding=1" /etc/sysctl.conf || echo "net.ipv6.conf.all.forwarding=1" >> /etc/sysctl.conf
sysctl -p &>/dev/null
echo -e "${GREEN}✔ IP Forwarding Enabled${NC}"
}

# -------------------------------
# Tunnel Functions
# -------------------------------
create_generic(){
TYPE=$1
DB_FILE=$2
EXTRA_PARAMS=$3

read -rp "Tunnel name: " NAME
read -rp "Peer Public IP: " REMOTE
read -rp "MTU [1450]: " MTU
MTU=${MTU:-1450}

smart_private

ip addr flush dev $NAME 2>/dev/null
ip link del $NAME 2>/dev/null || true

case $TYPE in
    gre) ip tunnel add $NAME mode gre local $SERVER_IP remote $REMOTE ttl 255 ;;
    vxlan) ip link add $NAME type vxlan id $EXTRA_PARAMS local $SERVER_IP remote $REMOTE dstport 4789 ;;
    geneve) ip link add $NAME type geneve id $EXTRA_PARAMS local $SERVER_IP remote $REMOTE dstport 6081 ;;
    ipip) ip tunnel add $NAME mode ipip local $SERVER_IP remote $REMOTE ;;
    l2tp) ip link add $NAME type l2tpeth local $SERVER_IP remote $REMOTE ;;
    gretap) ip tunnel add $NAME mode gretap local $SERVER_IP remote $REMOTE ttl 255 ;;
    sit) ip tunnel add $NAME mode sit local $SERVER_IP remote $REMOTE ttl 255 ;;
esac

ip link set $NAME up
ip addr add $IP4 dev $NAME
ip addr add $IP6 dev $NAME
ip link set $NAME mtu $MTU

# Save to config
case $TYPE in
    gre|ipip|l2tp|gretap|sit) echo "$NAME $REMOTE $IP4 $IP6 $MTU" >> "$DB_FILE" ;;
    vxlan|geneve) echo "$NAME $REMOTE $IP4 $IP6 $EXTRA_PARAMS $MTU" >> "$DB_FILE" ;;
esac

echo -e "${GREEN}$TYPE Tunnel Created${NC}"
test_ping
}

# -------------------------------
restore_generic(){
TYPE=$1
DB_FILE=$2

while read -r LINE; do
    [ -z "$LINE" ] && continue
    NAME=$(echo $LINE | awk '{print $1}')
    REMOTE=$(echo $LINE | awk '{print $2}')
    IP4=$(echo $LINE | awk '{print $3}')
    IP6=$(echo $LINE | awk '{print $4}')
    EXTRA=$(echo $LINE | awk '{print $5}')
    MTU=$(echo $LINE | awk '{print $6}')

    ip addr flush dev $NAME 2>/dev/null
    ip link del $NAME 2>/dev/null || true

    case $TYPE in
        gre) ip tunnel add $NAME mode gre local $SERVER_IP remote $REMOTE ttl 255 ;;
        vxlan) ip link add $NAME type vxlan id $EXTRA local $SERVER_IP remote $REMOTE dstport 4789 ;;
        geneve) ip link add $NAME type geneve id $EXTRA local $SERVER_IP remote $REMOTE dstport 6081 ;;
        ipip) ip tunnel add $NAME mode ipip local $SERVER_IP remote $REMOTE ;;
        l2tp) ip link add $NAME type l2tpeth local $SERVER_IP remote $REMOTE ;;
        gretap) ip tunnel add $NAME mode gretap local $SERVER_IP remote $REMOTE ttl 255 ;;
        sit) ip tunnel add $NAME mode sit local $SERVER_IP remote $REMOTE ttl 255 ;;
    esac

    ip link set $NAME up
    ip addr add $IP4 dev $NAME
    ip addr add $IP6 dev $NAME
    ip link set $NAME mtu $MTU
done < "$DB_FILE"
}

# -------------------------------
remove_tunnel(){
echo "Select interface to delete:"
ip -br link | nl
read -rp "Number: " NUM

NAME=$(ip -br link | awk '{print $1}' | sed -n "${NUM}p")

if ip link show $NAME &>/dev/null; then
    ip addr flush dev $NAME
    ip link del $NAME
    for FILE in "$GRE_DB" "$VXLAN_DB" "$GENEVE_DB" "$IPIP_DB" "$L2TP_DB" "$GRETAB_DB" "$SIT_DB"; do
        sed -i "/^$NAME /d" "$FILE"
    done
    echo -e "${GREEN}Deleted $NAME and removed private IPs${NC}"
else
    echo -e "${RED}✖ Interface not found${NC}"
fi
}

# -------------------------------
edit_ip(){
read -rp "Interface: " NAME
ip addr flush dev $NAME
read -rp "New IPv4: " N4
read -rp "New IPv6: " N6
ip addr add $N4 dev $NAME
ip addr add $N6 dev $NAME
echo -e "${GREEN}Updated IPs${NC}"
}

# -------------------------------
enable_bbr(){
echo "1) BBR"
echo "2) BBR2"
echo "3) Cubic"
read -rp "Choice: " OPT
grep -q "^net.core.default_qdisc=fq" /etc/sysctl.conf || echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
case $OPT in
1) sysctl -w net.ipv4.tcp_congestion_control=bbr ;;
2) sysctl -w net.ipv4.tcp_congestion_control=bbr2 ;;
3) sysctl -w net.ipv4.tcp_congestion_control=cubic ;;
esac
sysctl -p
echo -e "${GREEN}✔ TCP Congestion Control updated${NC}"
}

# -------------------------------
ping_all_private(){
echo -e "${YELLOW}Pinging all private IPs...${NC}"
for FILE in "$GRE_DB" "$VXLAN_DB" "$GENEVE_DB" "$IPIP_DB" "$L2TP_DB" "$GRETAB_DB" "$SIT_DB"; do
    while read -r LINE; do
        [ -z "$LINE" ] && continue
        NAME=$(echo $LINE | awk '{print $1}')
        IP4=$(echo $LINE | awk '{print $3}')
        IP6=$(echo $LINE | awk '{print $4}')
        echo -n "$NAME: "
        ping -c1 -W1 $(clean_ip $IP4) &>/dev/null && echo -n "IPv4 ✔ " || echo -n "IPv4 ✖ "
        ping6 -c1 -W1 $(clean_ip $IP6) &>/dev/null && echo "IPv6 ✔" || echo "IPv6 ✖"
    done < "$FILE"
done
}

# -------------------------------
while true; do
header

echo "1) ⚡ Update Server"
echo "2) 🌐 Create GRE"
echo "3) 🛡 Create VXLAN"
echo "4) 🔗 Create Geneve"
echo "5) 🟢 Create IPIP"
echo "6) 🔵 Create L2TP"
echo "7) 🟣 Create GRETAB"
echo "8) 🟠 Create SIT"
echo "9) ❌ Remove Tunnel"
echo "10) ✏️ Edit Private IP"
echo "11) 📄 Show Interfaces"
echo "12) 🚀 Enable BBR"
echo "13) 🔁 Enable IP Forwarding"
echo "14) 🔄 Restore All Tunnels"
echo "15) 📊 Ping All Private IPs"
echo "0) Exit"

read -rp "Choice: " CH

case $CH in
1) apt update && apt upgrade -y ;;
2) create_generic gre "$GRE_DB" ;;
3) read -rp "VNI: " VNI; create_generic vxlan "$VXLAN_DB" "$VNI" ;;
4) read -rp "VNI: " VNI; create_generic geneve "$GENEVE_DB" "$VNI" ;;
5) create_generic ipip "$IPIP_DB" ;;
6) create_generic l2tp "$L2TP_DB" ;;
7) create_generic gretap "$GRETAB_DB" ;;
8) create_generic sit "$SIT_DB" ;;
9) remove_tunnel ;;
10) edit_ip ;;
11) ip -br link ;;
12) enable_bbr ;;
13) enable_forwarding ;;
14) enable_forwarding; restore_generic gre "$GRE_DB"; restore_generic vxlan "$VXLAN_DB"; restore_generic geneve "$GENEVE_DB"; restore_generic ipip "$IPIP_DB"; restore_generic l2tp "$L2TP_DB"; restore_generic gretap "$GRETAB_DB"; restore_generic sit "$SIT_DB"; echo -e "${GREEN}All tunnels restored${NC}" ;;
15) ping_all_private ;;
0) exit ;;
*) echo -e "${RED}Invalid option${NC}" ;;
esac

read -p "Press Enter..."
done
