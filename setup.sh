#!/bin/bash
# Enhanced WireGuard over WebSocket Setup Script
# Supports Ubuntu/Debian with comprehensive error handling

set -euo pipefail
trap 'error_handler $? $LINENO $BASH_LINENO "$BASH_COMMAND" $(printf "::%s" ${FUNCNAME[@]:-})' ERR

# Color codes for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

# Configuration variables
readonly WG_INTERFACE="wg0"
readonly WG_PORT="51820"
readonly WS_PORT="443"
readonly LOCAL_WG_PORT="51821"
readonly WG_NETWORK="10.10.0.0/24"
readonly WG_SERVER_IP="10.10.0.1"
readonly WG_CLIENT_IP="10.10.0.2"
readonly WG_CONFIG_DIR="/etc/wireguard"
readonly GOST_PATH="/usr/local/bin/gost"
readonly LOG_DIR="/var/log/wireguard-ws"
readonly LOG_FILE="${LOG_DIR}/setup.log"
readonly BACKUP_DIR="/root/wg-backup"
readonly CLIENT_DIR="/root/wg-client"
readonly GOST_VERSION="v3.0.0-nightly.20250207"

# Error handler function
error_handler() {
    local exit_code=$1
    local line_number=$2
    local bash_lineno=$3
    local last_command=$4
    local error_trace=$5
    
    log "ERROR: Command '$last_command' failed with exit code $exit_code at line $line_number"
    log "Stack trace: $error_trace"
    
    cleanup
    exit $exit_code
}

# Logging function
log() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${timestamp} - $1" | tee -a "$LOG_FILE"
}

# Cleanup function
cleanup() {
    log "Performing cleanup..."
    # Stop services in case of failure
    systemctl stop wg-quick@${WG_INTERFACE} 2>/dev/null || true
    systemctl stop gost 2>/dev/null || true
}

# Check system requirements
check_requirements() {
    log "Checking system requirements..."
    
    # Check root
    if [[ $EUID -ne 0 ]]; then
        log "${RED}This script must be run as root${NC}"
        exit 1
    }
    
    # Check OS
    if ! grep -qi "ubuntu\|debian" /etc/os-release; then
        log "${RED}This script requires Ubuntu or Debian${NC}"
        exit 1
    }
    
    # Check kernel version
    local kernel_version=$(uname -r | cut -d. -f1)
    if [[ $kernel_version -lt 5 ]]; then
        log "${RED}Kernel 5.x or higher is required${NC}"
        exit 1
    }
    
    # Create necessary directories
    mkdir -p "$LOG_DIR" "$BACKUP_DIR" "$CLIENT_DIR"
}

# Install dependencies
install_dependencies() {
    log "Installing dependencies..."
    
    apt-get update
    apt-get install -y \
        wireguard \
        qrencode \
        iptables \
        curl \
        wget \
        ufw \
        jq \
        resolvconf
}

# Install and configure gost
install_gost() {
    log "Installing gost..."
    
    if [[ -f "$GOST_PATH" ]]; then
        log "Gost already installed, checking version..."
        return 0
    }
    
    local gost_url="https://github.com/go-gost/gost/releases/download/${GOST_VERSION}/gost_${GOST_VERSION}_linux_amd64.tar.gz"
    wget -O /tmp/gost.tar.gz "$gost_url"
    tar -xzf /tmp/gost.tar.gz -C /tmp
    mv /tmp/gost "$GOST_PATH"
    chmod +x "$GOST_PATH"
    rm /tmp/gost.tar.gz
    
    # Create systemd service for gost
    cat > /etc/systemd/system/gost.service <<EOF
[Unit]
Description=Gost WebSocket Tunnel
After=network.target

[Service]
Type=simple
User=root
ExecStart=$GOST_PATH -L udp://:${WG_PORT} -F relay+ws://:${WS_PORT}
Restart=always
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable gost
}

