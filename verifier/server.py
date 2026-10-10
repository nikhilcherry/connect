"""Verification console for violation reports.

Sits between the phone app and the authority that issues challans. It does not issue challans and is not
a government system: it makes a report trustworthy and easy to act on.

  * receives the app's multipart report (same fields the app sends to its webhook)
  * fingerprints every photo (SHA-256) and signs the whole record, so later tampering is detectable
  * flags probable duplicates (same plate and violation within minutes)
  * lets a reviewer approve or reject, correct the plate, and leave a note; every action is logged
  * exports an evidence packet (zip: manifest, photos, printable page) and can email it to an authority

Standard library only. Run:  python server.py   (see README.md)
"""
import base64
import email
import email.policy
import hashlib
import hmac
import html
import io
import json
import os
import re
import secrets
import smtplib
import sqlite3
import sys
import threading
import time
import zipfile
from datetime import datetime, timedelta, timezone
from email.message import EmailMessage
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, quote, urlparse

MAX_BODY = 30 * 1024 * 1024
MAX_FILE = 10 * 1024 * 1024
FILE_PARTS = {"frame": "frame.jpg", "plate": "plate.jpg", "vehicle": "vehicle.jpg"}
VIOLATIONS = {"triple_riding": "Triple riding", "no_helmet": "Rider without helmet"}
DUP_WINDOW = timedelta(minutes=10)


def now_iso():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def norm_plate(p):
    return re.sub(r"[^A-Z0-9]", "", (p or "").upper())


class Config:
    def __init__(self, data_dir, secret, user, password, api_key="", smtp=None, send_mail=None):
        self.data_dir = Path(data_dir)
        self.secret = secret
        self.user = user
        self.password = password
        self.api_key = api_key
        self.smtp = smtp or {}
        self.send_mail = send_mail or self._smtp_send

    def _smtp_send(self, msg):
        s = self.smtp
        if not s.get("host") or not s.get("to"):
            raise RuntimeError("SMTP is not configured (set SMTP_HOST and SMTP_TO)")
        with smtplib.SMTP(s["host"], int(s.get("port", 587)), timeout=30) as c:
            if s.get("starttls", True):
                c.starttls()
            if s.get("user"):
                c.login(s["user"], s.get("password", ""))
            c.send_message(msg)


