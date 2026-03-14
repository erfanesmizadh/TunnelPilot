#!/usr/bin/env bash

# ===============================
# 🚀 AVASH NET - TunnelPilot Ultra PRO ULTIMATE
# Version: 4.0 - Iran Edition
# با Wireguard، SSH Tunnel، و Cloudflare
# ===============================

set -euo pipefail

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Color codes
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly CYAN='\033[0;36m'
readonly MAGENTA='\033[0;35m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Constants
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
readonly DB_DIR="/etc/tunnelpilot"
readonly GRE_DB="$DB_DIR/gre.conf"
readonly VXLAN_DB="$DB_DIR/vxlan.conf"
readonly GENEVE_DB="$DB_DIR/geneve.conf"
readonly IPIP_DB="$DB_DIR/ipip.conf"
readonly L2TP_DB="$DB_DIR/l2tp.conf"
readonly GRETAP_DB="$DB_DIR/gretap.conf"
readonly SIT_DB="$DB_DIR/sit.conf"
readonly WG_DB="$DB_DIR/wireguard.conf"
readonly SSH_DB="$DB_DIR/ssh_tunnels.conf"
readonly CF_DB="$DB_DIR/cloudflare.conf"
readonly WG_DIR="/etc/wireguard"
readonly BACKUP_DIR="/root/tunnelpilot_backup"
readonly LOG_FILE="/var/log/tunnelpilot.log"
readonly LOCK_FILE="/tmp/tunnelpilot.lock"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Globals
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
SERVER_IP=""
NAME=""
REMOTE=""
IP4=""
IP6=""
MTU=""

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Cleanup & Error Handling
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
cleanup() {
    local exit_code=$?
    [[ -f "$LOCK_FILE" ]] && rm -f "$LOCK_FILE"
    rm -f /tmp/tunnelpilot_$$.* 2>/dev/null || true
    if [[ $exit_code -ne 0 ]]; then
        log "ERROR" "Script exited with code $exit_code"
    fi
    exit "$exit_code"
}

