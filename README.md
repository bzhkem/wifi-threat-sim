# Wi-Fi Threat Simulator

**Purpose:**  
Automate Evil Twin/Rogue AP, deauth, WPA handshake capture, and credential phishing via captive portal for blue-team/red-team LAB USE ONLY.

---

## Prerequisites
- Linux, with `hostapd`, `dnsmasq`, `iw`, `aircrack-ng` suite, and `python3`
- Supported WiFi card/driver for monitor + AP mode (Atheros, Mediatek, etc)
- Run as **root** (`sudo ./wifi_threat_sim.sh`)

---

## Features

- Menu-driven: Start Evil Twin, deauth attacks, WPA handshake capture, launch credential-capturing phishing portal
- Safe teardown: restores network, kills AP & DHCP processes
- All logs, creds, handshakes saved to `logs/`.

---

## Usage

1. Place all files in the same project directory.
2. Run:
   ```bash
   sudo ./wifi_threat_sim.sh
