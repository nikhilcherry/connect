"""Scan-page server with the same rewrites as vercel.json.

    python3 web/serve.py            # http://127.0.0.1:8093/t/<CODE>
                                    # http://127.0.0.1:8093/trip#<TOKEN>

Serves config.local.js (local Supabase) in place of config.js when it exists.
To point the page at another backend without touching files, set
CONNECT_API_URL (and CONNECT_ANON_KEY): scripts/demo-up.sh does that to put
the page in front of the stack on this machine.

Only the pages themselves are served, never the rest of the folder, so it is
safe behind a public tunnel.
"""
import http.server
import json
import os
import re
import sys

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8093
TAG_PATH = re.compile(r"^/t/[A-Za-z0-9]{8}/?$")
PAGES = {"/": "/index.html", "/index.html": "/index.html", "/trip": "/trip.html", "/trip.html": "/trip.html",
         "/privacy": "/privacy.html", "/privacy.html": "/privacy.html"}
API_URL = os.environ.get("CONNECT_API_URL")
ANON_KEY = os.environ.get("CONNECT_ANON_KEY", "sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH")


class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=os.path.dirname(os.path.abspath(__file__)), **kwargs)

    def do_GET(self):
        path = self.path.split("?", 1)[0].rstrip("/") or "/"
        if TAG_PATH.match(path + "/"):
            self.path = "/index.html"
        elif path in PAGES:
            self.path = PAGES[path]
        elif path == "/config.js" and API_URL:
            body = ("window.CONNECT_CONFIG = " + json.dumps({"supabaseUrl": API_URL, "anonKey": ANON_KEY}) + ";\n").encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/javascript")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-cache")
            self.end_headers()
            self.wfile.write(body)
            return
        elif path == "/config.js":
            # Local stack instead of production; config.local.js is git-ignored.
            local = os.path.exists(os.path.join(self.directory, "config.local.js"))
            self.path = "/config.local.js" if local else "/config.js"
        else:
            self.send_error(404)
            return
        super().do_GET()

    def end_headers(self):
        # The headers vercel.json sets in production.
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("X-Frame-Options", "DENY")
        super().end_headers()


http.server.ThreadingHTTPServer((os.environ.get("BIND", "127.0.0.1"), PORT), Handler).serve_forever()