# Generate WireGuard keys
generate_keys() {
    log "Generating WireGuard keys..."
    
    cd "$WG_CONFIG_DIR"
    umask 077
    
    # Server keys
    wg genkey | tee server_private.key | wg pubkey > server_public.key
    SERVER_PRIVATE_KEY=$(cat server_private.key)
    SERVER_PUBLIC_KEY=$(cat server_public.key)
    
    # Client keys
    wg genkey | tee client_private.key | wg pubkey > client_public.key
    CLIENT_PRIVATE_KEY=$(cat client_private.key)
    CLIENT_PUBLIC_KEY=$(cat client_public.key)
}

# Configure WireGuard server
configure_server() {
    log "Configuring WireGuard server..."
    
    local primary_interface=$(ip route get 8.8.8.8 | awk '{print $5; exit}')
    
    cat > "${WG_CONFIG_DIR}/${WG_INTERFACE}.conf" <<EOF
[Interface]
PrivateKey = ${SERVER_PRIVATE_KEY}
Address = ${WG_SERVER_IP}/24
ListenPort = ${WG_PORT}
SaveConfig = true

PostUp = iptables -A FORWARD -i %i -j ACCEPT; iptables -A FORWARD -o %i -j ACCEPT; iptables -t nat -A POSTROUTING -o ${primary_interface} -j MASQUERADE
PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -D FORWARD -o %i -j ACCEPT; iptables -t nat -D POSTROUTING -o ${primary_interface} -j MASQUERADE

[Peer]
PublicKey = ${CLIENT_PUBLIC_KEY}
AllowedIPs = ${WG_CLIENT_IP}/32
EOF

    chmod 600 "${WG_CONFIG_DIR}/${WG_INTERFACE}.conf"
}

