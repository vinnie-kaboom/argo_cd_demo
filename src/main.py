"""
Simple HTTP app.
BUILD_VERSION, APP_COLOR, and ENVIRONMENT are injected at deploy time.
"""
import json
import os
import socket
from http.server import HTTPServer, BaseHTTPRequestHandler

VERSION = os.environ.get("BUILD_VERSION", "dev")
APP_COLOR = os.environ.get("APP_COLOR", "blue")
ENVIRONMENT = os.environ.get("ENVIRONMENT", "unknown")
HOSTNAME = socket.gethostname()


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/healthz":
            self._respond(200, {"status": "ok"})
        elif self.path == "/":
            self._respond(200, {
                "version": VERSION,
                "color": APP_COLOR,
                "environment": ENVIRONMENT,
                "pod": HOSTNAME,
            })
        else:
            self._respond(404, {"error": "not found"})

    def _respond(self, code, body):
        payload = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, *_):
        pass


if __name__ == "__main__":
    port = int(os.environ.get("PORT", 8080))
    print(f"Starting my-app version={VERSION} color={APP_COLOR} env={ENVIRONMENT} pod={HOSTNAME} on :{port}")
    HTTPServer(("", port), Handler).serve_forever()
