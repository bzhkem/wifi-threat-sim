# Wi-Fi Threat Simulator

**Purpose:**  
Automate Evil Twin/Rogue APs, deauth attacks, WPA handshake capture, and credential phishing via a captive portal—now with dynamic skin selection, HTTPS mode, and full credential/client logging—for blue-team/red-team **LAB USE ONLY**.

---

## Features

- **Interactive CLI menu** for all attacks and resets
- **Evil Twin AP**: Clone any network (SSID/channel) with custom WPA2 passphrase
- **DHCP/DNS + captive portal** (pick from multiple skins, logs all credentials)
- **Runs the phishing portal in HTTP (port 80) or HTTPS (port 443 with self-signed certs)**
- **Logs client IP, User-Agent, and all POST attempts** (with timestamps in `captured_creds.txt`)
- **Credential submission count & session stats** tracked in `stats.log`
- **After victim submits credentials, they're redirected to a legit website** (default: apple.com)
- **Deauth attack**: disconnects clients from real AP to force reconnection to Evil Twin
- **WPA handshake capture**: saves .cap files for lab cracking
- **Safe teardown/reset**: restores network, kills all helper processes
- **Automatic logs:** WPA handshake files in `logs/`, credentials in `phishing_portal/`, errors in `server_errors.log`

---

## Dependencies

- Linux (Debian/Ubuntu/Kali, Fedora, Arch, ...)
- Essential tools: hostapd, dnsmasq, iw, aircrack-ng, python3, openssl, mitmproxy
- USB WiFi card supporting monitor + AP mode (see below)

**You can now check and install all required dependencies using the built-in installer:  
Simply run the tool and choose `0) Install/check dependencies` from the main menu.**

The installer supports apt (Debian/Ubuntu/Kali), dnf or yum (Fedora/CentOS), pacman (Arch).

---

## Usage

1. **Clone this repo or copy all files** to your lab machine.
2. Make the main script executable:
    ```bash
    chmod +x opt/wifi-threat-sim-main/wifi_threat_sim.sh
    ```
3. Run the tool:
    ```bash
    sudo opt/wifi-threat-sim-main/wifi_threat_sim.sh
    ```
4. Follow the menu options:

    - Install/check dependencies
    - Scan WiFi interfaces & networks
    - Start Rogue AP (Evil Twin)
    - Deauth client(s) from real AP
    - Capture WPA Handshake
    - Choose phishing portal skin
    - Launch Captive Phishing Portal
    - Launch MITMProxy (sniff/intercept)
    - SAFE TEARDOWN/RESET
    - Exit

5. Review creds in `opt/wifi_threat_sim/phishing_portal/captured_creds.txt`, stats in `phishing_portal/stats.log`, and handshake .cap files in `logs/`.

---

## HTTPS Notes

- If you select HTTPS, the portal auto-generates a self-signed cert at first run (browsers will warn about it—expected in labs!).
- HTTPS runs on port 443.

---

## Legal Notice

> **FOR LAB OR AUTHORIZED TEST ENVIRONMENTS ONLY.**  
> Never use these tools on networks you do not own or without explicit written permission.  
> You are responsible for all actions.

---

## Credits

- For research, education, and lab defense/offense simulation.
- Inspired by open-source WiFi & phishing projects, but with an improved modern workflow.

---
