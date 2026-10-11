"""A tiny local mail server that keeps what it receives, for trying the console's "Email to the authority" without
a real mail account: every message is saved as a .eml file (with its attachments) and summarised on screen.

  python smtp_sink.py                       # listens on 127.0.0.1:2525, saves to ./inbox
  SMTP_HOST=127.0.0.1 SMTP_PORT=2525 SMTP_SECURITY=none SMTP_TO=police@example.org python server.py

Open the saved .eml in any mail program, or unzip its attachment to see the evidence packet. No sign-in, no
encryption: for local testing only. Standard library only.
"""
import argparse
import email
import email.policy
import socketserver
import sys
import threading
from datetime import datetime, timezone
from pathlib import Path


class Handler(socketserver.StreamRequestHandler):
    def reply(self, line):
        self.wfile.write((line + "\r\n").encode())
        self.wfile.flush()

    def handle(self):
        self.reply("220 sink ready")
        sender, rcpts = "", []
        while True:
            raw = self.rfile.readline()
            if not raw:
                return
            line = raw.decode("utf-8", "replace").rstrip("\r\n")
            cmd = line.upper()
            if cmd.startswith(("EHLO", "HELO")):
                self.wfile.write(b"250-sink\r\n250 SIZE 40000000\r\n")
                self.wfile.flush()
            elif cmd.startswith("MAIL FROM"):
                sender, rcpts = line[10:].strip(), []
                self.reply("250 ok")
            elif cmd.startswith("RCPT TO"):
                rcpts.append(line[8:].strip())
                self.reply("250 ok")
            elif cmd == "DATA":
                self.reply("354 end with <CRLF>.<CRLF>")
                chunks = []
                while True:
                    part = self.rfile.readline()
                    if not part or part in (b".\r\n", b".\n"):
                        break
                    chunks.append(part[1:] if part.startswith(b"..") else part)
                self.server.keep(b"".join(chunks), sender, rcpts)
                self.reply("250 queued")
            elif cmd == "RSET":
                sender, rcpts = "", []
                self.reply("250 ok")
            elif cmd == "NOOP":
                self.reply("250 ok")
            elif cmd == "QUIT":
                self.reply("221 bye")
                return
            else:
                self.reply("502 not supported")


class Sink(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True

    def __init__(self, addr, folder):
        super().__init__(addr, Handler)
        self.folder = Path(folder)
        self.folder.mkdir(parents=True, exist_ok=True)
        self.lock = threading.Lock()
        self.count = 0
        self.saved = []

    def keep(self, data, sender, rcpts):
        with self.lock:
            self.count += 1
            name = "%s_%03d.eml" % (datetime.now(timezone.utc).strftime("%Y%m%d_%H%M%S"), self.count)
            (self.folder / name).write_bytes(data)
            self.saved.append(self.folder / name)
        try:
            msg = email.message_from_bytes(data, policy=email.policy.default)
            atts = [p.get_filename() for p in msg.iter_attachments()]
            print("mail %s: from %s to %s | %s | attachments: %s" % (name, sender, ", ".join(rcpts), msg["Subject"], atts or "none"))
        except Exception:
            print("mail %s saved" % name)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=2525)
    ap.add_argument("--folder", default=str(Path(__file__).parent / "inbox"))
    a = ap.parse_args()
    srv = Sink((a.host, a.port), a.folder)
    print("Mail sink on %s:%d, saving to %s (Ctrl+C to stop)" % (a.host, a.port, a.folder))
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
