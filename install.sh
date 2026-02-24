#!/usr/bin/env bash

# ===============================
# 🚀 AVASH NET - TunnelPilot Ultra PRO MAX
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
        if [[ -x "$(command -v apt)" ]]; then
            apt update && apt install -y ${cmd/iputils-ping/iputils-ping} ${cmd/curl/curl} ${cmd/ip/iproute2}
        elif [[ -x "$(command -v apt-get)" ]]; then
            apt-get update && apt-get install -y ${cmd/iputils-ping/iputils-ping} ${cmd/curl/curl} ${cmd/ip/iproute2}
        fi
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
GRETAB_DB="$DB/gretap.conf"
SIT_DB="$DB/sit.conf"

mkdir -p "$DB"
touch "$GRE_DB" "$VXLAN_DB" "$GENEVE_DB" "$IPIP_DB" "$L2TP_DB" "$GRETAB_DB" "$SIT_DB"

# -------------------------------
SERVER_IP=$(curl -s ipv4.icanhazip.com || echo "0.0.0.0")

# -------------------------------
header(){
clear
echo -e "${MAGENTA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN} █████╗ ██╗   ██╗ ████████╗ ███╗   ██╗ ██████╗ ${NC}"
echo -e "${CYAN}██╔══██╗██║   ██║ ╚══██╔══╝ ████╗  ██║ ██╔═══██╗${NC}"
echo -e "${CYAN}███████║██║   ██║    ██║    ██╔██╗ ██║ ██║  ███╗${NC}"
echo -e "${CYAN}██╔══██║██║   ██║    ██║    ██╚██╗██║ ██║   ██║${NC}"
echo -e "${CYAN}██║  ██║╚██████╔╝    ██║    ██ ╚████║ ╚██████╔╝${NC}"
echo -e "${CYAN}╚═╝  ╚═╝ ╚═════╝     ╚═╝    ╚═╝  ╚═══╝  ╚═════╝${NC}"
echo -e "${MAGENTA}──────────────────────────────────────────${NC}"
echo -e "        🚀 AVASH NET - TunnelPilot Ultra PRO MAX 🚀"
echo -e "${MAGENTA}──────────────────────────────────────────${NC}"
echo "Server Public IP: $SERVER_IP"
echo -e "${MAGENTA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# -------------------------------
smart_private(){
echo "Server Role:"
echo "1) Foreign 🇩🇪 (Germany)"
echo "2) IRAN 🇮🇷"
read -rp "Choice [1]: " ROLE
ROLE=${ROLE:-1}

# Default private IPs
IP4_OUT="10.10.1.1/30"
IP4_IR="10.10.1.2/30"
IP6_OUT="fd10:abcd:1234::1/64"
IP6_IR="fd10:abcd:1234::2/64"

DISPLAY_IP4_OUT="$IP4_OUT (default)"
DISPLAY_IP4_IR="$IP4_IR (default)"
DISPLAY_IP6_OUT="$IP6_OUT (default)"
DISPLAY_IP6_IR="$IP6_IR (default)"

case $ROLE in
2)  # Iran
    IP4="$IP4_IR"
    IP6="$IP6_IR"
    DISPLAY_IP4="$DISPLAY_IP4_IR"
    DISPLAY_IP6="$DISPLAY_IP6_IR"
    ;;
*)  # Foreign / Germany
    IP4="$IP4_OUT"
    IP6="$IP6_OUT"
    DISPLAY_IP4="$DISPLAY_IP4_OUT"
    DISPLAY_IP6="$DISPLAY_IP6_OUT"
    ;;
esac

echo "Private IPv4 [$DISPLAY_IP4]: "
read IN4
[ -n "$IN4" ] && IP4="$IN4"

echo "Private IPv6 [$DISPLAY_IP6]: "
read IN6
[ -n "$IN6" ] && IP6="$IN6"
}

clean_ip(){ echo "${1%%/*}"; }

