#!/bin/bash

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}[+] Suricata IDS Installation Script${NC}"
echo -e "${GREEN}========================================${NC}"

# Check root privileges
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}[-] Please run as root (sudo)${NC}"
    exit 1
fi

# ============================================
# 0. Fix Repository Issues
# ============================================
echo -e "${YELLOW}[+] Fixing repository issues...${NC}"

# Fix Google Chrome GPG key
if [ -f /etc/apt/sources.list.d/google-chrome.list ] || [ -f /etc/apt/sources.list.d/google.list ]; then
    echo -e "${YELLOW}[+] Fixing Google Chrome GPG key...${NC}"
    wget -q -O - https://dl.google.com/linux/linux_signing_key.pub | apt-key add - 2>/dev/null || \
    curl -fsSL https://dl.google.com/linux/linux_signing_key.pub | gpg --dearmor -o /usr/share/keyrings/google-chrome.gpg 2>/dev/null || true
fi

# Fix Wazuh duplicate entries
if [ -f /etc/apt/sources.list.d/wazuh.list ]; then
    echo -e "${YELLOW}[+] Fixing Wazuh duplicate entries...${NC}"
    sort -u /etc/apt/sources.list.d/wazuh.list > /tmp/wazuh.list
    mv /tmp/wazuh.list /etc/apt/sources.list.d/wazuh.list
fi

# Remove any problematic repository entries
if [ -f /etc/apt/sources.list.d/chrome.list ]; then
    echo -e "${YELLOW}[+] Fixing Chrome repository...${NC}"
    sed -i 's/^deb/#deb/' /etc/apt/sources.list.d/chrome.list 2>/dev/null || true
fi

