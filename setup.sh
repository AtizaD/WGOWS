#!/bin/bash
# WireGuard over WebSocket Auto-Setup Script
# Supports Ubuntu/Debian
set -e

# Colors for better readability
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Define variables
WG_IFACE="wg0"
WG_PORT="51820"
WS_PORT="443"
WG_NETWORK="10.24.10.0/24"
WG_SERVER_IP="10.24.10.1"
CLIENT_IP="10.24.10.12"
WG_DIR="/etc/wireguard"
GOST_BIN="/usr/local/bin/gost"
LOG_FILE="/var/log/wireguard-setup.log"
BACKUP_DIR="/root/wireguard-backup"

# Function to print and log messages
log_msg() {
    echo -e "${2:-$BLUE}$1${NC}" | tee -a $LOG_FILE
}

# Function to backup existing configuration
backup_config() {
    if [ -d "$WG_DIR" ]; then
        mkdir -p $BACKUP_DIR
        cp -r $WG_DIR/* $BACKUP_DIR/
        log_msg "📦 Existing configuration backed up to $BACKUP_DIR" "$YELLOW"
    fi
}

# Check root
if [ "$EUID" -ne 0 ]; then
    log_msg "Please run as root" "$RED"
    exit 1
fi

# Check platform compatibility
check_platform() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        case $ID in
            ubuntu|debian)
                log_msg "✓ Platform supported: $ID" "$GREEN"
                ;;
            *)
                log_msg "Error: Unsupported platform: $ID" "$RED"
                exit 1
                ;;
        esac
    else
        log_msg "Error: Cannot determine OS" "$RED"
        exit 1
    fi
}

# Check if WireGuard is installed
check_wireguard() {
    command -v wg >/dev/null 2>&1
}

# Enhanced uninstall function
uninstall() {
    log_msg "🗑️ Starting uninstallation process..." "$YELLOW"
    
    # Backup existing configuration
    backup_config
    
    # Stop services first
    log_msg "Stopping services..."
    systemctl stop wg-quick@$WG_IFACE 2>/dev/null || true
    systemctl stop gost 2>/dev/null || true
    systemctl disable wg-quick@$WG_IFACE 2>/dev/null || true
    systemctl disable gost 2>/dev/null || true
    
    # Remove packages
    log_msg "Removing packages..."
    apt remove -y wireguard wireguard-tools qrencode
    apt autoremove -y
    
    # Clean up directories and files
    log_msg "Cleaning up files..."
    rm -rf $WG_DIR
    rm -f $GOST_BIN
    rm -f /etc/systemd/system/gost.service
    
    # Remove firewall rules
    log_msg "Removing firewall rules..."
    ufw delete allow $WG_PORT/udp >/dev/null 2>&1
    ufw delete allow $WS_PORT/tcp >/dev/null 2>&1
    
    # Get default interface
    DEFAULT_INTERFACE=$(ip route get 8.8.8.8 | awk '{print $5; exit}')
    
    # Clean up iptables rules
    log_msg "Cleaning up iptables rules..."
    iptables -D FORWARD -i $WG_IFACE -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -o $WG_IFACE -j ACCEPT 2>/dev/null || true
    iptables -t nat -D POSTROUTING -o $DEFAULT_INTERFACE -j MASQUERADE 2>/dev/null || true
    iptables -D INPUT -p udp --dport $WG_PORT -j ACCEPT 2>/dev/null || true
    
    # Remove WireGuard interface
    log_msg "Removing network interface..."
    ip link delete $WG_IFACE 2>/dev/null || true
    
    # Disable IP forwarding
    log_msg "Resetting IP forwarding..."
    sed -i '/net.ipv4.ip_forward=1/d' /etc/sysctl.conf
    sysctl -p >/dev/null 2>&1  # Suppress output
    
    # Reload systemd
    systemctl daemon-reload
    
    # Verify cleanup
    if ! command -v wg >/dev/null 2>&1 && ! ip link show $WG_IFACE >/dev/null 2>&1; then
        log_msg "✅ Uninstallation complete. System restored to original state." "$GREEN"
        log_msg "💾 Configuration backup saved in $BACKUP_DIR" "$YELLOW"
    else
        log_msg "⚠️ Some components might still remain. Please check manually." "$RED"
    fi
}

# Install WireGuard and dependencies
install() {
    if check_wireguard; then
        log_msg "WireGuard is already installed" "$RED"
        log_msg "Use -s to show current configuration or -u to uninstall first"
        exit 1
    fi

    # Backup any existing configuration
    backup_config

    log_msg "🔹 Installing WireGuard and dependencies..."
    apt update && apt install -y wireguard qrencode wget curl ufw | tee -a $LOG_FILE

    log_msg "🔹 Installing gost WebSocket tunnel..."
    GOST_VERSION="2.11.5"  # Use a specific stable version
    wget -O gost.tar.gz "https://github.com/go-gost/gost/releases/download/v${GOST_VERSION}/gost_${GOST_VERSION}_linux_amd64.tar.gz"
    tar -xzf gost.tar.gz gost
    mv gost /usr/local/bin/
    chmod +x $GOST_BIN
    rm gost.tar.gz

    log_msg "🔹 Generating WireGuard keys..."
    mkdir -p $WG_DIR && cd $WG_DIR
    wg genkey | tee privatekey | wg pubkey > publickey
    SERVER_PRIVATE_KEY=$(cat privatekey)
    SERVER_PUBLIC_KEY=$(cat publickey)
    wg genkey | tee client_privatekey | wg pubkey > client_publickey
    CLIENT_PRIVATE_KEY=$(cat client_privatekey)
    CLIENT_PUBLIC_KEY=$(cat client_publickey)

    # Detect default network interface
    DEFAULT_INTERFACE=$(ip route get 8.8.8.8 | awk '{print $5; exit}')

    log_msg "🔹 Creating WireGuard server configuration..."
    cat > $WG_DIR/$WG_IFACE.conf <<EOF
[Interface]
PrivateKey = $SERVER_PRIVATE_KEY
Address = $WG_SERVER_IP/24
ListenPort = $WG_PORT
SaveConfig = false
PostUp = iptables -A FORWARD -i %i -j ACCEPT; iptables -A FORWARD -o %i -j ACCEPT; iptables -t nat -A POSTROUTING -o $DEFAULT_INTERFACE -j MASQUERADE
PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -D FORWARD -o %i -j ACCEPT; iptables -t nat -D POSTROUTING -o $DEFAULT_INTERFACE -j MASQUERADE

[Peer]
PublicKey = $CLIENT_PUBLIC_KEY
AllowedIPs = $CLIENT_IP/32
EOF

    log_msg "🔹 Enabling IP forwarding..."
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
    sysctl -p

    log_msg "🔹 Configuring firewall..."
    ufw allow $WG_PORT/udp
    ufw allow OpenSSH
    ufw allow $WS_PORT/tcp
    ufw --force enable

    log_msg "🔹 Starting WireGuard..."
    systemctl enable wg-quick@$WG_IFACE
    systemctl start wg-quick@$WG_IFACE

    log_msg "🔹 Creating gost WebSocket service..."
    cat > /etc/systemd/system/gost.service <<EOF
[Unit]
Description=Gost WebSocket Tunnel
After=network.target

[Service]
ExecStart=$GOST_BIN -L=relay+ws://:$WS_PORT/127.0.0.1:$WG_PORT
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable gost
    systemctl restart gost

    log_msg "🔹 Generating client configuration..."
    SERVER_IP=$(curl -s ifconfig.me)
    cat > $WG_DIR/client.conf <<EOF
[Interface]
PrivateKey = $CLIENT_PRIVATE_KEY
Address = $CLIENT_IP/24
DNS = 8.8.8.8, 8.8.4.4

[Peer]
PublicKey = $SERVER_PUBLIC_KEY
Endpoint = $SERVER_IP:$WS_PORT
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF

    log_msg "✅ Setup Complete!" "$GREEN"
    log_msg "📄 Client configuration: $WG_DIR/client.conf" "$GREEN"
    log_msg "🌐 Server endpoint: $SERVER_IP:$WS_PORT" "$GREEN"
    log_msg "📱 Client Config QR Code:" "$BLUE"
    qrencode -t ansiutf8 < $WG_DIR/client.conf
}

# Enhanced status function
status() {
    if ! check_wireguard; then
        log_msg "WireGuard is not installed" "$RED"
        return 1
    fi

    log_msg "🔒 WireGuard Status:" "$BLUE"
    wg show all
    log_msg "\n🌐 WebSocket Tunnel Status:" "$BLUE"
    systemctl status gost --no-pager
    log_msg "\n🛡️ Firewall Status:" "$BLUE"
    ufw status | grep -E "$WG_PORT|$WS_PORT"
}

# Check platform before any operation
check_platform

# Handle script arguments
case "$1" in
    -i|--install)
        install
        ;;
    -u|--uninstall)
        uninstall
        ;;
    -s|--status)
        status
        ;;
    *)
        echo "Usage: $0 [-i|--install] [-u|--uninstall] [-s|--status]"
        echo "Options:"
        echo "  -i, --install    Install WireGuard with WebSocket support"
        echo "  -u, --uninstall  Uninstall WireGuard and WebSocket tunnel"
        echo "  -s, --status     Show current configuration"
        exit 1
        ;;
esac
