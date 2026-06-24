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
# 1.5. CREATE CONFIG FILE FIRST (FIXED)
# ============================================
echo -e "${YELLOW}[+] Creating Suricata configuration file...${NC}"

# Create directory if missing
mkdir -p /etc/suricata
mkdir -p /var/lib/suricata/rules
mkdir -p /var/log/suricata

# Create suricata.yaml from scratch (FIXED)
echo -e "${YELLOW}[+] Generating suricata.yaml...${NC}"
cat > /etc/suricata/suricata.yaml << 'EOF'
%YAML 1.1
---

# Suricata configuration file

# Network interface - will be updated by script
af-packet:
  - interface: INTERFACE_PLACEHOLDER
    cluster-id: 99
    cluster-type: cluster_flow
    defrag: yes
    use-mmap: yes
    tpacket-v3: yes
    # For better performance
    ring-size: 4096
    block-size: 32768

# Variables
vars:
  HOME_NET: "[192.168.0.0/16,10.0.0.0/8,172.16.0.0/12]"
  EXTERNAL_NET: "!$HOME_NET"

# Logging
default-log-dir: /var/log/suricata/

# Global stats
stats:
  enabled: yes
  interval: 60

# Outputs
outputs:
  - fast:
      enabled: yes
      filename: fast.log
      append: yes
  - eve-log:
      enabled: yes
      filetype: regular
      filename: eve.json
      types:
        - alert
        - http:
            extended: yes
        - dns
        - tls
        - ssh
        - smtp
        - ftp
        - files
  - stats:
      enabled: yes
      filename: stats.log
      interval: 60

# Rules
default-rule-path: /var/lib/suricata/rules
rule-files:
  - suricata.rules

# Performance
runmode: workers
max-pending-packets: 4096

# Detection engine
detect:
  profile: medium
  custom-values:
    toserver-groups: 3
    toclient-groups: 3
  sgh-mpm-context: auto
  inspection-recursion-limit: 3000

# Memory
flow:
  memcap: 128mb
  hash-size: 65536
  prealloc: 10000
  emergency-recovery: 30

# Stream engine
stream:
  memcap: 64mb
  prealloc-sessions: 32768
  checksum-validation: yes
  inline: auto
  reassembly:
    memcap: 256mb
    depth: 1mb
    toserver-chunk-size: 2560
    toclient-chunk-size: 2560
    randomize-chunk-size: yes

# App layer protocols
app-layer:
  protocols:
    http:
      enabled: yes
      memcap: 64mb
      libhtp:
        default-config:
          personality: IDS
          request-body-limit: 3072
          response-body-limit: 3072
    dns:
      enabled: yes
      memcap: 16mb
    tls:
      enabled: yes
      memcap: 32mb

# Threshold config
threshold-file: /etc/suricata/threshold.config
EOF

# Create threshold.config
echo -e "${YELLOW}[+] Creating threshold.config...${NC}"
cat > /etc/suricata/threshold.config << 'EOF'
# Suricata threshold.config
# This file is used to configure thresholding for alerts

# Suppress specific alerts (example)
# suppress gen_id 1, sig_id 1234, track by_src, ip 192.168.1.1
# suppress gen_id 1, sig_id 1234, track by_dst, ip 192.168.1.1

# Threshold rules (example)
# threshold gen_id 1, sig_id 1234, type limit, track by_src, count 1, seconds 60
EOF

# Set proper permissions
chown -R suricata:suricata /etc/suricata 2>/dev/null || true
chown -R suricata:suricata /var/lib/suricata 2>/dev/null || true
chown -R suricata:suricata /var/log/suricata 2>/dev/null || true

echo -e "${GREEN}[+] Configuration files created successfully.${NC}"

# ============================================
# 2. Detect network interface
# ============================================
echo -e "${YELLOW}[+] Detecting network interface...${NC}"
DEFAULT_IFACE=$(ip route | grep default | awk '{print $5}' | head -n1)
if [ -z "$DEFAULT_IFACE" ]; then
    DEFAULT_IFACE=$(ip link | grep -E '^[0-9]+: (eth|ens|enp|wlan)' | grep -v lo | head -n1 | cut -d: -f2 | xargs)
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
# 3. Update interface in config
# ============================================
echo -e "${YELLOW}[+] Setting interface in config...${NC}"

# Replace placeholder with actual interface
sed -i "s/INTERFACE_PLACEHOLDER/$DEFAULT_IFACE/g" /etc/suricata/suricata.yaml

# Also update if interface already exists
if grep -q "interface:" /etc/suricata/suricata.yaml; then
    sed -i "s/interface:.*/interface: $DEFAULT_IFACE/" /etc/suricata/suricata.yaml
fi