# Detect OS
if [ -f /etc/debian_version ]; then
    PKG_MANAGER="apt-get"
    INSTALL_CMD="apt-get install -y"
    UPDATE_CMD="apt-get update"
    OS="Debian/Ubuntu"

    echo -e "${YELLOW}[+] Updating package lists with fixes...${NC}"
    $UPDATE_CMD --fix-missing || {
        echo -e "${YELLOW}[!] Update failed, trying with disabled repos...${NC}"
        mkdir -p /tmp/apt-backup
        mv /etc/apt/sources.list.d/*.list /tmp/apt-backup/ 2>/dev/null || true
        $UPDATE_CMD
        mv /tmp/apt-backup/*.list /etc/apt/sources.list.d/ 2>/dev/null || true
    }

elif [ -f /etc/redhat-release ]; then
    PKG_MANAGER="yum"
    INSTALL_CMD="yum install -y"
    UPDATE_CMD="yum update -y"
    OS="RHEL/CentOS"
else
    echo -e "${RED}[-] Unsupported OS. Only Debian/Ubuntu and RHEL/CentOS supported.${NC}"
    exit 1
fi

echo -e "${GREEN}[+] Detected OS: $OS${NC}"

# ============================================
# 1. Install Suricata
# ============================================
echo -e "${YELLOW}[+] Installing Suricata...${NC}"
$INSTALL_CMD suricata || {
    echo -e "${YELLOW}[!] Standard install failed, trying with apt-get fix...${NC}"
    apt-get install -f -y
    $INSTALL_CMD suricata || {
        echo -e "${RED}[-] Suricata installation failed.${NC}"
        echo -e "${YELLOW}[!] Try manual: apt-get install suricata${NC}"
        exit 1
    }
}

# ============================================
# 2. Detect network interface
# ============================================
echo -e "${YELLOW}[+] Detecting network interface...${NC}"
DEFAULT_IFACE=$(ip route | grep default | awk '{print $5}' | head -n1)
if [ -z "$DEFAULT_IFACE" ]; then
    DEFAULT_IFACE=$(ip link | grep -E '^[0-9]+: (eth|ens|enp|wlan)' | head -n1 | cut -d: -f2 | xargs)
fi

if [ -z "$DEFAULT_IFACE" ]; then
    echo -e "${RED}[-] Could not detect network interface.${NC}"
    echo -e "${YELLOW}[!] Available interfaces:${NC}"
    ip link show | grep -E '^[0-9]+:' | cut -d: -f2 | xargs
    echo -e "${YELLOW}[!] Please manually configure interface in /etc/suricata/suricata.yaml${NC}"
    DEFAULT_IFACE="eth0"
fi

echo -e "${GREEN}[+] Using network interface: $DEFAULT_IFACE${NC}"

# ============================================
# 3. Configure Suricata
# ============================================
echo -e "${YELLOW}[+] Configuring Suricata...${NC}"

# Backup original config
if [ ! -f /etc/suricata/suricata.yaml.backup ]; then
    cp /etc/suricata/suricata.yaml /etc/suricata/suricata.yaml.backup
    echo -e "${GREEN}[+] Backup created: /etc/suricata/suricata.yaml.backup${NC}"
fi

# Set interface in config
if grep -q "af-packet:" /etc/suricata/suricata.yaml; then
    sed -i "/af-packet:/,/^$/ s/interface:.*/interface: $DEFAULT_IFACE/" /etc/suricata/suricata.yaml
else
    echo -e "${YELLOW}[!] af-packet not found, using default config${NC}"
fi

# Set HOME_NET
sed -i "s/HOME_NET:.*/HOME_NET: \"[192.168.0.0\/16,10.0.0.0\/8,172.16.0.0\/12]\"/" /etc/suricata/suricata.yaml

# ============================================
# 4. Download and update Suricata rules
# ============================================
echo -e "${YELLOW}[+] Downloading and updating Suricata rules...${NC}"
suricata-update || {
    echo -e "${YELLOW}[!] Rule update failed, trying alternative source...${NC}"
    suricata-update -o /var/lib/suricata/rules
}

# Ensure proper permissions
if [ -d /var/lib/suricata/rules ]; then
    chown -R suricata:suricata /var/lib/suricata/rules 2>/dev/null || true
fi

# ============================================
# 5. Create log directory
# ============================================
mkdir -p /var/log/suricata
chown -R suricata:suricata /var/log/suricata 2>/dev/null || true

# ============================================
# 6. Configure Wazuh agent to read eve.json (NEW)
# ============================================
WAZUH_CONFIG="/var/ossec/etc/ossec.conf"
if [ -f "$WAZUH_CONFIG" ]; then
    echo -e "${YELLOW}[+] Configuring Wazuh agent to read Suricata logs...${NC}"

    # Check if already configured
    if grep -q "/var/log/suricata/eve.json" "$WAZUH_CONFIG"; then
        echo -e "${GREEN}[+] Wazuh already configured for Suricata. Skipping...${NC}"
    else
        # Use heredoc for clean XML injection
        LOCALFILE_BLOCK="  <localfile>
    <log_format>json</log_format>
    <location>/var/log/suricata/eve.json</location>
  </localfile>"

        # Inject before </ossec_config>
        sed -i "/<\/ossec_config>/i ${LOCALFILE_BLOCK}" "$WAZUH_CONFIG"
        echo -e "${GREEN}[+] Wazuh config updated successfully.${NC}"
    fi
else
    echo -e "${YELLOW}[!] Wazuh agent not found. Skipping Wazuh configuration.${NC}"
    echo -e "${YELLOW}[!] To install Wazuh agent: curl -sSL https://packages.wazuh.com/key/GPG-KEY-WAZUH | apt-key add -${NC}"
fi

# ============================================
# 7. Enable and start Suricata as service
# ============================================
echo -e "${YELLOW}[+] Enabling Suricata service...${NC}"

if command -v systemctl &>/dev/null; then
    systemctl enable suricata 2>/dev/null || true
    systemctl start suricata 2>/dev/null || {
        echo -e "${YELLOW}[!] Service start failed, starting manually...${NC}"
        suricata -c /etc/suricata/suricata.yaml -i "$DEFAULT_IFACE" -D
    }
    sleep 2
    if systemctl is-active --quiet suricata 2>/dev/null; then
        echo -e "${GREEN}[+] Suricata service started successfully${NC}"
    else
        echo -e "${YELLOW}[!] Service not active, running in foreground...${NC}"
        suricata -c /etc/suricata/suricata.yaml -i "$DEFAULT_IFACE" -D
    fi
else
    service suricata start || suricata -c /etc/suricata/suricata.yaml -i "$DEFAULT_IFACE" -D
fi

# ============================================
# 8. Verify Suricata is running
# ============================================
sleep 3
if pgrep -x "suricata" > /dev/null; then
    echo -e "${GREEN}[+] Suricata is running!${NC}"
    PID=$(pgrep -x "suricata" | head -1)
    echo -e "${GREEN}[+] PID: $PID${NC}"
else
    echo -e "${RED}[-] Suricata failed to start.${NC}"
    echo -e "${YELLOW}[!] Check logs: tail -f /var/log/suricata/suricata.log${NC}"
    echo -e "${YELLOW}[!] Try manual: suricata -c /etc/suricata/suricata.yaml -i $DEFAULT_IFACE${NC}"
    exit 1
fi

# ============================================
# 9. Create systemd service file (if missing)
# ============================================
if [ ! -f /etc/systemd/system/suricata.service ] && command -v systemctl &>/dev/null; then
    echo -e "${YELLOW}[+] Creating systemd service...${NC}"
    cat > /etc/systemd/system/suricata.service << 'EOF'
[Unit]
Description=Suricata Intrusion Detection System
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/suricata -c /etc/suricata/suricata.yaml -i INTERFACE
ExecReload=/bin/kill -HUP $MAINPID
Restart=always
User=suricata
Group=suricata

[Install]
WantedBy=multi-user.target
EOF
    sed -i "s/INTERFACE/$DEFAULT_IFACE/g" /etc/systemd/system/suricata.service
    systemctl daemon-reload
    systemctl enable suricata 2>/dev/null || true
fi

# ============================================
# 10. Restart Wazuh agent (if installed)
# ============================================
if [ -f "$WAZUH_CONFIG" ]; then
    echo -e "${YELLOW}[+] Restarting Wazuh agent to apply changes...${NC}"
    if command -v systemctl &>/dev/null; then
        systemctl restart wazuh-agent 2>/dev/null || true
    else
        service wazuh-agent restart 2>/dev/null || true
    fi
    echo -e "${GREEN}[+] Wazuh agent restarted.${NC}"
fi

# ============================================
# 11. Show Suricata rules count
# ============================================
RULES_COUNT=$(suricata-update --list-sources 2>/dev/null | grep -c enabled || echo "0")
echo -e "${GREEN}[+] Rules enabled: $RULES_COUNT${NC}"

# ============================================
# 12. Final summary
# ============================================
echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}[+] Installation Complete!${NC}"
echo -e "${GREEN}========================================${NC}"
echo -e "${BLUE}Network Interface:${NC} $DEFAULT_IFACE"
echo -e "${BLUE}Configuration:${NC} /etc/suricata/suricata.yaml"
echo -e "${BLUE}Logs:${NC} /var/log/suricata/"
echo -e "${BLUE}Alerts:${NC} /var/log/suricata/fast.log"
echo -e "${BLUE}EVE JSON:${NC} /var/log/suricata/eve.json"

