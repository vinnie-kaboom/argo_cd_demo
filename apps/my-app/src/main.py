"""
Simple HTTP app – replace with your real application.
Version is injected at build time via BUILD_VERSION env var.
"""
import os
from http.server import HTTPServer, BaseHTTPRequestHandler
import json

VERSION = os.environ.get("BUILD_VERSION", "dev")
APP_COLOR = os.environ.get("APP_COLOR", "blue")


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/healthz":
            self._respond(200, {"status": "ok"})
        else:
            self._respond(200, {"version": VERSION, "color": APP_COLOR})

    def _respond(self, code, body):
        payload = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, *_):  # suppress default access log noise
        pass


if __name__ == "__main__":
    port = int(os.environ.get("PORT", 8080))
    print(f"Starting my-app version={VERSION} on :{port}")
    HTTPServer(("", port), Handler).serve_forever()
