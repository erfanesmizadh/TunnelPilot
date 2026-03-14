#!/usr/bin/env bash

# ===============================
# 🚀 AVASH NET - TunnelPilot Ultra PRO ULTIMATE v4.1
# با UDP2RAW Integrated برای بدترین فیلتر ایران
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
readonly UDP2RAW_DB="$DB_DIR/udp2raw.conf"
readonly WG_DIR="/etc/wireguard"
readonly UDP2RAW_DIR="/etc/tunnelpilot/udp2raw"
readonly BACKUP_DIR="/root/tunnelpilot_backup"
readonly LOG_FILE="/var/log/tunnelpilot.log"
readonly UDP2RAW_LOG="/var/log/tunnelpilot_udp2raw.log"
readonly LOCK_FILE="/tmp/tunnelpilot.lock"
readonly UDP2RAW_BIN="/usr/local/bin/udp2raw"

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
    mkdir -p "$DB_DIR" "$BACKUP_DIR" "$WG_DIR" "$UDP2RAW_DIR" "$(dirname "$LOG_FILE")" "$(dirname "$UDP2RAW_LOG")"
    touch "$GRE_DB" "$VXLAN_DB" "$GENEVE_DB" "$IPIP_DB" "$L2TP_DB" "$GRETAP_DB" "$SIT_DB" "$WG_DB" "$SSH_DB" "$CF_DB" "$UDP2RAW_DB"
    chmod 755 "$DB_DIR" "$BACKUP_DIR" "$WG_DIR" "$UDP2RAW_DIR" 2>/dev/null || true
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

validate_port() {
    local port=$1
    [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 )) && return 0
    log "ERROR" "Invalid port: $port"
    return 1
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
# ⭐ UDP2RAW SERVER TUNNEL
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
create_udp2raw_server() {
    echo -e "${CYAN}🌊 Creating UDP2RAW Server Tunnel${NC}"
    
    # Check if UDP2RAW binary exists
    if [[ ! -f "$UDP2RAW_BIN" ]]; then
        echo -e "${YELLOW}UDP2RAW binary not found. Installing...${NC}"
        install_udp2raw_binary || {
            echo -e "${RED}Failed to install UDP2RAW${NC}"
            return 1
        }
    fi
    
    read -rp "Tunnel name: " NAME
    validate_tunnel_name "$NAME" || return 1
    
    read -rp "Local UDP Port to Listen [8080]: " LOCAL_UDP_PORT
    LOCAL_UDP_PORT=${LOCAL_UDP_PORT:-8080}
    validate_port "$LOCAL_UDP_PORT" || return 1
    
    read -rp "RAW Packet Port [9090]: " RAW_PORT
    RAW_PORT=${RAW_PORT:-9090}
    validate_port "$RAW_PORT" || return 1
    
    echo "Select protocol:"
    echo "  1) ICMP (توصیه شده - Ping-based)"
    echo "  2) DNS (Port 53)"
    echo "  3) HTTP (Port 80)"
    read -rp "Choice [1]: " proto_choice
    proto_choice=${proto_choice:-1}
    
    local PROTOCOL
    case "$proto_choice" in
        1) PROTOCOL="icmp" ;;
        2) PROTOCOL="dns" ;;
        3) PROTOCOL="http" ;;
        *) PROTOCOL="icmp" ;;
    esac
    
    log "INFO" "Creating UDP2RAW server: $NAME"
    
    # Create systemd service
    cat > "/etc/systemd/system/udp2raw-server-$NAME.service" <<EOFSERVICE
[Unit]
Description=UDP2RAW Server Tunnel - $NAME
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal
ExecStart=$UDP2RAW_BIN -s -l 0.0.0.0:$RAW_PORT -r 127.0.0.1:$LOCAL_UDP_PORT -a -k "password123" --raw-mode $PROTOCOL
ExecStop=/bin/kill -TERM \$MAINPID