# Configure client files
configure_client() {
    log "Creating client configuration..."
    
    local server_ip=$(curl -s ifconfig.me)
    
    # WireGuard client configuration
    cat > "${CLIENT_DIR}/wg0.conf" <<EOF
[Interface]
PrivateKey = ${CLIENT_PRIVATE_KEY}
Address = ${WG_CLIENT_IP}/24
DNS = 1.1.1.1, 8.8.8.8

[Peer]
PublicKey = ${SERVER_PUBLIC_KEY}
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = 127.0.0.1:${LOCAL_WG_PORT}
PersistentKeepalive = 25
EOF

    # Gost client service
    cat > "${CLIENT_DIR}/gost-client.service" <<EOF
[Unit]
Description=Gost Client WebSocket Tunnel
After=network.target
Before=wg-quick@wg0.service

[Service]
Type=simple
User=root
ExecStart=$GOST_PATH -L udp://:${LOCAL_WG_PORT} -F relay+ws://${server_ip}:${WS_PORT}
Restart=always
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

    # Client setup script
    cat > "${CLIENT_DIR}/setup-client.sh" <<EOF
#!/bin/bash
set -euo pipefail

if [[ \$EUID -ne 0 ]]; then
    echo "This script must be run as root"
    exit 1
fi

# Install WireGuard
apt-get update
apt-get install -y wireguard resolvconf

# Install gost
if [[ ! -f "$GOST_PATH" ]]; then
    wget -O /tmp/gost.tar.gz "https://github.com/go-gost/gost/releases/download/${GOST_VERSION}/gost_${GOST_VERSION}_linux_amd64.tar.gz"
    tar -xzf /tmp/gost.tar.gz -C /tmp
    mv /tmp/gost "$GOST_PATH"
    chmod +x "$GOST_PATH"
    rm /tmp/gost.tar.gz
fi

# Setup WireGuard
mkdir -p /etc/wireguard
cp wg0.conf /etc/wireguard/
chmod 600 /etc/wireguard/wg0.conf

# Setup gost service
cp gost-client.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable gost-client
systemctl start gost-client
sleep 2

# Start WireGuard
systemctl enable wg-quick@wg0
systemctl start wg-quick@wg0

echo "Client setup complete!"
echo "Testing connection..."
ping -c 3 ${WG_SERVER_IP}
EOF

    chmod +x "${CLIENT_DIR}/setup-client.sh"

    # Create README
    cat > "${CLIENT_DIR}/README.md" <<EOF
# WireGuard over WebSocket Client Setup

## Prerequisites
- Ubuntu/Debian system
- Root access
- Open outbound port ${WS_PORT}

## Installation
1. Copy this entire directory to your client machine
2. Run the setup script:
   \`\`\`bash
   sudo ./setup-client.sh
   \`\`\`

## Verification
- Check WireGuard status: \`sudo wg show\`
- Check gost status: \`sudo systemctl status gost-client\`
- Test connection: \`ping ${WG_SERVER_IP}\`

## Troubleshooting
1. Check logs:
   - WireGuard: \`sudo journalctl -u wg-quick@wg0\`
   - Gost: \`sudo journalctl -u gost-client\`
2. Verify services:
   - \`sudo systemctl status wg-quick@wg0\`
   - \`sudo systemctl status gost-client\`

## Server Details
- Server IP: ${server_ip}
- WebSocket Port: ${WS_PORT}
- WireGuard IP: ${WG_CLIENT_IP}
EOF
}

# Configure system
configure_system() {
    log "Configuring system settings..."
    
    # Enable IP forwarding
    echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-wireguard.conf
    sysctl -p /etc/sysctl.d/99-wireguard.conf
    
    # Configure firewall
    ufw allow ${WS_PORT}/tcp comment 'WireGuard WebSocket'
    ufw allow OpenSSH
    ufw --force enable
}

# Main installation function
install() {
    log "Starting installation..."
    
    check_requirements
    install_dependencies
    install_gost
    
    # Backup existing configuration
    if [[ -d "$WG_CONFIG_DIR" ]]; then
        cp -r "$WG_CONFIG_DIR" "$BACKUP_DIR"
    fi
    
    mkdir -p "$WG_CONFIG_DIR"
    generate_keys
    configure_server
    configure_client
    configure_system
    
    # Start services
    systemctl start gost
    systemctl enable wg-quick@${WG_INTERFACE}
    systemctl start wg-quick@${WG_INTERFACE}
    
    log "${GREEN}Installation completed successfully!${NC}"
    log "${YELLOW}Client configuration package is available at: ${CLIENT_DIR}${NC}"
}

# Uninstall function
uninstall() {
    log "Starting uninstallation..."
    
    # Stop and disable services
    systemctl stop wg-quick@${WG_INTERFACE} 2>/dev/null || true
    systemctl stop gost 2>/dev/null || true
    systemctl disable wg-quick@${WG_INTERFACE} 2>/dev/null || true
    systemctl disable gost 2>/dev/null || true
    
    # Remove configuration and binaries
    rm -rf "$WG_CONFIG_DIR" "$GOST_PATH" "/etc/systemd/system/gost.service"
    
    # Remove packages
    apt-get remove -y wireguard wireguard-tools
    apt-get autoremove -y
    
    # Remove firewall rules
    ufw delete allow ${WS_PORT}/tcp
    
    # Disable IP forwarding
    rm -f /etc/sysctl.d/99-wireguard.conf
    sysctl -p
    
    log "${GREEN}Uninstallation completed successfully!${NC}"
}

# Show status
show_status() {
    echo -e "${BLUE}WireGuard Status:${NC}"
    wg show all
    echo -e "\n${BLUE}Gost Status:${NC}"
    systemctl status gost --no-pager
    echo -e "\n${BLUE}Firewall Status:${NC}"
    ufw status | grep -E "${WG_PORT}|${WS_PORT}"
}

# Main script execution
case "${1:-}" in
    install)
        install
        ;;
    uninstall)
        uninstall
        ;;
    status)
        show_status
        ;;
    *)
        echo "Usage: $0 {install|uninstall|status}"
        exit 1
        ;;
esac