# -------------------------------
test_ping_tcp(){
IP4C=$(clean_ip "$IP4")
IP6C=$(clean_ip "$IP6")
PEER=$1

echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo "Tunnel Summary & Connectivity Test"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo "Server Public IP: $SERVER_IP"
echo "Tunnel Name: $NAME"
echo "Peer Public IP: $PEER"
echo "Private IPv4: $IP4"
echo "Private IPv6: $IP6"

ping -c2 -W1 $IP4C &>/dev/null && echo -e "IPv4 Ping: ${GREEN}✔ OK${NC}" || echo -e "IPv4 Ping: ${RED}✖ FAIL${NC}"
ping6 -c2 -W1 $IP6C &>/dev/null && echo -e "IPv6 Ping: ${GREEN}✔ OK${NC}" || echo -e "IPv6 Ping: ${RED}✖ FAIL${NC}"

for PORT in 22 80 443; do
    timeout 1 bash -c "echo > /dev/tcp/$IP4C/$PORT" &>/dev/null && echo -e "TCP $PORT: ${GREEN}✔ Open${NC}" || echo -e "TCP $PORT: ${RED}✖ Closed${NC}"
done
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# -------------------------------
create_persistent_private_ip(){
echo -e "${YELLOW}━━━━━━━━━━━━ Creating Persistent Private IP ━━━━━━━━━━━━${NC}"
IFACE=$(ip route | awk '/default/ {print $5}' | head -n1)
read -rp "Interface to assign private IP [$IFACE]: " INPUT
IFACE=${INPUT:-$IFACE}

smart_private

ip addr add "$IP4" dev "$IFACE"
ip addr add "$IP6" dev "$IFACE"

enable_forwarding

echo -e "${GREEN}✔ Persistent Private IP added on $IFACE${NC}"
echo "$IFACE $IP4 $IP6" >> "/etc/tunnelpilot/persistent_private_ips.db"
}

# -------------------------------
enable_forwarding(){
grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.conf || echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
grep -q "^net.ipv6.conf.all.forwarding=1" /etc/sysctl.conf || echo "net.ipv6.conf.all.forwarding=1" >> /etc/sysctl.conf
sysctl -p &>/dev/null
echo -e "${GREEN}✔ IP Forwarding Enabled${NC}"
}

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

case $TYPE in
    gre|ipip|l2tp|gretap|sit) echo "$NAME $REMOTE $IP4 $IP6 $MTU" >> "$DB_FILE" ;;
    vxlan|geneve) echo "$NAME $REMOTE $IP4 $IP6 $EXTRA_PARAMS $MTU" >> "$DB_FILE" ;;
esac

echo -e "${GREEN}$TYPE Tunnel Created${NC}"
test_ping_tcp "$REMOTE"
}

# -------------------------------
remove_tunnel(){
echo -e "${YELLOW}━━━━━━━━━━━━━ Private Tunnels ━━━━━━━━━━━━━${NC}"
printf "%-10s | %-18s | %-39s\n" "Name" "IPv4" "IPv6"
printf "%-10s-+-%-18s-+-%-39s\n" "----------" "------------------" "---------------------------------------"
for FILE in "$GRE_DB" "$VXLAN_DB" "$GENEVE_DB" "$IPIP_DB" "$L2TP_DB" "$GRETAB_DB" "$SIT_DB"; do
    while read -r LINE; do
        [ -z "$LINE" ] && continue
        NAME=$(echo $LINE | awk '{print $1}')
        IP4=$(echo $LINE | awk '{print $3}')
        IP6=$(echo $LINE | awk '{print $4}')
        if [[ "$IP4" =~ ^172\.|^10\.|^192\.168\. ]]; then
            printf "${CYAN}%-10s${NC} | %-18s | %-39s\n" "$NAME" "$IP4" "$IP6"
        fi
    done < "$FILE"
done
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

read -rp "Tunnel name to delete: " NAME

if ip link show "$NAME" &>/dev/null; then
    ip addr flush dev "$NAME"
    ip link del "$NAME"
    for FILE in "$GRE_DB" "$VXLAN_DB" "$GENEVE_DB" "$IPIP_DB" "$L2TP_DB" "$GRETAB_DB" "$SIT_DB"; do
        sed -i "/^$NAME /d" "$FILE"
    done
    echo -e "${GREEN}✔ Deleted $NAME and removed private IPs${NC}"
else
    echo -e "${RED}✖ Interface not found${NC}"
fi
}