if [ -f "$WAZUH_CONFIG" ]; then
    echo -e "${BLUE}Wazuh Agent:${NC} Configured to read eve.json ✅"
    echo -e "${BLUE}Wazuh Config:${NC} $WAZUH_CONFIG"
else
    echo -e "${YELLOW}Wazuh Agent:${NC} Not installed (optional)"
fi

echo -e "${BLUE}Rules Enabled:${NC} $RULES_COUNT"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "${YELLOW}Useful Commands:${NC}"
echo -e "  ${GREEN}Check Suricata status:${NC} systemctl status suricata"
echo -e "  ${GREEN}View alerts:${NC} tail -f /var/log/suricata/fast.log"
echo -e "  ${GREEN}View JSON:${NC} tail -f /var/log/suricata/eve.json | jq '.'"
echo -e "  ${GREEN}Update rules:${NC} suricata-update && systemctl restart suricata"
echo -e "  ${GREEN}Test config:${NC} suricata -T -c /etc/suricata/suricata.yaml"

if [ -f "$WAZUH_CONFIG" ]; then
    echo -e "  ${GREEN}Check Wazuh logs:${NC} tail -f /var/ossec/logs/ossec.log"
    echo -e "  ${GREEN}Check Suricata in Wazuh:${NC} grep suricata /var/ossec/logs/alerts/alerts.log"
fi
echo ""