class Store:
    def __init__(self, cfg):
        self.cfg = cfg
        self.files_dir = cfg.data_dir / "files"
        self.files_dir.mkdir(parents=True, exist_ok=True)
        self.lock = threading.Lock()
        self.db = sqlite3.connect(str(cfg.data_dir / "reports.db"), check_same_thread=False)
        self.db.row_factory = sqlite3.Row
        self.db.executescript(
            """
            CREATE TABLE IF NOT EXISTS reports (
              id TEXT PRIMARY KEY, event_id TEXT NOT NULL, received_at TEXT NOT NULL,
              violation TEXT NOT NULL, ts TEXT NOT NULL, lat REAL NOT NULL, lon REAL NOT NULL,
              plate_number TEXT NOT NULL, plate_clear INTEGER NOT NULL, plate_hires INTEGER NOT NULL,
              note TEXT NOT NULL, source TEXT NOT NULL,
              files_json TEXT NOT NULL, receipt_sig TEXT NOT NULL,
              status TEXT NOT NULL DEFAULT 'pending', reviewer TEXT, review_note TEXT, reviewed_at TEXT,
              plate_final TEXT, dup_of TEXT, forwarded_at TEXT,
              UNIQUE (event_id, ts)
            );
            CREATE TABLE IF NOT EXISTS audit (
              n INTEGER PRIMARY KEY AUTOINCREMENT, at TEXT NOT NULL, actor TEXT NOT NULL,
              action TEXT NOT NULL, report_id TEXT, detail TEXT
            );
            """
        )

    def close(self):
        self.db.close()

    # -- helpers ------------------------------------------------------------------------------
    def audit(self, actor, action, report_id=None, detail=""):
        self.db.execute("INSERT INTO audit (at, actor, action, report_id, detail) VALUES (?,?,?,?,?)",
                        (now_iso(), actor, action, report_id, detail))
        self.db.commit()

    def canonical(self, r, hashes):
        return json.dumps(
            {"id": r["id"], "event_id": r["event_id"], "received_at": r["received_at"], "violation": r["violation"],
             "ts": r["ts"], "lat": r["lat"], "lon": r["lon"], "plate_number": r["plate_number"], "files": hashes},
            sort_keys=True, separators=(",", ":"))

    def sign(self, canonical):
        return hmac.new(self.cfg.secret.encode(), canonical.encode(), hashlib.sha256).hexdigest()

    # -- ingestion ----------------------------------------------------------------------------
    def ingest(self, fields, files):
        """Returns (status_code, body_dict)."""
        violation = fields.get("violation", "")
        if violation not in VIOLATIONS:
            return 400, {"error": "violation must be triple_riding or no_helmet"}
        try:
            lat, lon = float(fields["latitude"]), float(fields["longitude"])
            if not (-90 <= lat <= 90 and -180 <= lon <= 180):
                raise ValueError
        except (KeyError, ValueError):
            return 400, {"error": "latitude and longitude are required and must be valid"}
        ts = fields.get("timestamp", "")
        try:
            datetime.fromisoformat(ts.replace("Z", "+00:00"))
        except ValueError:
            return 400, {"error": "timestamp must be ISO 8601"}
        event_id = fields.get("event_id", "")[:80]
        if not event_id:
            return 400, {"error": "event_id is required"}
        if "frame" not in files:
            return 400, {"error": "the frame photo is required"}
        for name, data in files.items():
            if not data.startswith(b"\xff\xd8"):
                return 400, {"error": f"{name} is not a JPEG"}
            if len(data) > MAX_FILE:
                return 400, {"error": f"{name} is too large"}

        with self.lock:
            same = self.db.execute("SELECT id FROM reports WHERE event_id=? AND ts=?", (event_id, ts)).fetchone()
            if same:  # the app retried: idempotent
                return 200, {"id": same["id"], "duplicate_submission": True}
            rid = "R-%s-%s" % (datetime.now(timezone.utc).strftime("%Y%m%d"), secrets.token_hex(3).upper())
            folder = self.files_dir / rid
            folder.mkdir(parents=True)
            hashes = {}
            for part, name in FILE_PARTS.items():
                if part in files:
                    (folder / name).write_bytes(files[part])
                    hashes[name] = hashlib.sha256(files[part]).hexdigest()
            plate = fields.get("plate_number", "")[:20]
            row = {
                "id": rid, "event_id": event_id, "received_at": now_iso(), "violation": violation, "ts": ts,
                "lat": lat, "lon": lon, "plate_number": plate,
            }
            sig = self.sign(self.canonical(row, hashes))
            dup = None
            if norm_plate(plate):
                t = datetime.fromisoformat(ts.replace("Z", "+00:00"))
                for o in self.db.execute("SELECT id, ts, plate_number, plate_final FROM reports WHERE violation=?", (violation,)):
                    if norm_plate(o["plate_final"] or o["plate_number"]) == norm_plate(plate):
                        try:
                            ot = datetime.fromisoformat(o["ts"].replace("Z", "+00:00"))
                        except ValueError:
                            continue
                        if abs(t - ot) <= DUP_WINDOW:
                            dup = o["id"]
                            break
            self.db.execute(
                "INSERT INTO reports (id,event_id,received_at,violation,ts,lat,lon,plate_number,plate_clear,plate_hires,"
                "note,source,files_json,receipt_sig,dup_of) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                (rid, event_id, row["received_at"], violation, ts, lat, lon, plate,
                 1 if fields.get("plate_clear") == "true" else 0, 1 if fields.get("plate_hires") == "true" else 0,
                 fields.get("note", "")[:500], fields.get("source", "")[:60], json.dumps(hashes), sig, dup))
            self.db.commit()
            self.audit("system", "received", rid, "possible duplicate of %s" % dup if dup else "")
        return 201, {"id": rid, "receipt": sig, "possible_duplicate_of": dup}

    # -- reads --------------------------------------------------------------------------------
    def get(self, rid):
        with self.lock:
            return self.db.execute("SELECT * FROM reports WHERE id=?", (rid,)).fetchone()

    def list(self, status=None):
        with self.lock:
            if status in ("pending", "approved", "rejected"):
                return self.db.execute("SELECT * FROM reports WHERE status=? ORDER BY received_at DESC", (status,)).fetchall()
            return self.db.execute("SELECT * FROM reports ORDER BY received_at DESC").fetchall()

    def counts(self):
        with self.lock:
            c = {"pending": 0, "approved": 0, "rejected": 0}
            for r in self.db.execute("SELECT status, COUNT(*) n FROM reports GROUP BY status"):
                c[r["status"]] = r["n"]
            return c

    def audit_for(self, rid):
        with self.lock:
            return self.db.execute("SELECT * FROM audit WHERE report_id=? ORDER BY n", (rid,)).fetchall()

    def verify(self, rid):
        """Recompute the file hashes and the signature from what is on disk now."""
        r = self.get(rid)
        if not r:
            return None
        stored = json.loads(r["files_json"])
        current, problems = {}, []
        for name, h in stored.items():
            p = self.files_dir / rid / name
            if not p.exists():
                problems.append(f"{name} is missing")
                continue
            current[name] = hashlib.sha256(p.read_bytes()).hexdigest()
            if current[name] != h:
                problems.append(f"{name} has changed since it was received")
        ok_sig = hmac.compare_digest(self.sign(self.canonical(r, current if not problems else stored)), r["receipt_sig"])
        if not ok_sig:
            problems.append("the signed record does not match")
        return {"id": rid, "intact": not problems, "problems": problems, "files": stored, "receipt": r["receipt_sig"]}

    # -- review -------------------------------------------------------------------------------
    def review(self, rid, actor, decision, note, plate_final):
        if decision not in ("approved", "rejected"):
            return False, "decision must be approved or rejected"
        with self.lock:
            r = self.db.execute("SELECT status FROM reports WHERE id=?", (rid,)).fetchone()
            if not r:
                return False, "no such report"
            self.db.execute(
                "UPDATE reports SET status=?, reviewer=?, review_note=?, reviewed_at=?, plate_final=? WHERE id=?",
                (decision, actor, note[:1000], now_iso(), (plate_final or "")[:20] or None, rid))
            self.db.commit()
            self.audit(actor, decision, rid, note[:200])
        return True, ""

    # -- packet and forwarding ----------------------------------------------------------------
    def packet(self, rid):
        r = self.get(rid)
        if not r:
            return None
        v = self.verify(rid)
        manifest = {
            "report_id": r["id"], "violation": r["violation"], "violation_label": VIOLATIONS[r["violation"]],
            "occurred_at_utc": r["ts"], "received_at_utc": r["received_at"],
            "location": {"latitude": r["lat"], "longitude": r["lon"],
                         "map": "https://maps.google.com/?q=%s,%s" % (r["lat"], r["lon"])},
            "plate_as_read_by_app": r["plate_number"], "plate_confirmed_by_reviewer": r["plate_final"],
            "plate_read_clear": bool(r["plate_clear"]), "app_note": r["note"],
            "review": {"status": r["status"], "reviewer": r["reviewer"], "note": r["review_note"], "at": r["reviewed_at"]},
            "integrity": {"files_sha256": v["files"], "signature_hmac_sha256": v["receipt"], "intact_at_export": v["intact"]},
            "notice": "A report assembled from a citizen's phone and checked by a reviewer. It is not a challan and "
                      "does not itself establish an offence; the competent authority decides.",
        }
        buf = io.BytesIO()
        with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z:
            z.writestr("manifest.json", json.dumps(manifest, indent=2))
            imgs = ""
            for name in v["files"]:
                data = (self.files_dir / rid / name).read_bytes()
                z.writestr(name, data)
                imgs += '<figure><img src="data:image/jpeg;base64,%s"><figcaption>%s</figcaption></figure>' % (
                    base64.b64encode(data).decode(), html.escape(name))
            z.writestr("packet.html", self._packet_html(manifest, imgs))
        return buf.getvalue(), manifest

    def _packet_html(self, m, imgs):
        e = html.escape
        plate = m["plate_confirmed_by_reviewer"] or m["plate_as_read_by_app"] or "not read"
        return (
            "<!doctype html><meta charset=utf-8><title>Evidence packet %s</title>"
            "<style>body{font:15px/1.5 system-ui,sans-serif;max-width:820px;margin:24px auto;padding:0 16px}"
            "img{max-width:100%%;border:1px solid #ccc}figure{margin:12px 0}code{word-break:break-all;font-size:12px}"
            "td{padding:4px 12px 4px 0;vertical-align:top}</style><h1>Evidence packet %s</h1>"
            "<p><b>%s</b></p><table>"
            "<tr><td>Occurred (UTC)</td><td>%s</td></tr><tr><td>Location</td><td>%s, %s &middot; <a href='%s'>map</a></td></tr>"
            "<tr><td>Plate</td><td>%s</td></tr><tr><td>Review</td><td>%s by %s &mdash; %s</td></tr>"
            "<tr><td>Signature</td><td><code>%s</code></td></tr></table>%s"
            "<h3>Fingerprints (SHA-256)</h3><ul>%s</ul><p><i>%s</i></p>"
            % (e(m["report_id"]), e(m["report_id"]), e(m["violation_label"]), e(m["occurred_at_utc"]),
               m["location"]["latitude"], m["location"]["longitude"], e(m["location"]["map"]), e(plate),
               e(m["review"]["status"] or ""), e(m["review"]["reviewer"] or "-"), e(m["review"]["note"] or ""),
               e(m["integrity"]["signature_hmac_sha256"]), imgs,
               "".join("<li>%s <code>%s</code></li>" % (e(k), e(v)) for k, v in m["integrity"]["files_sha256"].items()),
               e(m["notice"])))

    def forward(self, rid, actor):
        r = self.get(rid)
        if not r or r["status"] != "approved":
            return False, "only an approved report can be forwarded"
        data, m = self.packet(rid)
        msg = EmailMessage()
        msg["Subject"] = "Traffic violation report %s: %s" % (rid, VIOLATIONS[r["violation"]])
        msg["From"] = self.cfg.smtp.get("from", "verifier@localhost")
        msg["To"] = self.cfg.smtp.get("to", "")
        msg.set_content(
            "Violation: %s\nWhen (UTC): %s\nWhere: %s\nPlate: %s\n\nThe attached packet has the photos, their "
            "fingerprints and the reviewer's decision. This is a report for your review, not a challan."
            % (VIOLATIONS[r["violation"]], r["ts"], m["location"]["map"], r["plate_final"] or r["plate_number"] or "not read"))
        msg.add_attachment(data, maintype="application", subtype="zip", filename="%s.zip" % rid)
        try:
            self.cfg.send_mail(msg)
        except Exception as ex:  # report the cause, never claim it was sent
            self.audit(actor, "forward_failed", rid, str(ex)[:200])
            return False, str(ex)
        with self.lock:
            self.db.execute("UPDATE reports SET forwarded_at=? WHERE id=?", (now_iso(), rid))
            self.db.commit()
            self.audit(actor, "forwarded", rid, msg["To"])
        return True, ""

    def purge(self, days):
        cutoff = (datetime.now(timezone.utc) - timedelta(days=days)).strftime("%Y-%m-%dT%H:%M:%SZ")
        n = 0
        with self.lock:
            for r in self.db.execute("SELECT id FROM reports WHERE received_at < ?", (cutoff,)).fetchall():
                for f in (self.files_dir / r["id"]).glob("*"):
                    f.unlink()
                (self.files_dir / r["id"]).rmdir()
                self.db.execute("DELETE FROM reports WHERE id=?", (r["id"],))
                self.audit("system", "purged", r["id"], "older than %d days" % days)
                n += 1
            self.db.commit()
        return n


