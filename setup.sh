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
LOCAL_WG_PORT="51821"  # Local port for client-side gost
WG_NETWORK="10.24.10.0/24"
WG_SERVER_IP="10.24.10.1"
CLIENT_IP="10.24.10.12"
WG_DIR="/etc/wireguard"
GOST_BIN="/usr/local/bin/gost"
LOG_FILE="/var/log/wireguard-setup.log"
BACKUP_DIR="/root/wireguard-backup"
CLIENT_DIR="/root/wireguard-client"

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

# Check if gost is already installed
check_gost() {
    if [ -f "$GOST_BIN" ]; then
        log_msg "Gost is already installed" "$YELLOW"
        return 0
    fi
    return 1
}

# Install gost if not present
install_gost() {
    if ! check_gost; then
        log_msg "🔹 Installing gost..."
        wget -O gost.tar.gz "https://github.com/go-gost/gost/releases/download/v3.0.0-nightly.20250207/gost_3.0.0-nightly.20250207_linux_amd64.tar.gz"
        tar -xzf gost.tar.gz
        mv gost $GOST_BIN
        chmod +x $GOST_BIN
        rm gost.tar.gz
    fi
}

# Function to safely set IP forwarding
setup_ip_forwarding() {
    # Remove any existing ip_forward entries
    sed -i '/net.ipv4.ip_forward/d' /etc/sysctl.conf
    # Add new entry
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
    # Apply changes
    sysctl -p
}

# Function to get server IP with fallback
get_server_ip() {
    # Try external IP first, fallback to internal IP
    SERVER_IP=$(curl -s ifconfig.me || hostname -I | awk '{print $1}')
    if [ -z "$SERVER_IP" ]; then
        log_msg "Error: Could not determine server IP" "$RED"
        exit 1
    fi
    echo "$SERVER_IP"
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
    
    # Stop services
    systemctl stop wg-quick@$WG_IFACE 2>/dev/null || true
    systemctl stop gost 2>/dev/null || true
    systemctl disable wg-quick@$WG_IFACE 2>/dev/null || true
    systemctl disable gost 2>/dev/null || true
    
    # Remove packages and cleanup
    apt remove -y wireguard wireguard-tools qrencode
    apt autoremove -y
    
    rm -rf $WG_DIR $GOST_BIN /etc/systemd/system/gost.service
    
    # Remove firewall rules
    ufw delete allow $WG_PORT/udp >/dev/null 2>&1
    ufw delete allow $WS_PORT/tcp >/dev/null 2>&1
    
    # Clean up iptables
    DEFAULT_INTERFACE=$(ip route get 8.8.8.8 | awk '{print $5; exit}')
    iptables -D FORWARD -i $WG_IFACE -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -o $WG_IFACE -j ACCEPT 2>/dev/null || true
    iptables -t nat -D POSTROUTING -o $DEFAULT_INTERFACE -j MASQUERADE 2>/dev/null || true
    
    # Remove interface and disable forwarding
    ip link delete $WG_IFACE 2>/dev/null || true
    sed -i '/net.ipv4.ip_forward=1/d' /etc/sysctl.conf
    sysctl -p >/dev/null 2>&1
    
    systemctl daemon-reload
    
    log_msg "✅ Uninstallation complete" "$GREEN"
}