echo -e "${GREEN}[+] Interface set to: $DEFAULT_IFACE${NC}"

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
# 5. Test configuration
# ============================================
echo -e "${YELLOW}[+] Testing Suricata configuration...${NC}"
if suricata -T -c /etc/suricata/suricata.yaml 2>/dev/null; then
    echo -e "${GREEN}[+] Configuration test passed!${NC}"
else
    echo -e "${YELLOW}[!] Configuration test failed. Please check manually.${NC}"
    echo -e "${YELLOW}[!] Run: suricata -T -c /etc/suricata/suricata.yaml${NC}"
fi

# ============================================
# 6. Configure Wazuh (if installed)
# ============================================
WAZUH_CONFIG="/var/ossec/etc/ossec.conf"
if [ -f "$WAZUH_CONFIG" ]; then
    echo -e "${YELLOW}[+] Configuring Wazuh agent...${NC}"
    
    if grep -q "/var/log/suricata/eve.json" "$WAZUH_CONFIG"; then
        echo -e "${GREEN}[+] Wazuh already configured for Suricata.${NC}"
    else
        LOCALFILE_BLOCK="  <localfile>
    <log_format>json</log_format>
    <location>/var/log/suricata/eve.json</location>
  </localfile>"
        
        sed -i "/<\/ossec_config>/i ${LOCALFILE_BLOCK}" "$WAZUH_CONFIG"
        echo -e "${GREEN}[+] Wazuh config updated.${NC}"
    fi
else
    echo -e "${YELLOW}[!] Wazuh agent not found. Skipping Wazuh config.${NC}"
fi

# ============================================
# 7. Start Suricata
# ============================================
echo -e "${YELLOW}[+] Starting Suricata...${NC}"

# Try to start via systemctl
if command -v systemctl &>/dev/null; then
    systemctl enable suricata 2>/dev/null || true
    if ! systemctl start suricata 2>/dev/null; then
        echo -e "${YELLOW}[!] Service start failed, starting manually...${NC}"
        suricata -c /etc/suricata/suricata.yaml -i "$DEFAULT_IFACE" -D
    fi
else
    service suricata start || suricata -c /etc/suricata/suricata.yaml -i "$DEFAULT_IFACE" -D
fi

sleep 3

# ============================================
# 8. Verify Suricata
# ============================================
if pgrep -x "suricata" > /dev/null; then
    echo -e "${GREEN}[+] Suricata is running! PID: $(pgrep -x suricata | head -1)${NC}"
else
    echo -e "${YELLOW}[!] Suricata not running. Starting in foreground...${NC}"
    suricata -c /etc/suricata/suricata.yaml -i "$DEFAULT_IFACE" -D
    sleep 2
    if pgrep -x "suricata" > /dev/null; then
        echo -e "${GREEN}[+] Suricata started!${NC}"
    else
        echo -e "${RED}[-] Suricata failed to start.${NC}"
        echo -e "${YELLOW}[!] Check logs: tail -f /var/log/suricata/suricata.log${NC}"
    fi
fi

# ============================================
# 9. Restart Wazuh (if installed)
# ============================================
if [ -f "$WAZUH_CONFIG" ]; then
    echo -e "${YELLOW}[+] Restarting Wazuh agent...${NC}"
    systemctl restart wazuh-agent 2>/dev/null || service wazuh-agent restart 2>/dev/null || true
    echo -e "${GREEN}[+] Wazuh agent restarted.${NC}"
fi

# ============================================
# 10. Final Summary
# ============================================
RULES_COUNT=$(suricata-update --list-sources 2>/dev/null | grep -c enabled || echo "0")

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}[+] Installation Complete!${NC}"
echo -e "${GREEN}========================================${NC}"
echo -e "${BLUE}Network Interface:${NC} $DEFAULT_IFACE"
echo -e "${BLUE}Configuration:${NC} /etc/suricata/suricata.yaml"
echo -e "${BLUE}Logs:${NC} /var/log/suricata/"
echo -e "${BLUE}Alerts:${NC} /var/log/suricata/fast.log"
echo -e "${BLUE}EVE JSON:${NC} /var/log/suricata/eve.json"
echo -e "${BLUE}Rules Enabled:${NC} $RULES_COUNT"

if [ -f "$WAZUH_CONFIG" ]; then
    echo -e "${BLUE}Wazuh Agent:${NC} Configured ✅"
fi

echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "${YELLOW}Useful Commands:${NC}"
echo -e "  ${GREEN}Check status:${NC} systemctl status suricata"
echo -e "  ${GREEN}View alerts:${NC} tail -f /var/log/suricata/fast.log"
echo -e "  ${GREEN}View JSON:${NC} tail -f /var/log/suricata/eve.json | jq '.'"
echo -e "  ${GREEN}Update rules:${NC} suricata-update && systemctl restart suricata"
echo -e "  ${GREEN}Test config:${NC} suricata -T -c /etc/suricata/suricata.yaml"
echo ""