# ---- HTML ----------------------------------------------------------------------------------------

CSS = """
:root{--bg:#f4f3fa;--card:#fff;--ink:#1b1740;--mut:#6b6890;--line:#e2e0f0;--pri:#5b46c8;--ok:#14803c;--bad:#b3261e}
@media(prefers-color-scheme:dark){:root{--bg:#14122a;--card:#1d1a3a;--ink:#ecebff;--mut:#a09dc8;--line:#33305a;--pri:#8d7bff;--ok:#4cc27a;--bad:#ff8a80}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--ink);font:15px/1.5 system-ui,sans-serif}
main{max-width:980px;margin:0 auto;padding:20px 16px 48px}h1{margin:0 0 4px}a{color:var(--pri)}
.sub{color:var(--mut);margin:0 0 18px}.tabs a{display:inline-block;margin:0 8px 8px 0;padding:6px 14px;border:1px solid var(--line);
border-radius:99px;text-decoration:none;color:var(--ink)}.tabs a.on{background:var(--pri);color:#fff;border-color:var(--pri)}
.card{background:var(--card);border:1px solid var(--line);border-radius:14px;padding:14px;margin:0 0 12px}
.row{display:flex;gap:14px;align-items:center;text-decoration:none;color:inherit}.row img{width:120px;height:80px;object-fit:cover;border-radius:8px;background:var(--line)}
.row .t{font-weight:600}.mut{color:var(--mut);font-size:13px}.pill{font-size:12px;padding:2px 9px;border-radius:99px;border:1px solid var(--line)}
.pending{color:var(--pri)}.approved{color:var(--ok)}.rejected{color:var(--bad)}
.grid{display:grid;grid-template-columns:1.3fr 1fr;gap:14px}@media(max-width:760px){.grid{grid-template-columns:1fr}}
.grid img{width:100%;border-radius:10px;border:1px solid var(--line)}label{display:block;margin:10px 0 4px;font-weight:600}
input[type=text],textarea{width:100%;padding:9px;border-radius:8px;border:1px solid var(--line);background:var(--bg);color:var(--ink);font:inherit}
button{font:inherit;padding:9px 16px;border-radius:99px;border:0;background:var(--pri);color:#fff;cursor:pointer;margin:10px 8px 0 0}
button.no{background:var(--bad)}button.sec{background:transparent;color:var(--pri);border:1px solid var(--pri)}code{word-break:break-all;font-size:12px}
.warn{border-color:var(--bad)}
"""