# Install WireGuard and dependencies
install() {
    if check_wireguard; then
        log_msg "WireGuard is already installed" "$RED"
        log_msg "Use -s to show current configuration or -u to uninstall first"
        exit 1
    fi

    backup_config

    log_msg "🔹 Installing WireGuard and dependencies..."
    apt update && apt install -y wireguard qrencode wget curl ufw

    # Install gost
    install_gost
    
    log_msg "🔹 Generating WireGuard keys..."
    mkdir -p $WG_DIR && cd $WG_DIR
    wg genkey | tee privatekey | wg pubkey > publickey
    SERVER_PRIVATE_KEY=$(cat privatekey)
    SERVER_PUBLIC_KEY=$(cat publickey)
    wg genkey | tee client_privatekey | wg pubkey > client_publickey
    CLIENT_PRIVATE_KEY=$(cat client_privatekey)
    CLIENT_PUBLIC_KEY=$(cat client_publickey)

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
    setup_ip_forwarding

    log_msg "🔹 Configuring firewall..."
    ufw allow $WG_PORT/udp
    ufw allow OpenSSH
    ufw allow $WS_PORT/tcp
    ufw --force enable

    log_msg "🔹 Starting WireGuard..."
    systemctl enable wg-quick@$WG_IFACE
    systemctl start wg-quick@$WG_IFACE

    log_msg "🔹 Creating server gost WebSocket service..."
    cat > /etc/systemd/system/gost.service <<EOF
[Unit]
Description=Gost WebSocket Tunnel
After=network.target

[Service]
ExecStart=$GOST_BIN -L udp://:$WG_PORT -F relay+ws://:$WS_PORT
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable gost
    systemctl restart gost

    # Create client configuration directory
    mkdir -p $CLIENT_DIR

    SERVER_IP=$(get_server_ip)
    
    log_msg "🔹 Generating client configuration..."
    # WireGuard client config
    cat > $CLIENT_DIR/wg0.conf <<EOF
[Interface]
PrivateKey = $CLIENT_PRIVATE_KEY
Address = $CLIENT_IP/24
DNS = 8.8.8.8, 8.8.4.4

[Peer]
PublicKey = $SERVER_PUBLIC_KEY
Endpoint = 127.0.0.1:$LOCAL_WG_PORT
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF

    # Client-side gost service
    cat > $CLIENT_DIR/gost-client.service <<EOF
[Unit]
Description=Gost Client WebSocket Tunnel
After=network.target

[Service]
ExecStart=/usr/local/bin/gost -L udp://:$LOCAL_WG_PORT -F relay+ws://$SERVER_IP:$WS_PORT
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF

    # Client setup script
    cat > $CLIENT_DIR/setup-client.sh <<EOF
#!/bin/bash
# Client setup script

# Check if running as root
if [ "\$EUID" -ne 0 ]; then
    echo "Please run as root"
    exit 1
fi

# Install WireGuard
apt update && apt install -y wireguard

# Install gost if not present
if [ ! -f "/usr/local/bin/gost" ]; then
    wget -O gost.tar.gz "https://github.com/go-gost/gost/releases/download/v3.0.0-nightly.20250207/gost_3.0.0-nightly.20250207_linux_amd64.tar.gz"
    tar -xzf gost.tar.gz
    mv gost /usr/local/bin/
    chmod +x /usr/local/bin/gost
    rm gost.tar.gz
fi

# Create WireGuard directory if it doesn't exist
mkdir -p /etc/wireguard

# Copy configurations
cp wg0.conf /etc/wireguard/
cp gost-client.service /etc/systemd/system/

# Reload systemd and start services
systemctl daemon-reload
systemctl enable gost-client
systemctl start gost-client
systemctl enable wg-quick@wg0
systemctl start wg-quick@wg0

echo "Client setup complete!"
echo "Testing connection..."
ping -c 3 10.24.10.1
EOF

    chmod +x $CLIENT_DIR/setup-client.sh

    # Create a README file
    cat > $CLIENT_DIR/README.txt <<EOF
WireGuard over WebSocket Client Setup Instructions

1. Copy this entire directory to your client machine
2. Run the setup script as root:
   sudo ./setup-client.sh

The script will:
- Install WireGuard and gost
- Set up the WireGuard configuration
- Configure the WebSocket tunnel
- Start all necessary services
- Test the connection

To verify the connection:
- Check WireGuard status: sudo wg show
- Check gost status: systemctl status gost-client
- Test connection: ping 10.24.10.1

Troubleshooting:
1. Check logs:
   - WireGuard: sudo journalctl -u wg-quick@wg0
   - Gost: sudo journalctl -u gost-client
2. Verify services are running:
   - sudo systemctl status wg-quick@wg0
   - sudo systemctl status gost-client
3. Check firewall status:
   - sudo ufw status

Server Details:
Server IP: $SERVER_IP
WebSocket Port: $WS_PORT
WireGuard IP: $CLIENT_IP
EOF

    log_msg "✅ Setup Complete!" "$GREEN"
    log_msg "📁 Client configuration package created at: $CLIENT_DIR" "$GREEN"
    log_msg "📝 Follow the instructions in $CLIENT_DIR/README.txt to set up the client" "$YELLOW"
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