trap cleanup EXIT INT TERM

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Logging
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
log() {
    local level=$1
    shift
    local message="$*"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $message" | tee -a "$LOG_FILE"
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Root check
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}❌ Please run as root${NC}"
        exit 1
    fi
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Dependencies
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
install_dependencies() {
    log "INFO" "Checking dependencies..."
    
    declare -A packages=(
        [ip]="iproute2"
        [ping]="iputils-ping"
        [curl]="curl"
        [jq]="jq"
        [wg]="wireguard"
        [wg-quick]="wireguard-tools"
        [ssh]="openssh-client"
    )
    
    local missing=()
    
    for cmd in "${!packages[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("${packages[$cmd]}")
        fi
    done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo -e "${YELLOW}Installing missing packages...${NC}"
        if command -v apt-get &>/dev/null; then
            apt-get update -qq || true
            apt-get install -y "${missing[@]}" || {
                log "ERROR" "Failed to install packages"
                return 1
            }
        fi
    fi
    
    log "INFO" "Dependencies satisfied"
    return 0
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Init Directories
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
init_directories() {
    mkdir -p "$DB_DIR" "$BACKUP_DIR" "$WG_DIR" "$(dirname "$LOG_FILE")"
    touch "$GRE_DB" "$VXLAN_DB" "$GENEVE_DB" "$IPIP_DB" "$L2TP_DB" "$GRETAP_DB" "$SIT_DB" "$WG_DB" "$SSH_DB" "$CF_DB"
    chmod 755 "$DB_DIR" "$BACKUP_DIR" "$WG_DIR" 2>/dev/null || true
    log "INFO" "Directories initialized"
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Get Server IP
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
get_server_ip() {
    if [[ -z "$SERVER_IP" ]]; then
        SERVER_IP=$(curl --connect-timeout 5 --max-time 10 -s ipv4.icanhazip.com 2>/dev/null || echo "0.0.0.0")
    fi
    echo "$SERVER_IP"
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Validation Functions
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
validate_ip() {
    local ip=$1
    if ! [[ "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        log "ERROR" "Invalid IP format: $ip"
        return 1
    fi
    return 0
}

validate_ipv6() {
    local ip=$1
    [[ "$ip" =~ ^([0-9a-fA-F]{0,4}:){2,7}[0-9a-fA-F]{0,4}(/[0-9]+)?$ ]] && return 0
    log "ERROR" "Invalid IPv6 format: $ip"
    return 1
}

validate_tunnel_name() {
    local name=$1
    if ! [[ "$name" =~ ^[a-zA-Z0-9_-]+$ ]] || [[ ${#name} -gt 15 ]]; then
        log "ERROR" "Invalid tunnel name"
        return 1
    fi
    return 0
}

validate_mtu() {
    local mtu=$1
    [[ "$mtu" =~ ^[0-9]+$ ]] && (( mtu >= 68 && mtu <= 65535 )) || return 1
    return 0
}

clean_ip() {
    echo "${1%%/*}"
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Smart Private IP
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
smart_private() {
    echo "Server Role:"
    echo "1) Foreign 🇩🇪 (Abroad)"
    echo "2) IRAN 🇮🇷"
    read -rp "Choice [1]: " role
    role=${role:-1}

    case "$role" in
        2)
            IP4="10.10.1.2/30"
            IP6="fd10:abcd:1234::2/64"
            ;;
        *)
            IP4="10.10.1.1/30"
            IP6="fd10:abcd:1234::1/64"
            ;;
    esac

    read -rp "Private IPv4 [$IP4]: " input
    IP4="${input:-$IP4}"
    
    read -rp "Private IPv6 [$IP6]: " input
    IP6="${input:-$IP6}"
    
    validate_ip "$(clean_ip "$IP4")" || return 1
    validate_ipv6 "$IP6" || return 1
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Lock Management
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
acquire_lock() {
    local timeout=10
    local elapsed=0
    while [[ -f "$LOCK_FILE" ]] && (( elapsed < timeout )); do
        sleep 0.1
        (( elapsed++ ))
    done
    [[ -f "$LOCK_FILE" ]] && return 1
    echo $$ > "$LOCK_FILE"
    return 0
}

release_lock() {
    rm -f "$LOCK_FILE"
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Backup Functions
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
backup_tunnel_db() {
    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_file="$BACKUP_DIR/tunnels_$timestamp.tar.gz"
    tar czf "$backup_file" -C "$DB_DIR" . 2>/dev/null && log "INFO" "Backup: $backup_file"
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# WIREGUARD TUNNEL FUNCTIONS
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
generate_wg_keys() {
    local private_key
    private_key=$(wg genkey)
    local public_key
    public_key=$(echo "$private_key" | wg pubkey)
    echo "$private_key|$public_key"
}

create_wireguard_tunnel() {
    echo -e "${CYAN}🔐 Creating Wireguard Tunnel${NC}"
    
    read -rp "Tunnel name: " NAME
    validate_tunnel_name "$NAME" || return 1
    
    read -rp "Peer Public IP: " REMOTE
    validate_ip "$REMOTE" || return 1
    
    read -rp "Peer Public Key: " PEER_PUB
    read -rp "Listening Port [51820]: " PORT
    PORT=${PORT:-51820}
    
    smart_private || return 1
    
    log "INFO" "Creating Wireguard tunnel: $NAME"
    
    # Generate keys
    local keys server_priv server_pub
    keys=$(generate_wg_keys)
    server_priv="${keys%%|*}"
    server_pub="${keys##*|}"
    
    # Create config
    cat > "$WG_DIR/$NAME.conf" <<EOF
[Interface]
Address = $IP4, $IP6
ListenPort = $PORT
PrivateKey = $server_priv

[Peer]
PublicKey = $PEER_PUB
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = $REMOTE:$PORT
PersistentKeepalive = 25
EOF
    
    # Bring up
    ip link add "$NAME" type wireguard 2>/dev/null || true
    ip addr add "$IP4" dev "$NAME" 2>/dev/null || true
    ip addr add "$IP6" dev "$NAME" 2>/dev/null || true
    ip link set "$NAME" up
    wg set "$NAME" private-key <(echo "$server_priv") || {
        log "ERROR" "Failed to set WG key"
        return 1
    }
    
    # Save
    acquire_lock || return 1
    echo "$NAME|$REMOTE|$IP4|$IP6|$PORT|$server_pub|$server_priv" >> "$WG_DB"
    release_lock
    
    # Show public key
    echo -e "${GREEN}✔ Wireguard tunnel created!${NC}"
    echo -e "${YELLOW}Server Public Key:${NC} $server_pub"
    echo -e "${YELLOW}Save this for peer configuration${NC}"
    
    log "INFO" "Wireguard tunnel: $NAME"
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# SSH TUNNEL FUNCTIONS (برای فیلترینگ سخت)
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
create_ssh_tunnel() {
    echo -e "${CYAN}🔗 Creating SSH Tunnel (Anti-Filtering)${NC}"
    
    read -rp "Tunnel name: " NAME
    validate_tunnel_name "$NAME" || return 1
    
    read -rp "Remote SSH User: " REMOTE_USER
    read -rp "Remote SSH Host: " REMOTE_HOST
    read -rp "Remote SSH Port [22]: " SSH_PORT
    SSH_PORT=${SSH_PORT:-22}
    
    read -rp "Local Port [8080]: " LOCAL_PORT
    LOCAL_PORT=${LOCAL_PORT:-8080}
    
    read -rp "Remote Forward Port [1080]: " REMOTE_PORT
    REMOTE_PORT=${REMOTE_PORT:-1080}
    
    log "INFO" "Creating SSH tunnel: $NAME"
    
    # Create systemd service
    cat > "/etc/systemd/system/ssh-tunnel-$NAME.service" <<'EOFSERVICE'
[Unit]
Description=SSH Tunnel - $TUNNEL_NAME
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

ExecStart=/bin/bash -c 'ssh -N -L $LOCAL_PORT:127.0.0.1:$REMOTE_PORT \
    -p $SSH_PORT \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=10 \
    -o ServerAliveInterval=60 \
    -o ServerAliveCountMax=3 \
    $REMOTE_USER@$REMOTE_HOST'

ExecStop=/bin/kill -TERM $MAINPID

[Install]
WantedBy=multi-user.target
EOFSERVICE

    # Replace variables
    sed -i "s|\$TUNNEL_NAME|$NAME|g" "/etc/systemd/system/ssh-tunnel-$NAME.service"
    sed -i "s|\$LOCAL_PORT|$LOCAL_PORT|g" "/etc/systemd/system/ssh-tunnel-$NAME.service"
    sed -i "s|\$REMOTE_PORT|$REMOTE_PORT|g" "/etc/systemd/system/ssh-tunnel-$NAME.service"
    sed -i "s|\$SSH_PORT|$SSH_PORT|g" "/etc/systemd/system/ssh-tunnel-$NAME.service"
    sed -i "s|\$REMOTE_USER|$REMOTE_USER|g" "/etc/systemd/system/ssh-tunnel-$NAME.service"
    sed -i "s|\$REMOTE_HOST|$REMOTE_HOST|g" "/etc/systemd/system/ssh-tunnel-$NAME.service"
    
    # Enable and start
    systemctl daemon-reload
    systemctl enable "ssh-tunnel-$NAME" 2>/dev/null || true
    systemctl start "ssh-tunnel-$NAME" 2>/dev/null || true
    
    # Save
    acquire_lock || return 1
    echo "$NAME|$REMOTE_USER|$REMOTE_HOST|$SSH_PORT|$LOCAL_PORT|$REMOTE_PORT" >> "$SSH_DB"
    release_lock
    
    echo -e "${GREEN}✔ SSH tunnel created!${NC}"
    echo -e "${YELLOW}Local Port: 127.0.0.1:$LOCAL_PORT${NC}"
    echo -e "${YELLOW}Usage: curl -x socks5://127.0.0.1:$LOCAL_PORT http://example.com${NC}"
    
    sleep 2
    if systemctl is-active --quiet "ssh-tunnel-$NAME"; then
        echo -e "${GREEN}✔ Service is running${NC}"
    else
        echo -e "${RED}✖ Service failed to start${NC}"
        log "ERROR" "SSH tunnel service failed"
    fi
    
    log "INFO" "SSH tunnel: $NAME -> $REMOTE_USER@$REMOTE_HOST"
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# CLOUDFLARE TUNNEL (برای شرایط خیلی سخت)
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
create_cloudflare_tunnel() {
    echo -e "${CYAN}☁️  Creating Cloudflare Tunnel (Ultra Anti-Filtering)${NC}"
    
    # Check cloudflared
    if ! command -v cloudflared &>/dev/null; then
        echo -e "${YELLOW}Installing cloudflared...${NC}"
        curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb -o /tmp/cloudflared.deb
        dpkg -i /tmp/cloudflared.deb 2>/dev/null || {
            log "ERROR" "Failed to install cloudflared"
            return 1
        }
    fi
    
    read -rp "Tunnel name: " NAME
    validate_tunnel_name "$NAME" || return 1
    
    read -rp "Tunnel Token (from Cloudflare): " TOKEN
    [[ -z "$TOKEN" ]] && { echo "Token required!"; return 1; }
    
    read -rp "Local Service Port [3128]: " LOCAL_PORT
    LOCAL_PORT=${LOCAL_PORT:-3128}
    
    log "INFO" "Creating Cloudflare tunnel: $NAME"
    
    # Create systemd service
    cat > "/etc/systemd/system/cloudflare-tunnel-$NAME.service" <<EOF
[Unit]
Description=Cloudflare Tunnel - $NAME
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

ExecStart=/usr/local/bin/cloudflared tunnel run --token $TOKEN

ExecStop=/bin/kill -TERM \$MAINPID

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload
    systemctl enable "cloudflare-tunnel-$NAME" 2>/dev/null || true
    systemctl start "cloudflare-tunnel-$NAME" 2>/dev/null || true
    
    # Save
    acquire_lock || return 1
    echo "$NAME|cloudflare|$TOKEN|$LOCAL_PORT" >> "$CF_DB"
    release_lock
    
    echo -e "${GREEN}✔ Cloudflare tunnel created!${NC}"
    echo -e "${YELLOW}This tunnel uses Cloudflare edge network${NC}"
    echo -e "${YELLOW}Maximum anti-filtering protection${NC}"
    
    log "INFO" "Cloudflare tunnel: $NAME"
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# GRE Tunnel (قدیمی - سریع)
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
create_generic() {
    local type=$1
    local db_file=$2
    local extra_params=${3:-}

    read -rp "Tunnel name: " NAME
    validate_tunnel_name "$NAME" || return 1

    read -rp "Peer Public IP: " REMOTE
    validate_ip "$REMOTE" || return 1

    read -rp "MTU [1450]: " MTU
    MTU=${MTU:-1450}
    validate_mtu "$MTU" || return 1

    smart_private || return 1

    log "INFO" "Creating $type tunnel: $NAME"

    ip addr flush dev "$NAME" 2>/dev/null || true
    ip link del "$NAME" 2>/dev/null || true

    case "$type" in
        gre)
            ip tunnel add "$NAME" mode gre local "$(get_server_ip)" remote "$REMOTE" ttl 255 || {
                log "ERROR" "Failed to create GRE tunnel"
                return 1
            }
            ;;
        vxlan)
            ip link add "$NAME" type vxlan id "$extra_params" local "$(get_server_ip)" remote "$REMOTE" dstport 4789 || {
                log "ERROR" "Failed to create VXLAN tunnel"
                return 1
            }
            ;;
        *)
            log "ERROR" "Unknown tunnel type: $type"
            return 1
            ;;
    esac

    ip link set "$NAME" up || return 1
    ip addr add "$IP4" dev "$NAME" || return 1
    ip addr add "$IP6" dev "$NAME" || return 1
    ip link set "$NAME" mtu "$MTU" || return 1

    acquire_lock || return 1
    echo "$NAME|$REMOTE|$IP4|$IP6|$MTU" >> "$db_file"
    release_lock

    log "INFO" "$type tunnel created: $NAME"
    echo -e "${GREEN}✔ $type tunnel created!${NC}"
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# List Tunnels
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
list_all_tunnels() {
    echo -e "${CYAN}═══════════════════════════════════════════════${NC}"
    echo -e "${CYAN}          All Tunnels & Services${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════${NC}"
    
    # Wireguard
    echo -e "\n${GREEN}🔐 Wireguard Tunnels:${NC}"
    if [[ -s "$WG_DB" ]]; then
        while IFS='|' read -r name remote ip4 ip6 port _ _; do
            [[ -z "$name" ]] && continue
            printf "  ${CYAN}%-15s${NC} | %-18s | %-40s\n" "$name" "$remote:$port" "$ip4"
        done < "$WG_DB"
    else
        echo "  (none)"
    fi
    
    # SSH Tunnels
    echo -e "\n${BLUE}🔗 SSH Tunnels (Anti-Filtering):${NC}"
    if [[ -s "$SSH_DB" ]]; then
        while IFS='|' read -r name user host sshport localport _; do
            [[ -z "$name" ]] && continue
            printf "  ${CYAN}%-15s${NC} | %-25s | Port: %-10s\n" "$name" "$user@$host:$sshport" "$localport"
        done < "$SSH_DB"
    else
        echo "  (none)"
    fi
    
    # Cloudflare
    echo -e "\n${MAGENTA}☁️  Cloudflare Tunnels:${NC}"
    if [[ -s "$CF_DB" ]]; then
        while IFS='|' read -r name type token port; do
            [[ -z "$name" ]] && continue
            printf "  ${CYAN}%-15s${NC} | Cloudflare Edge Network\n" "$name"
        done < "$CF_DB"
    else
        echo "  (none)"
    fi
    
    # GRE
    echo -e "\n${YELLOW}🌐 GRE Tunnels:${NC}"
    if [[ -s "$GRE_DB" ]]; then
        while IFS='|' read -r name remote ip4 ip6 mtu; do
            [[ -z "$name" ]] && continue
            printf "  ${CYAN}%-15s${NC} | %-18s | %-40s\n" "$name" "$remote" "$ip4"
        done < "$GRE_DB"
    else
        echo "  (none)"
    fi
    
    echo -e "\n${CYAN}═══════════════════════════════════════════════${NC}"
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Remove Tunnel
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
remove_tunnel() {
    list_all_tunnels
    
    read -rp "Tunnel name to delete: " NAME
    [[ -z "$NAME" ]] && return 1
    
    # Remove interface
    ip addr flush dev "$NAME" 2>/dev/null || true
    ip link del "$NAME" 2>/dev/null || true
    
    # Remove SSH service
    systemctl stop "ssh-tunnel-$NAME" 2>/dev/null || true
    systemctl disable "ssh-tunnel-$NAME" 2>/dev/null || true
    rm -f "/etc/systemd/system/ssh-tunnel-$NAME.service"
    
    # Remove Cloudflare service
    systemctl stop "cloudflare-tunnel-$NAME" 2>/dev/null || true
    systemctl disable "cloudflare-tunnel-$NAME" 2>/dev/null || true
    rm -f "/etc/systemd/system/cloudflare-tunnel-$NAME.service"
    
    systemctl daemon-reload 2>/dev/null || true
    
    # Remove from databases
    acquire_lock || return 1
    for file in "$GRE_DB" "$VXLAN_DB" "$WG_DB" "$SSH_DB" "$CF_DB"; do
        [[ -f "$file" ]] && sed -i "/^$NAME|/d" "$file"
    done
    release_lock
    
    # Remove WG config
    rm -f "$WG_DIR/$NAME.conf"
    
    log "INFO" "Tunnel deleted: $NAME"
    echo -e "${GREEN}✔ Tunnel deleted: $NAME${NC}"
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Test Tunnel
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
test_tunnel_connectivity() {
    list_all_tunnels
    
    read -rp "Tunnel name to test: " NAME
    [[ -z "$NAME" ]] && return 1
    
    if ! ip link show "$NAME" &>/dev/null; then
        echo -e "${RED}✖ Tunnel not found${NC}"
        return 1
    fi
    
    echo -e "${YELLOW}Testing $NAME...${NC}"
    
    # Get IPs
    local ip4 ip6
    ip4=$(ip -4 addr show "$NAME" | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
    ip6=$(ip -6 addr show "$NAME" | grep -oP '(?<=inet6\s)[0-9a-f:]+' | head -1)
    
    echo "IPv4: $ip4"
    ping -c 2 -W 2 -q "$ip4" &>/dev/null && echo -e "  ${GREEN}✔ IPv4 OK${NC}" || echo -e "  ${RED}✖ IPv4 FAIL${NC}"
    
    echo "IPv6: $ip6"
    ping6 -c 2 -W 2 -q "$ip6" &>/dev/null && echo -e "  ${GREEN}✔ IPv6 OK${NC}" || echo -e "  ${RED}✖ IPv6 FAIL${NC}"
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Enable Forwarding
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
enable_forwarding() {
    log "INFO" "Enabling IP forwarding..."
    
    grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.conf || echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
    grep -q "^net.ipv6.conf.all.forwarding=1" /etc/sysctl.conf || echo "net.ipv6.conf.all.forwarding=1" >> /etc/sysctl.conf
    
    sysctl -p &>/dev/null || return 1
    echo -e "${GREEN}✔ IP Forwarding Enabled${NC}"
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Enable BBR
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
enable_bbr() {
    echo "1) BBR"
    echo "2) BBR2"
    echo "3) Cubic"
    read -rp "Choice: " opt
    
    grep -q "^net.core.default_qdisc=fq" /etc/sysctl.conf || echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    
    case "$opt" in
        1) sysctl -w net.ipv4.tcp_congestion_control=bbr ;;
        2) sysctl -w net.ipv4.tcp_congestion_control=bbr2 ;;
        3) sysctl -w net.ipv4.tcp_congestion_control=cubic ;;
    esac
    
    sysctl -p &>/dev/null || true
    echo -e "${GREEN}✔ TCP updated${NC}"
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Advanced Iran Filtering Bypass Setup
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
setup_iran_bypass() {
    echo -e "${MAGENTA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}Iran Anti-Filtering Advanced Setup${NC}"
    echo -e "${MAGENTA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    
    echo "1) Setup SSH Tunnel (Port Obfuscation)"
    echo "2) Setup Wireguard (UDP Tunneling)"
    echo "3) Setup Cloudflare Tunnel (Maximum Protection)"
    echo "4) Setup Hybrid (All 3 Combined)"
    
    read -rp "Choice: " choice
    
    case "$choice" in
        1)
            echo -e "${YELLOW}Setting up SSH Tunnel...${NC}"
            create_ssh_tunnel
            ;;
        2)
            echo -e "${YELLOW}Setting up Wireguard...${NC}"
            create_wireguard_tunnel
            ;;
        3)
            echo -e "${YELLOW}Setting up Cloudflare...${NC}"
            create_cloudflare_tunnel
            ;;
        4)
            echo -e "${YELLOW}Setting up HYBRID mode...${NC}"
            create_ssh_tunnel && sleep 1
            create_wireguard_tunnel && sleep 1
            create_cloudflare_tunnel
            ;;
        *)
            echo -e "${RED}Invalid option${NC}"
            ;;
    esac
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Show Header
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
show_header() {
    clear
    echo -e "${MAGENTA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN} █████╗ ██╗   ██╗ ████████╗ ███╗   ██╗ ██████╗ ${NC}"
    echo -e "${CYAN}██╔══██╗██║   ██║ ╚══██╔══╝ ████╗  ██║ ██╔═══██╗${NC}"
    echo -e "${CYAN}███████║██║   ██║    ██║    ██╔██╗ ██║ ██║  ███╗${NC}"
    echo -e "${CYAN}██╔══██║██║   ██║    ██║    ██╚██╗██║ ██║   ██║${NC}"
    echo -e "${CYAN}██║  ██║╚██████╔╝    ██║    ██ ╚████║ ╚██████╔╝${NC}"
    echo -e "${CYAN}╚═╝  ╚═╝ ╚═════╝     ╚═╝    ╚═╝  ╚═══╝  ╚═════╝${NC}"
    echo -e "${MAGENTA}──────────────────────────────────────────${NC}"
    echo -e "   🚀 TunnelPilot Ultra PRO ULTIMATE v4.0"
    echo -e "      Iran Edition - Anti-Filtering Optimized"
    echo -e "${MAGENTA}──────────────────────────────────────────${NC}"
    echo "Server Public IP: $(get_server_ip)"
    echo -e "${MAGENTA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Main Menu
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
main() {
    check_root
    install_dependencies || exit 1
    init_directories || exit 1
    
    log "INFO" "=== TunnelPilot v4.0 Started ==="
    
    while true; do
        show_header

        echo -e "\n${YELLOW}📡 ADVANCED TUNNELS (Iran Edition):${NC}"
        echo "1) 🔐 Create Wireguard Tunnel (UDP Tunneling)"
        echo "2) 🔗 Create SSH Tunnel (Anti-Filtering)"
        echo "3) ☁️  Create Cloudflare Tunnel (Maximum Protection)"
        echo "4) 🛡️  HYBRID Setup (All 3 Combined)"
        echo "5) 🔧 Advanced Iran Bypass Setup"
        
        echo -e "\n${YELLOW}🌐 STANDARD TUNNELS:${NC}"
        echo "6) 🌐 Create GRE Tunnel"
        echo "7) 🛡️  Create VXLAN Tunnel"
        
        echo -e "\n${YELLOW}🛠️  MANAGEMENT:${NC}"
        echo "8) ❌ Remove Tunnel"
        echo "9) 📄 List All Tunnels"
        echo "10) 🧪 Test Tunnel Connectivity"
        echo "11) ⚡ Update Server"
        echo "12) 🔁 Enable IP Forwarding"
        echo "13) 🚀 Enable BBR/BBR2/Cubic"
        echo "14) 💾 Backup All Tunnels"
        echo "15) 📊 View Logs"
        echo "0) Exit"

        read -rp "Choice: " choice
        choice=${choice:-0}
        
        case "$choice" in
            1) create_wireguard_tunnel ;;
            2) create_ssh_tunnel ;;
            3) create_cloudflare_tunnel ;;
            4)
                echo -e "${YELLOW}Creating HYBRID setup...${NC}"
                create_wireguard_tunnel && sleep 1
                create_ssh_tunnel && sleep 1
                create_cloudflare_tunnel
                ;;
            5) setup_iran_bypass ;;
            6) create_generic "gre" "$GRE_DB" ;;
            7)
                read -rp "VNI [1]: " vni
                create_generic "vxlan" "$VXLAN_DB" "${vni:-1}"
                ;;
            8) remove_tunnel ;;
            9) list_all_tunnels ;;
            10) test_tunnel_connectivity ;;
            11)
                apt-get update && apt-get upgrade -y || log "ERROR" "Update failed"
                ;;
            12) enable_forwarding ;;
            13) enable_bbr ;;
            14) backup_tunnel_db && echo -e "${GREEN}✔ Backup created${NC}" ;;
            15) tail -30 "$LOG_FILE" ;;
            0)
                log "INFO" "=== TunnelPilot Exited ==="
                echo -e "${GREEN}Goodbye! 👋${NC}"
                exit 0
                ;;
            *)
                echo -e "${RED}Invalid option${NC}"
                ;;
        esac

        read -p "Press Enter to continue..."
    done
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Run
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
main "$@"