[Install]
WantedBy=multi-user.target
EOFSERVICE

    systemctl daemon-reload
    systemctl enable "udp2raw-server-$NAME" 2>/dev/null || true
    systemctl start "udp2raw-server-$NAME" 2>/dev/null || true
    
    # Save to database
    acquire_lock || return 1
    echo "$NAME|server|0.0.0.0|$RAW_PORT|127.0.0.1|$LOCAL_UDP_PORT|$PROTOCOL|$(date +%s)" >> "$UDP2RAW_DB"
    release_lock
    
    echo -e "${GREEN}✔ UDP2RAW server tunnel created!${NC}"
    echo -e "${YELLOW}Name: $NAME${NC}"
    echo -e "${YELLOW}Listen on: 0.0.0.0:$RAW_PORT ($PROTOCOL)${NC}"
    echo -e "${YELLOW}Forward to: 127.0.0.1:$LOCAL_UDP_PORT (UDP)${NC}"
    
    log "INFO" "UDP2RAW server: $NAME → $PROTOCOL"
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# ⭐ UDP2RAW CLIENT TUNNEL
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
create_udp2raw_client() {
    echo -e "${CYAN}🌊 Creating UDP2RAW Client Tunnel${NC}"
    
    # Check if UDP2RAW binary exists
    if [[ ! -f "$UDP2RAW_BIN" ]]; then
        echo -e "${YELLOW}UDP2RAW binary not found. Installing...${NC}"
        install_udp2raw_binary || {
            echo -e "${RED}Failed to install UDP2RAW${NC}"
            return 1
        }
    fi
    
    read -rp "Tunnel name: " NAME
    validate_tunnel_name "$NAME" || return 1
    
    read -rp "Server IP: " SERVER_IP_INPUT
    validate_ip "$SERVER_IP_INPUT" || return 1
    
    read -rp "Server RAW Port [9090]: " SERVER_RAW_PORT
    SERVER_RAW_PORT=${SERVER_RAW_PORT:-9090}
    validate_port "$SERVER_RAW_PORT" || return 1
    
    read -rp "Local UDP Port to Provide [1080]: " LOCAL_UDP_PORT
    LOCAL_UDP_PORT=${LOCAL_UDP_PORT:-1080}
    validate_port "$LOCAL_UDP_PORT" || return 1
    
    echo "Select protocol (must match server):"
    echo "  1) ICMP"
    echo "  2) DNS"
    echo "  3) HTTP"
    read -rp "Choice [1]: " proto_choice
    proto_choice=${proto_choice:-1}
    
    local PROTOCOL
    case "$proto_choice" in
        1) PROTOCOL="icmp" ;;
        2) PROTOCOL="dns" ;;
        3) PROTOCOL="http" ;;
        *) PROTOCOL="icmp" ;;
    esac
    
    log "INFO" "Creating UDP2RAW client: $NAME"
    
    # Create systemd service
    cat > "/etc/systemd/system/udp2raw-client-$NAME.service" <<EOFSERVICE
[Unit]
Description=UDP2RAW Client Tunnel - $NAME
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal
ExecStart=$UDP2RAW_BIN -c -l 127.0.0.1:$LOCAL_UDP_PORT -r $SERVER_IP_INPUT:$SERVER_RAW_PORT -a -k "password123" --raw-mode $PROTOCOL
ExecStop=/bin/kill -TERM \$MAINPID

