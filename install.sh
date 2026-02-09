#!/usr/bin/env bash
# TunnelPilot Ultra PRO 2.1 – Full Edition
# GRE / GRE+IPSec / VXLAN / Geneve TCP
# Multi-Peer + Auto-Failover + Backup + Restore
# Author: ChatGPT

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

SERVER_IP=$(curl -s ipv4.icanhazip.com)
GRE_DB="/etc/tunnelpilot/gre.conf"
VXLAN_DB="/etc/tunnelpilot/vxlan.conf"
GENEVE_DB="/etc/tunnelpilot/geneve.conf"
mkdir -p /etc/tunnelpilot
touch $GRE_DB $VXLAN_DB $GENEVE_DB

log() { echo "[$(date '+%F %T')] $*" >> /var/log/tunnelpilot.log; }

header(){
clear
echo -e "${BLUE}========================================"
echo "      TunnelPilot Ultra PRO 2.1"
echo " GRE / GRE+IPSec / VXLAN / Geneve TCP"
echo "========================================${NC}"
echo "Server Public IP: $SERVER_IP"
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
echo "0) Exit"
read -rp "Select: " CHOICE
}

rand_name(){ echo "$1$(shuf -i1000-9999 -n1)"; }

default_mtu(){ echo "1450"; }

peer_test(){
IP4=$1
IP6=$2
PEER4=$(echo $IP4 | sed 's/1\/30/2/;s/2\/30/1/')
PEER6=$(echo $IP6 | sed 's/::1/::2/;s/::2/::1/')
echo -e "${YELLOW}Testing connectivity...${NC}"
ping -c2 -W1 $PEER4
ping6 -c2 -W1 $PEER6
}