# -------------------------------
edit_ip(){
echo -e "${YELLOW}━━━━━━━━━━━━━ Private Tunnels ━━━━━━━━━━━━━${NC}"
printf "%-10s | %-18s | %-39s\n" "Name" "IPv4" "IPv6"
printf "%-10s-+-%-18s-+-%-39s\n" "----------" "------------------" "---------------------------------------"
for FILE in "$GRE_DB" "$VXLAN_DB" "$GENEVE_DB" "$IPIP_DB" "$L2TP_DB" "$GRETAB_DB" "$SIT_DB"; do
    while read -r LINE; do
        [ -z "$LINE" ] && continue
        NAME=$(echo $LINE | awk '{print $1}')
        IP4=$(echo $LINE | awk '{print $3}')
        IP6=$(echo $LINE | awk '{print $4}')
        if [[ "$IP4" =~ ^172\.|^10\.|^192\.168\. ]]; then
            printf "${CYAN}%-10s${NC} | %-18s | %-39s\n" "$NAME" "$IP4" "$IP6"
        fi
    done < "$FILE"
done
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

read -rp "Interface to edit: " NAME
ip addr flush dev "$NAME"
read -rp "New IPv4: " N4
read -rp "New IPv6: " N6
ip addr add "$N4" dev "$NAME"
ip addr add "$N6" dev "$NAME"
echo -e "${GREEN}✔ Updated IPs${NC}"
}

# -------------------------------
show_interfaces(){
echo -e "${YELLOW}━━━━━━━━━━━━━ Private Tunnels ━━━━━━━━━━━━━${NC}"
printf "%-10s | %-18s | %-39s | %-21s | %-21s\n" "Name" "IPv4" "IPv6" "Ping IPv4" "Ping IPv6"
printf "%-10s-+-%-18s-+-%-39s-+-%-21s-+-%-21s\n" "----------" "------------------" "---------------------------------------" "--------------------" "--------------------"
for FILE in "$GRE_DB" "$VXLAN_DB" "$GENEVE_DB" "$IPIP_DB" "$L2TP_DB" "$GRETAB_DB" "$SIT_DB"; do
    while read -r LINE; do
        [ -z "$LINE" ] && continue
        NAME=$(echo $LINE | awk '{print $1}')
        IP4=$(echo $LINE | awk '{print $3}')
        IP6=$(echo $LINE | awk '{print $4}')
        if [[ "$IP4" =~ ^172\.|^10\.|^192\.168\. ]]; then
            IP4C=$(clean_ip $IP4)
            IP6C=$(clean_ip $IP6)
            ping -c1 -W1 $IP4C &>/dev/null && P4="✔" || P4="✖"
            ping6 -c1 -W1 $IP6C &>/dev/null && P6="✔" || P6="✖"
            printf "${CYAN}%-10s${NC} | %-18s | %-39s | %-21s | %-21s\n" "$NAME" "$IP4" "$IP6" "$P4" "$P6"
        fi
    done < "$FILE"
done
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
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

echo "1) ⚡    Update Server"
echo "2) 🌐 Create GRE"
echo "3) 🛡 Create VXLAN"
echo "4) 🔗 Create Geneve"
echo "5) 🟢 Create IPIP"
echo "6) 🔵 Create L2TP"
echo "7) 🟣 Create GRETAP"
echo "8) 🟠 Create SIT"
echo "9) ❌    Remove Tunnel"
echo "10) ✏️   Edit Private IP"
echo "11) 📄   Show Interfaces"
echo "12) 🚀 Enable BBR"
echo "13) 🔁 Enable IP Forwarding"
echo "14) 🔄 Restore All Tunnels"
echo "15) 📊 Ping All Private IPs"
echo "16) 🟢 Create Persistent Private IP"
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
11) show_interfaces ;;
12) enable_bbr ;;
13) enable_forwarding ;;
14) enable_forwarding; echo -e "${GREEN}All tunnels restored${NC}" ;;
15) ping_all_private ;;
16) create_persistent_private_ip ;;
0) exit ;;
*) echo -e "${RED}Invalid option${NC}" ;;
esac

read -p "Press Enter..."
done
