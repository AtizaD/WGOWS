# WireGuard over WebSocket Setup Script 🔒

Automated setup script for WireGuard VPN with WebSocket tunneling support for enhanced compatibility and bypass capabilities. Works on Ubuntu/Debian systems.

## 🚀 Quick Install

One-command installation:
```bash
curl -O https://raw.githubusercontent.com/AtizaD/WGOWS/main/setup.sh && chmod +x setup.sh && sudo ./setup.sh -i
```

## ✨ Features

- 🔧 One-command installation
- 🌐 WebSocket tunneling (port 443)
- 🔄 Auto-detection of network interface
- 🖥️ Platform compatibility checking
- 📱 QR code generation for mobile clients
- 🔍 Configuration status viewer
- 🗑️ Clean uninstallation option
- 📝 Installation logging
- 🛡️ UFW firewall configuration
- 🔌 Automatic service management
- 🌍 Domain support

## 🛠️ Requirements

- Ubuntu or Debian based system
- Root privileges
- Active internet connection

## 📋 Usage

```bash
# Install WireGuard with WebSocket support
sudo ./setup.sh -i

# Show current configuration status
sudo ./setup.sh -s

# Uninstall everything
sudo ./setup.sh -u
```

## ⚙️ Configuration Details

Default settings (can be modified in the script):
```plaintext
WireGuard Interface: wg0
WireGuard Port: 51820
WebSocket Port: 443 (HTTPS)
VPN Network: 10.24.10.0/24
Server IP: 10.24.10.1
Client IP: 10.24.10.12
Log File: /var/log/wireguard-setup.log
```

## 🌐 WebSocket Features

This script sets up WireGuard with a WebSocket tunnel using gost, which provides:
- Better compatibility with restrictive networks
- Ability to run on standard HTTPS port (443)
- Improved bypass capabilities
- WebSocket encapsulation of VPN traffic

## 📱 Client Setup

After installation:
1. Server displays QR code for mobile clients
2. Client configuration saved at: `/etc/wireguard/client.conf`
3. Use any WireGuard client with WebSocket support

## 🔒 Security Features

- Automatic key generation and management
- UFW firewall configuration
- Secure WebSocket tunnel
- IP forwarding configuration
- NAT masquerading
- Strict peer configuration

## 📊 Monitoring

Check the status of your VPN:
```bash
sudo ./setup.sh -s
```

This shows:
- WireGuard connection status
- WebSocket tunnel status
- Connected peers
- Transfer statistics

## 📝 Logging

All installation steps are logged to:
```bash
/var/log/wireguard-setup.log
```

## ⚠️ Important Notes

- Run script with root privileges
- Backup any existing WireGuard configurations before installing
- Default WebSocket port (443) can be changed in the script
- Script supports only Debian/Ubuntu systems
- If using a domain, set the DOMAIN variable in the script

## 🔧 Troubleshooting

Common issues:
1. Check service status:
   ```bash
   systemctl status wg-quick@wg0
   systemctl status gost
   ```

2. View logs:
   ```bash
   tail -f /var/log/wireguard-setup.log
   journalctl -u wg-quick@wg0
   journalctl -u gost
   ```

3. Check firewall status:
   ```bash
   ufw status
   ```

## 📜 License

This project is licensed under the MIT License - see the LICENSE file for details.

## 🤝 Contributing

Contributions, issues, and feature requests are welcome! Feel free to check [issues page](https://github.com/AtizaD/wireguard/issues).

---
Remember to star ⭐ this repository if you find it helpful!