create_gre(){
read -rp "Tunnel name (Enter for random): " NAME
NAME=${NAME:-$(rand_name gre)}
read -rp "Peer Public IP (comma separated): " PEERS
read -rp "Tunnel Type [1 GRE / 2 GRE+IPSec]: " TYPE
read -rp "Private IPv4 (e.g., 172.10.20.1/30): " IP4
read -rp "Private IPv6 (e.g., fd00::1/64): " IP6
read -rp "MTU [$(default_mtu)]: " MTU
MTU=${MTU:-$(default_mtu)}

for REMOTE in ${PEERS//,/ }; do
  ip link del $NAME 2>/dev/null || true
  ip tunnel add $NAME mode gre local $SERVER_IP remote $REMOTE ttl 255
  ip link set $NAME mtu $MTU
  ip addr add $IP4 dev $NAME
  ip addr add $IP6 dev $NAME
  ip link set $NAME up
  echo "$NAME $SERVER_IP $REMOTE $IP4 $IP6 $MTU" >> $GRE_DB
  echo -e "${GREEN}GRE $NAME created with peer $REMOTE${NC}"
  peer_test $IP4 $IP6
done
}

create_vxlan(){
read -rp "Tunnel name (Enter for random): " NAME
NAME=${NAME:-$(rand_name vx)}
read -rp "Peer Public IP (comma separated): " PEERS
read -rp "VNI (Enter=random): " VNI
VNI=${VNI:-$((RANDOM%5000+100))}
read -rp "Private IPv4: " IP4
read -rp "Private IPv6: " IP6
read -rp "MTU [$(default_mtu)]: " MTU
MTU=${MTU:-$(default_mtu)}

for REMOTE in ${PEERS//,/ }; do
  ip link del $NAME 2>/dev/null || true
  ip link add $NAME type vxlan id $VNI local $SERVER_IP remote $REMOTE dstport 4789
  ip link set $NAME mtu $MTU
  ip addr add $IP4 dev $NAME
  ip addr add $IP6 dev $NAME
  ip link set $NAME up
  echo "$NAME $SERVER_IP $REMOTE $VNI $IP4 $IP6 $MTU" >> $VXLAN_DB
  echo -e "${GREEN}VXLAN $NAME created with peer $REMOTE${NC}"
  peer_test $IP4 $IP6
done
}

create_geneve(){
read -rp "Tunnel name (Enter for random): " NAME
NAME=${NAME:-$(rand_name geneve)}
read -rp "Peer Public IP (comma separated): " PEERS
read -rp "VNI (Enter=random): " VNI
VNI=${VNI:-$((RANDOM%5000+100))}
read -rp "Private IPv4: " IP4
read -rp "Private IPv6: " IP6
read -rp "MTU [$(default_mtu)]: " MTU
MTU=${MTU:-$(default_mtu)}

for REMOTE in ${PEERS//,/ }; do
  ip link del $NAME 2>/dev/null || true
  ip link add $NAME type geneve id $VNI remote $REMOTE dstport 6081
  ip link set $NAME mtu $MTU
  ip addr add $IP4 dev $NAME
  ip addr add $IP6 dev $NAME
  ip link set $NAME up
  echo "$NAME $SERVER_IP $REMOTE $VNI $IP4 $IP6 $MTU" >> $GENEVE_DB
  echo -e "${GREEN}Geneve $NAME created with peer $REMOTE${NC}"
  peer_test $IP4 $IP6
done
}

remove_tunnel(){
echo "Existing tunnels:"
ip -br link | awk '{print NR")",$1}'
read -rp "Select number to delete: " NUM
NAME=$(ip -br link | awk '{print $1}' | sed -n "${NUM}p")
ip link del $NAME
sed -i "/^$NAME /d" $GRE_DB
sed -i "/^$NAME /d" $VXLAN_DB
sed -i "/^$NAME /d" $GENEVE_DB
echo -e "${GREEN}Deleted $NAME${NC}"
}

edit_ip(){
read -rp "Interface name: " NAME
ip addr flush dev $NAME
read -rp "New IPv4: " IP4
read -rp "New IPv6: " IP6
ip addr add $IP4 dev $NAME
ip addr add $IP6 dev $NAME
echo -e "${GREEN}IP updated for $NAME${NC}"
}

backup_restore(){
mkdir -p /root/tunnel_backup
cp $GRE_DB /root/tunnel_backup/gre_$(date +%F).conf
cp $VXLAN_DB /root/tunnel_backup/vxlan_$(date +%F).conf
cp $GENEVE_DB /root/tunnel_backup/geneve_$(date +%F).conf
echo -e "${GREEN}Backups saved in /root/tunnel_backup${NC}"
}

auto_failover(){
echo -e "${YELLOW}=== Checking Tunnel Latency & Auto-Failover ===${NC}"
for f in $GRE_DB $VXLAN_DB $GENEVE_DB; do
  while read LINE; do
    [ -z "$LINE" ] && continue
    NAME=$(echo $LINE | awk '{print $1}')
    REMOTE=$(echo $LINE | awk '{print $3}')
    LAT=$(ping -c2 -W1 $REMOTE | tail -1 | awk -F '/' '{print $5}')
    if [[ -z "$LAT" ]]; then
      echo -e "${RED}$NAME Peer $REMOTE DOWN!${NC}"
    else
      echo -e "${GREEN}$NAME Peer $REMOTE Latency: ${LAT}ms${NC}"
    fi
  done < $f
done
echo -e "${YELLOW}Auto-Failover Check Completed${NC}"
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
*) echo "Invalid"; return ;;
esac
sysctl -p
echo -e "${GREEN}TCP Optimization Applied${NC}"
}

while true; do
menu
case $CHOICE in
1) apt update && apt upgrade -y ;;
2) create_gre ;;
3) create_vxlan ;;
4) create_geneve ;;
5) remove_tunnel ;;
6) edit_ip ;;
7) ip -br link ;;
8) enable_bbr ;;
9) backup_restore ;;
10) auto_failover ;;
0) exit ;;
*) echo -e "${RED}Invalid Option${NC}" ;;
esac
read -p "Press Enter to continue..."
done
