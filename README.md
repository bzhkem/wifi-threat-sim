# Wi-Fi Threat Simulator

**Purpose:**  
Automate Evil Twin/Rogue APs, deauth attacks, WPA handshake capture, and credential phishing via a captive portal, for blue-team/red-team **LAB USE ONLY**.

---

## Features

- **Interactive menu** for all attacks and resets
- **Automatic creation of Evil Twin AP** (custom SSID, channel, passphrase)
- **DHCP/DNS with captive portal phishing page** (with credential logging)
- **Deauth attack**: disconnect clients from real AP to force reconnection to Evil Twin
- **WPA handshake capture**
- **Safe teardown/reset**: restores network, kills all helper processes
- **Logs:** captured handshakes, credentials, logs in `logs/` directory

---

## Dependencies

- **Linux** (Debian/Ubuntu recommended)
- `hostapd`, `dnsmasq`, `iw`, `aircrack-ng` tools (`iw`, `airodump-ng`, `aireplay-ng`)
- A WiFi card with support for monitor + AP mode (e.g. Atheros/Qualcomm, Mediatek, some Realtek)
- `python3`
- Run as **root** (`sudo ./wifi_threat_sim.sh`)

---

## Usage

1. **Clone the repo or copy all files** to your machine.
2. Make the main script executable:
    ```bash
    chmod +x wifi_threat_sim.sh
    ```
3. Run the tool:
    ```bash
    sudo ./wifi_threat_sim.sh
    ```
4. Follow the menu options:
    - Start Rogue AP (Evil Twin)
    - Deauth clients from real AP (to force onto twin)
    - Capture WPA handshake
    - Launch captive portal (phishing page, see captured_creds.txt)
    - Teardown/reset (restores normal networking)

5. Review results in `logs/` and `phishing_portal/`.

---

## Legal Notice

> **FOR LAB OR AUTHORIZED TEST ENVIRONMENTS ONLY.**  
> Running this tool on a network you do not own or without explicit permission is likely illegal and unethical.  
> You are responsible for your use!

---

## Credits

- Created for research, education, and defense/offense training only.
- Captive portal based on Python standard library for maximum portability.
- Inspired by aircrack-ng, OpenWrt Evil Twin docs, and DEFCON WiFi CTF practice.

---