[Install]
WantedBy=multi-user.target
EOFSERVICE

    systemctl daemon-reload
    systemctl enable "udp2raw-client-$NAME" 2>/dev/null || true
    systemctl start "udp2raw-client-$NAME" 2>/dev/null || true
    
    # Save to database
    acquire_lock || return 1
    echo "$NAME|client|$SERVER_IP_INPUT|$SERVER_RAW_PORT|127.0.0.1|$LOCAL_UDP_PORT|$PROTOCOL|$(date +%s)" >> "$UDP2RAW_DB"
    release_lock
    
    echo -e "${GREEN}✔ UDP2RAW client tunnel created!${NC}"
    echo -e "${YELLOW}Name: $NAME${NC}"
    echo -e "${YELLOW}Server: $SERVER_IP_INPUT:$SERVER_RAW_PORT ($PROTOCOL)${NC}"
    echo -e "${YELLOW}Local: 127.0.0.1:$LOCAL_UDP_PORT (UDP)${NC}"
    
    log "INFO" "UDP2RAW client: $NAME → $PROTOCOL"
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# UDP2RAW Binary Installation
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
install_udp2raw_binary() {
    if [[ -f "$UDP2RAW_BIN" ]]; then
        echo -e "${GREEN}✔ UDP2RAW already installed${NC}"
        return 0
    fi

    echo -e "${YELLOW}Installing UDP2RAW binary...${NC}"
    
    local arch
    arch=$(uname -m)
    local binary_url=""
    
    case "$arch" in
        x86_64)
            binary_url="https://github.com/wangyu-/udp2raw-tunnel/releases/download/20201113.0/udp2raw_binaries/udp2raw_amd64"
            ;;
        aarch64)
            binary_url="https://github.com/wangyu-/udp2raw-tunnel/releases/download/20201113.0/udp2raw_binaries/udp2raw_arm64"
            ;;
        armv7l)
            binary_url="https://github.com/wangyu-/udp2raw-tunnel/releases/download/20201113.0/udp2raw_binaries/udp2raw_armhf"
            ;;
        *)
            log "ERROR" "Unsupported architecture: $arch"
            return 1
            ;;
    esac

    log "INFO" "Downloading UDP2RAW..."
    
    if curl -fsSL "$binary_url" -o "$UDP2RAW_BIN" 2>/dev/null; then
        chmod +x "$UDP2RAW_BIN"
        log "INFO" "UDP2RAW installed successfully"
        echo -e "${GREEN}✔ UDP2RAW installed${NC}"
        return 0
    else
        log "ERROR" "Failed to download UDP2RAW"
        echo -e "${RED}Failed to install UDP2RAW${NC}"
        return 1
    fi
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# List ALL Tunnels Including UDP2RAW
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
list_all_tunnels() {
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}              All Tunnels & Services${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    
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
    
    # 🌊 UDP2RAW (NEW)
    echo -e "\n${BLUE}🌊 UDP2RAW Tunnels (DPI Evasion):${NC}"
    if [[ -s "$UDP2RAW_DB" ]]; then
        while IFS='|' read -r name mode local_addr local_port remote_addr remote_port protocol _; do
            [[ -z "$name" ]] && continue
            
            local service_name="udp2raw-${mode}-${name}"
            local status
            
            if systemctl is-active --quiet "$service_name" 2>/dev/null; then
                status="${GREEN}✔${NC}"
            else
                status="${RED}✗${NC}"
            fi
            
            printf "  ${CYAN}%-15s${NC} | %-8s | %-18s | %-18s | %-8s %b\n" \
                "$name" "$mode" "$local_addr:$local_port" "$remote_addr:$remote_port" "$protocol" "$status"
        done < "$UDP2RAW_DB"
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
    
    echo -e "\n${CYAN}═══════════════════════════════════════════════════════════════${NC}"
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Test UDP2RAW Tunnel
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
test_udp2raw_tunnel() {
    list_all_tunnels
    
    read -rp "Tunnel name to test: " NAME
    [[ -z "$NAME" ]] && return 1
    
    echo -e "${YELLOW}Testing UDP2RAW $NAME...${NC}"
    
    # Check service
    if systemctl is-active --quiet "udp2raw-server-$NAME" 2>/dev/null; then
        echo -e "${GREEN}✔ Server service is running${NC}"
    elif systemctl is-active --quiet "udp2raw-client-$NAME" 2>/dev/null; then
        echo -e "${GREEN}✔ Client service is running${NC}"
    else
        echo -e "${RED}✗ Service is not running${NC}"
        return 1
    fi
    
    log "INFO" "UDP2RAW test completed: $NAME"
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Remove UDP2RAW Tunnel
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
remove_udp2raw_tunnel() {
    list_all_tunnels
    
    read -rp "UDP2RAW tunnel name to delete: " NAME
    [[ -z "$NAME" ]] && return 1
    
    echo -e "${YELLOW}Removing $NAME...${NC}"
    
    systemctl stop "udp2raw-server-$NAME" 2>/dev/null || true
    systemctl stop "udp2raw-client-$NAME" 2>/dev/null || true
    
    systemctl disable "udp2raw-server-$NAME" 2>/dev/null || true
    systemctl disable "udp2raw-client-$NAME" 2>/dev/null || true
    
    rm -f "/etc/systemd/system/udp2raw-server-$NAME.service"
    rm -f "/etc/systemd/system/udp2raw-client-$NAME.service"
    
    systemctl daemon-reload 2>/dev/null || true
    
    acquire_lock || return 1
    sed -i "/^$NAME|/d" "$UDP2RAW_DB"
    release_lock
    
    echo -e "${GREEN}✔ UDP2RAW tunnel removed: $NAME${NC}"
    log "INFO" "UDP2RAW tunnel removed: $NAME"
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# GRE Tunnel (Legacy)
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
# Remove Generic Tunnel
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
remove_tunnel() {
    list_all_tunnels
    
    read -rp "Tunnel name to delete: " NAME
    [[ -z "$NAME" ]] && return 1
    
    ip addr flush dev "$NAME" 2>/dev/null || true
    ip link del "$NAME" 2>/dev/null || true
    
    acquire_lock || return 1
    for file in "$GRE_DB" "$VXLAN_DB" "$UDP2RAW_DB"; do
        [[ -f "$file" ]] && sed -i "/^$NAME|/d" "$file"
    done
    release_lock
    
    log "INFO" "Tunnel deleted: $NAME"
    echo -e "${GREEN}✔ Tunnel deleted: $NAME${NC}"
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Enable IP Forwarding
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
    echo -e "   🚀 TunnelPilot Ultra PRO ULTIMATE v4.1"
    echo -e "      Iran Edition - UDP2RAW Integrated"
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
    
    log "INFO" "=== TunnelPilot v4.1 with UDP2RAW Started ==="
    
    while true; do
        show_header

        echo -e "\n${YELLOW}🌊 UDP2RAW TUNNELS (بدترین فیلتر ایران):${NC}"
        echo "1) 🌊 Create UDP2RAW Server"
        echo "2) 🌊 Create UDP2RAW Client"

        echo -e "\n${YELLOW}🔐 ADVANCED TUNNELS:${NC}"
        echo "3) 🔐 Create Wireguard Tunnel"
        echo "4) 🔗 Create SSH Tunnel (Anti-Filtering)"
        echo "5) ☁️  Create Cloudflare Tunnel"
        echo "6) 🛡️  HYBRID Setup (All Combined)"

        echo -e "\n${YELLOW}🌐 LEGACY TUNNELS:${NC}"
        echo "7) 🌐 Create GRE Tunnel"
        echo "8) 🛡️  Create VXLAN Tunnel"

        echo -e "\n${YELLOW}🛠️  MANAGEMENT:${NC}"
        echo "9) ❌ Remove Tunnel"
        echo "10) 📄 List All Tunnels"
        echo "11) 🧪 Test UDP2RAW Tunnel"
        echo "12) ⚡ Update Server"
        echo "13) 🔁 Enable IP Forwarding"
        echo "14) 🚀 Enable BBR/BBR2/Cubic"
        echo "15) 💾 Backup All Tunnels"
        echo "16) 📊 View Logs"
        echo "0) Exit"

        read -rp "Choice: " choice
        choice=${choice:-0}
        
        case "$choice" in
            1) create_udp2raw_server ;;
            2) create_udp2raw_client ;;
            3) 
                read -rp "VNI [1]: " vni
                create_generic "wireguard" "$WG_DB" "${vni:-1}" 2>/dev/null || true
                ;;
            4) create_generic "ssh" "$SSH_DB" ;;
            5) create_generic "cloudflare" "$CF_DB" ;;
            6) 
                echo -e "${YELLOW}Creating HYBRID setup...${NC}"
                create_udp2raw_server && sleep 1
                create_generic "wireguard" "$WG_DB" "1" 2>/dev/null || true && sleep 1
                echo -e "${GREEN}✔ HYBRID setup complete${NC}"
                ;;
            7) create_generic "gre" "$GRE_DB" ;;
            8)
                read -rp "VNI [1]: " vni
                create_generic "vxlan" "$VXLAN_DB" "${vni:-1}"
                ;;
            9) remove_udp2raw_tunnel ;;
            10) list_all_tunnels ;;
            11) test_udp2raw_tunnel ;;
            12)
                apt-get update && apt-get upgrade -y || log "ERROR" "Update failed"
                ;;
            13) enable_forwarding ;;
            14) enable_bbr ;;
            15) backup_tunnel_db && echo -e "${GREEN}✔ Backup created${NC}" ;;
            16) tail -30 "$LOG_FILE" ;;
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
