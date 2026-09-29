"""Local scan-page server with the same rewrites as vercel.json.

    python3 web/serve.py            # http://127.0.0.1:8093/t/<CODE>
                                    # http://127.0.0.1:8093/trip#<TOKEN>

Serves config.local.js (local Supabase) in place of config.js when it exists.
"""
import http.server
import os
import re
import sys

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8093
TAG_PATH = re.compile(r"^/t/[A-Za-z0-9]{8}/?$")


class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=os.path.dirname(os.path.abspath(__file__)), **kwargs)

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if TAG_PATH.match(path):
            self.path = "/index.html"
        elif path in ("/trip", "/trip/"):
            self.path = "/trip.html"  # vercel.json's cleanUrls
        elif path == "/config.js" and os.path.exists(os.path.join(self.directory, "config.local.js")):
            # Local stack instead of production; config.local.js is git-ignored.
            self.path = "/config.local.js"
        super().do_GET()


http.server.ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