def page(title, body):
    return ("<!doctype html><html lang=en><meta charset=utf-8><meta name=viewport content='width=device-width,initial-scale=1'>"
            "<title>%s</title><style>%s</style><main>%s</main></html>" % (html.escape(title), CSS, body)).encode()


# ---- HTTP ----------------------------------------------------------------------------------------

class Handler(BaseHTTPRequestHandler):
    server_version = "Verifier/1.0"
    store: Store = None
    cfg: Config = None

    def log_message(self, fmt, *a):
        sys.stderr.write("%s %s\n" % (self.address_string(), fmt % a))

    # responses
    def send(self, code, body=b"", ctype="text/html; charset=utf-8", headers=None):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("Content-Security-Policy", "default-src 'self' data:; style-src 'unsafe-inline'; form-action 'self'")
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def json(self, code, obj):
        self.send(code, json.dumps(obj).encode(), "application/json")

    # auth
    def reviewer(self):
        h = self.headers.get("Authorization", "")
        if h.startswith("Basic "):
            try:
                user, _, pw = base64.b64decode(h[6:]).decode().partition(":")
            except Exception:
                user, pw = "", ""
            if hmac.compare_digest(user, self.cfg.user) and hmac.compare_digest(pw, self.cfg.password):
                return user
        self.send(401, page("Sign in", "<h1>Sign in required</h1>"), headers={"WWW-Authenticate": 'Basic realm="Verifier"'})
        return None

    def csrf(self, user):
        return hmac.new(self.cfg.secret.encode(), ("csrf|" + user).encode(), hashlib.sha256).hexdigest()[:32]

    # routes
    def do_POST(self):
        path = urlparse(self.path).path
        n = int(self.headers.get("Content-Length") or 0)
        if n <= 0 or n > MAX_BODY:
            return self.json(413 if n > MAX_BODY else 400, {"error": "body missing or too large"})
        body = self.rfile.read(n)
        if path == "/webhook/traffic-violation":
            return self.webhook(body)
        user = self.reviewer()
        if not user:
            return
        form = {k: v[0] for k, v in parse_qs(body.decode("utf-8", "replace"), keep_blank_values=True).items()}
        if not hmac.compare_digest(form.get("csrf", ""), self.csrf(user)):
            return self.send(403, page("Refused", "<h1>Refused</h1><p>Reload the page and try again.</p>"))
        m = re.fullmatch(r"/r/([A-Z0-9-]+)/(review|forward)", path)
        if not m:
            return self.send(404, page("Not found", "<h1>Not found</h1>"))
        rid, action = m.groups()
        if action == "review":
            ok, why = self.store.review(rid, user, form.get("decision", ""), form.get("note", ""), form.get("plate_final", ""))
        else:
            ok, why = self.store.forward(rid, user)
        loc = "/r/%s%s" % (rid, "" if ok else "?err=" + quote(why[:120]))
        self.send(303, b"", headers={"Location": loc})

    def webhook(self, body):
        if self.cfg.api_key and not hmac.compare_digest(self.headers.get("X-Api-Key", ""), self.cfg.api_key):
            return self.json(401, {"error": "missing or wrong X-Api-Key"})
        ctype = self.headers.get("Content-Type", "")
        if not ctype.startswith("multipart/form-data"):
            return self.json(400, {"error": "multipart/form-data expected"})
        try:
            msg = email.message_from_bytes(b"Content-Type: " + ctype.encode() + b"\r\nMIME-Version: 1.0\r\n\r\n" + body,
                                           policy=email.policy.default)
            fields, files = {}, {}
            for part in msg.iter_parts():
                name = part.get_param("name", header="content-disposition")
                data = part.get_payload(decode=True) or b""
                if part.get_filename():
                    if name in FILE_PARTS:
                        files[name] = data
                elif name:
                    fields[name] = data.decode("utf-8", "replace")
        except Exception:
            return self.json(400, {"error": "could not read the multipart body"})
        code, out = self.store.ingest(fields, files)
        self.json(code, out)

    def do_GET(self):
        u = urlparse(self.path)
        path, q = u.path, parse_qs(u.query)
        if path == "/healthz":
            return self.json(200, {"ok": True})
        user = self.reviewer()
        if not user:
            return
        if path == "/":
            return self.home(q.get("status", [""])[0])
        m = re.fullmatch(r"/r/([A-Z0-9-]+)", path)
        if m:
            return self.detail(m.group(1), user, q.get("err", [""])[0])
        m = re.fullmatch(r"/files/([A-Z0-9-]+)/(frame|plate|vehicle)\.jpg", path)
        if m:
            p = self.store.files_dir / m.group(1) / (m.group(2) + ".jpg")
            return self.send(200, p.read_bytes(), "image/jpeg") if p.exists() else self.send(404, page("Not found", "<h1>No such photo</h1>"))
        m = re.fullmatch(r"/r/([A-Z0-9-]+)/packet\.zip", path)
        if m:
            r = self.store.get(m.group(1))
            if not r or r["status"] != "approved":
                return self.send(404, page("Not found", "<h1>Only approved reports have a packet</h1>"))
            data, _ = self.store.packet(m.group(1))
            self.store.audit(user, "packet_downloaded", m.group(1))
            return self.send(200, data, "application/zip", {"Content-Disposition": 'attachment; filename="%s.zip"' % m.group(1)})
        m = re.fullmatch(r"/verify/([A-Z0-9-]+)", path)
        if m:
            v = self.store.verify(m.group(1))
            return self.json(200, v) if v else self.json(404, {"error": "no such report"})
        self.send(404, page("Not found", "<h1>Not found</h1>"))

    def home(self, status):
        e = html.escape
        c = self.store.counts()
        tabs = "".join('<a class="%s" href="%s">%s (%s)</a>' % ("on" if status == s else "", "/?status=" + s if s else "/", e(l), n)
                       for s, l, n in (("", "All", sum(c.values())), ("pending", "To review", c["pending"]),
                                       ("approved", "Approved", c["approved"]), ("rejected", "Rejected", c["rejected"])))
        rows = ""
        for r in self.store.list(status or None):
            plate = r["plate_final"] or r["plate_number"] or "plate not read"
            thumb = "/files/%s/frame.jpg" % r["id"]
            rows += ('<div class=card><a class=row href="/r/%s"><img src="%s" alt=""><div><div class=t>%s '
                     '<span class="pill %s">%s</span>%s</div><div class=mut>%s &middot; %s &middot; %s</div></div></a></div>'
                     % (e(r["id"]), thumb, e(VIOLATIONS[r["violation"]]), e(r["status"]), e(r["status"]),
                        ' <span class="pill warn">possible duplicate</span>' if r["dup_of"] else "", e(plate), e(r["ts"]), e(r["id"])))
        self.send(200, page("Reports", "<h1>Violation reports</h1><p class=sub>Review what the app sends. Nothing here is a challan.</p>"
                            "<div class=tabs>%s</div>%s" % (tabs, rows or "<p class=mut>No reports yet.</p>")))

    def detail(self, rid, user, err):
        r = self.store.get(rid)
        if not r:
            return self.send(404, page("Not found", "<h1>No such report</h1>"))
        e = html.escape
        v = self.store.verify(rid)
        files = json.loads(r["files_json"])
        imgs = "".join('<a href="/files/%s/%s"><img src="/files/%s/%s" alt="%s"></a>' % (rid, n, rid, n, e(n)) for n in files)
        plate = r["plate_final"] or r["plate_number"]
        map_url = "https://maps.google.com/?q=%s,%s" % (r["lat"], r["lon"])
        dup = ('<div class="card warn">Possible duplicate of <a href="/r/%s">%s</a> (same plate and violation within 10 minutes).</div>'
               % (e(r["dup_of"]), e(r["dup_of"]))) if r["dup_of"] else ""
        intact = ('<span class=approved>Intact: every photo matches its fingerprint and the signature is valid.</span>'
                  if v["intact"] else '<span class=rejected>TAMPERED: %s</span>' % e("; ".join(v["problems"])))
        audit = "".join("<li><span class=mut>%s</span> %s &middot; %s %s</li>" % (e(a["at"]), e(a["actor"]), e(a["action"]), e(a["detail"] or ""))
                        for a in self.store.audit_for(rid))
        tok = self.csrf(user)
        decide = ""
        if r["status"] == "pending":
            decide = ("<form method=post action='/r/%s/review'><input type=hidden name=csrf value='%s'>"
                      "<label>Plate (correct it if the photo shows something different)</label><input type=text name=plate_final value='%s'>"
                      "<label>Note</label><textarea name=note rows=3></textarea>"
                      "<button name=decision value=approved>Approve</button><button class=no name=decision value=rejected>Reject</button></form>"
                      % (e(rid), tok, e(plate or "")))
        else:
            decide = "<p>%s by %s: %s</p>" % (e(r["status"]), e(r["reviewer"] or "-"), e(r["review_note"] or ""))
            if r["status"] == "approved":
                decide += ("<p><a href='/r/%s/packet.zip'><button type=button class=sec>Download evidence packet</button></a></p>"
                           "<form method=post action='/r/%s/forward'><input type=hidden name=csrf value='%s'>"
                           "<button>Email to the authority</button> <span class=mut>%s</span></form>"
                           % (e(rid), e(rid), tok, ("Sent " + e(r["forwarded_at"])) if r["forwarded_at"] else "Not sent yet"))
        body = ("<p><a href='/'>&larr; All reports</a></p><h1>%s</h1><p class=sub>%s &middot; %s</p>%s%s"
                "<div class=grid><div>%s</div><div class=card>"
                "<p><b>When (UTC)</b><br>%s</p><p><b>Where</b><br>%s, %s &middot; <a href='%s' rel=noreferrer>open map</a></p>"
                "<p><b>Plate as read</b><br>%s <span class=mut>(%s)</span></p><p><b>App note</b><br>%s</p>"
                "<p><b>Integrity</b><br>%s</p><p><b>Signature</b><br><code>%s</code></p></div></div>"
                "<div class=card><h3>Decision</h3>%s</div><div class=card><h3>History</h3><ul>%s</ul></div>"
                % (e(VIOLATIONS[r["violation"]]), e(r["id"]), e(r["status"]),
                   ('<div class="card warn">%s</div>' % e(err)) if err else "", dup, imgs, e(r["ts"]), r["lat"], r["lon"], e(map_url),
                   e(r["plate_number"] or "not read"), "clear" if r["plate_clear"] else "not clear", e(r["note"] or "-"), intact,
                   e(r["receipt_sig"]), decide, audit))
        self.send(200, page(r["id"], body))


