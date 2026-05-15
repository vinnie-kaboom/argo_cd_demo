"""
Simple HTTP app.
BUILD_VERSION, APP_COLOR, and ENVIRONMENT are injected at deploy time.
"""
import json
import os
import socket
from datetime import datetime, timezone
from http.server import HTTPServer, BaseHTTPRequestHandler

VERSION = os.environ.get("BUILD_VERSION", "dev")
APP_COLOR = os.environ.get("APP_COLOR", "blue")
ENVIRONMENT = os.environ.get("ENVIRONMENT", "unknown")
DEMO_BANNER = os.environ.get("DEMO_BANNER", "PIPELINE DEMO")
HOSTNAME = socket.gethostname()


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/healthz":
            self._respond(200, {"status": "ok"})
        elif self.path == "/ui":
            self._respond_html(200, self._ui_html())
        elif self.path == "/":
            self._respond(200, {
                "version": VERSION,
                "color": APP_COLOR,
                "environment": ENVIRONMENT,
                "demoBanner": DEMO_BANNER,
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

    def _respond_html(self, code, body):
        payload = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def _ui_html(self):
        now_utc = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")
        return f"""<!doctype html>
<html lang=\"en\">
<head>
    <meta charset=\"utf-8\">
    <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">
    <meta http-equiv=\"refresh\" content=\"5\">
    <title>my-app pipeline demo</title>
    <style>
        :root {{
            --accent: {APP_COLOR};
            --bg: #0f172a;
            --card: #111827;
            --text: #e5e7eb;
            --muted: #9ca3af;
        }}
        * {{ box-sizing: border-box; }}
        body {{
            margin: 0;
            font-family: ui-monospace, Menlo, Monaco, Consolas, "Liberation Mono", "Courier New", monospace;
            color: var(--text);
            background:
                radial-gradient(circle at 20% 0%, color-mix(in oklab, var(--accent) 30%, transparent), transparent 35%),
                radial-gradient(circle at 90% 90%, color-mix(in oklab, var(--accent) 20%, transparent), transparent 40%),
                var(--bg);
            min-height: 100vh;
            display: grid;
            place-items: center;
            padding: 24px;
        }}
        .panel {{
            width: min(900px, 100%);
            background: linear-gradient(180deg, color-mix(in oklab, var(--card) 92%, var(--accent)), var(--card));
            border: 2px solid color-mix(in oklab, var(--accent) 70%, #334155);
            border-radius: 14px;
            box-shadow: 0 24px 50px rgba(0,0,0,.45);
            overflow: hidden;
        }}
        .banner {{
            padding: 18px 20px;
            font-size: clamp(20px, 4vw, 34px);
            font-weight: 800;
            letter-spacing: .03em;
            text-transform: uppercase;
            background: var(--accent);
            color: #111827;
        }}
        .grid {{
            padding: 20px;
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(220px, 1fr));
            gap: 12px;
        }}
        .cell {{
            background: rgba(2, 6, 23, .5);
            border: 1px solid #334155;
            border-radius: 10px;
            padding: 10px 12px;
        }}
        .k {{ color: var(--muted); font-size: 12px; text-transform: uppercase; letter-spacing: .08em; }}
        .v {{ margin-top: 6px; font-size: 20px; font-weight: 700; word-break: break-word; }}
        .hint {{ padding: 0 20px 20px; color: var(--muted); font-size: 13px; }}
        code {{ color: #93c5fd; }}
    </style>
</head>
<body>
    <section class=\"panel\">
        <div class=\"banner\">{DEMO_BANNER}</div>
        <div class=\"grid\">
            <div class=\"cell\"><div class=\"k\">Environment</div><div class=\"v\">{ENVIRONMENT}</div></div>
            <div class=\"cell\"><div class=\"k\">Version</div><div class=\"v\">{VERSION}</div></div>
            <div class=\"cell\"><div class=\"k\">Color</div><div class=\"v\">{APP_COLOR}</div></div>
            <div class=\"cell\"><div class=\"k\">Pod</div><div class=\"v\">{HOSTNAME}</div></div>
            <div class=\"cell\"><div class=\"k\">Rendered</div><div class=\"v\">{now_utc}</div></div>
        </div>
        <div class=\"hint\">Change <code>config.DEMO_BANNER</code> or <code>config.APP_COLOR</code> in your env values file to demo GitOps visibly.</div>
    </section>
</body>
</html>
"""

    def log_message(self, *_):
        pass


if __name__ == "__main__":
    port = int(os.environ.get("PORT", 8080))
    print(
        f"Starting my-app version={VERSION} color={APP_COLOR} "
        f"env={ENVIRONMENT} demoBanner={DEMO_BANNER} pod={HOSTNAME} on :{port}"
    )
    HTTPServer(("", port), Handler).serve_forever()