def make_server(cfg, host="127.0.0.1", port=8787):
    store = Store(cfg)
    handler = type("H", (Handler,), {"store": store, "cfg": cfg})
    srv = ThreadingHTTPServer((host, port), handler)
    srv.store = store
    return srv


def load_config(data_dir):
    d = Path(data_dir)
    d.mkdir(parents=True, exist_ok=True)

    def persisted(name, make):
        p = d / name
        if not p.exists():
            p.write_text(make())
        return p.read_text().strip()

    smtp = {"host": os.environ.get("SMTP_HOST", ""), "port": os.environ.get("SMTP_PORT", "587"),
            "user": os.environ.get("SMTP_USER", ""), "password": os.environ.get("SMTP_PASS", ""),
            "from": os.environ.get("SMTP_FROM", "verifier@localhost"), "to": os.environ.get("SMTP_TO", "")}
    return Config(
        d, persisted("secret.key", lambda: secrets.token_hex(32)),
        os.environ.get("REVIEW_USER", "reviewer"),
        os.environ.get("REVIEW_PASS") or persisted("reviewer-password.txt", lambda: secrets.token_urlsafe(12)),
        os.environ.get("VERIFIER_KEY", ""), smtp)


if __name__ == "__main__":
    import argparse
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=8787)
    ap.add_argument("--data", default=str(Path(__file__).parent / "data"))
    ap.add_argument("--purge-days", type=int, help="delete reports older than this many days and exit")
    a = ap.parse_args()
    cfg = load_config(a.data)
    if a.purge_days is not None:
        print("purged", Store(cfg).purge(a.purge_days), "reports")
        sys.exit(0)
    srv = make_server(cfg, a.host, a.port)
    print("Verifier on http://%s:%d   reviewer: %s / %s" % (a.host, a.port, cfg.user, cfg.password))
    if not cfg.api_key:
        print("WARNING: VERIFIER_KEY is not set, so anyone who can reach /webhook/traffic-violation can post reports.")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
