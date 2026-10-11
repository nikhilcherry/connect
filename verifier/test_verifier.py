import base64
import contextlib
import email
import email.policy
import io
import json
import shutil
import ssl
import subprocess
import tempfile
import threading
import unittest
import urllib.error
import urllib.parse
import urllib.request
import zipfile
from pathlib import Path

import server
import smtp_sink

JPEG = b"\xff\xd8\xff\xe0" + b"fake-jpeg-bytes" * 20 + b"\xff\xd9"


def multipart(fields, files):
    """The same layout the phone app builds."""
    b = "----connect-123"
    out = b""
    for k, v in fields.items():
        out += ('--%s\r\nContent-Disposition: form-data; name="%s"\r\n\r\n%s\r\n' % (b, k, v)).encode()
    for k, v in files.items():
        out += ('--%s\r\nContent-Disposition: form-data; name="%s"; filename="%s.jpg"\r\nContent-Type: image/jpeg\r\n\r\n' % (b, k, k)).encode()
        out += v + b"\r\n"
    out += ("--%s--\r\n" % b).encode()
    return out, "multipart/form-data; boundary=" + b


def fields(**kw):
    f = {
        "event_id": "no_helmet_00001", "violation": "no_helmet", "timestamp": "2026-10-10T09:30:15.000Z",
        "latitude": "12.9716", "longitude": "77.5946", "plate_number": "KA01AB1234", "plate_clear": "true",
        "plate_hires": "false", "authorised": "true", "source": "connect-drive-mode", "note": "ai: people=1",
    }
    f.update(kw)
    return f


class Base(unittest.TestCase):
    api_key = ""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.sent = []
        cfg = server.Config(self.tmp.name, "s" * 64, "rev", "pw", self.api_key,
                            {"to": "police@example.org", "from": "v@example.org"}, send_mail=self.sent.append)
        self.srv = server.make_server(cfg, "127.0.0.1", 0)
        self.port = self.srv.server_address[1]
        self.store = self.srv.store
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()

    def tearDown(self):
        self.srv.shutdown()
        self.srv.server_close()
        self.store.close()
        self.tmp.cleanup()

    def url(self, p):
        return "http://127.0.0.1:%d%s" % (self.port, p)

    def post_report(self, f=None, files=None, headers=None):
        body, ctype = multipart(f or fields(), files if files is not None else {"frame": JPEG, "plate": JPEG})
        h = {"Content-Type": ctype}
        h.update(headers or {})
        return self.req("POST", "/webhook/traffic-violation", body, h)

    def req(self, method, path, data=None, headers=None, auth=True):
        h = dict(headers or {})
        if auth:
            h["Authorization"] = "Basic " + base64.b64encode(b"rev:pw").decode()
        r = urllib.request.Request(self.url(path), data=data, headers=h, method=method)

        class NoRedirect(urllib.request.HTTPRedirectHandler):
            def redirect_request(self, *a, **k):
                return None
        try:
            with urllib.request.build_opener(NoRedirect).open(r) as resp:
                return resp.status, resp.read(), dict(resp.headers)
        except urllib.error.HTTPError as e:
            return e.code, e.read(), dict(e.headers)

    def received(self, **kw):
        code, body, _ = self.post_report(fields(**kw))
        self.assertIn(code, (200, 201), body)
        return json.loads(body)["id"]

    def csrf(self):
        return self.srv.RequestHandlerClass.csrf(type("X", (), {"cfg": self.srv.RequestHandlerClass.cfg})(), "rev")

    def decide(self, rid, decision, note="ok", plate=""):
        form = urllib.parse.urlencode({"csrf": self.csrf(), "decision": decision, "note": note, "plate_final": plate}).encode()
        return self.req("POST", "/r/%s/review" % rid, form, {"Content-Type": "application/x-www-form-urlencoded"})


class Ingest(Base):
    def test_a_report_in_the_apps_format_is_stored_and_signed(self):
        code, body, _ = self.post_report()
        self.assertEqual(code, 201)
        out = json.loads(body)
        self.assertTrue(out["id"].startswith("R-"))
        self.assertEqual(len(out["receipt"]), 64)
        r = self.store.get(out["id"])
        self.assertEqual((r["lat"], r["lon"], r["plate_number"], r["status"]), (12.9716, 77.5946, "KA01AB1234", "pending"))

    def test_a_report_without_a_plate_is_accepted(self):
        code, _, _ = self.post_report(fields(plate_number="", plate_clear="false"), {"frame": JPEG})
        self.assertEqual(code, 201)

    def test_bad_reports_are_refused(self):
        for bad in (fields(violation="pothole"), fields(latitude="abc"), fields(latitude="91"), fields(timestamp="yesterday"), fields(event_id="")):
            self.assertEqual(self.post_report(bad)[0], 400, bad)
        self.assertEqual(self.post_report(fields(), {"plate": JPEG})[0], 400)  # no frame
        self.assertEqual(self.post_report(fields(), {"frame": b"not a jpeg"})[0], 400)

    def test_a_retry_from_the_app_is_not_stored_twice(self):
        first = self.received()
        code, body, _ = self.post_report()
        self.assertEqual(code, 200)
        self.assertEqual(json.loads(body)["id"], first)
        self.assertEqual(len(self.store.list()), 1)

    def test_same_plate_and_violation_close_in_time_is_flagged(self):
        a = self.received()
        b = self.received(event_id="no_helmet_00002", timestamp="2026-10-10T09:34:00.000Z")
        self.assertEqual(self.store.get(b)["dup_of"], a)
        c = self.received(event_id="no_helmet_00003", timestamp="2026-10-10T11:00:00.000Z")
        self.assertIsNone(self.store.get(c)["dup_of"])

    def test_an_unread_plate_is_never_called_a_duplicate(self):
        self.received(plate_number="")
        b = self.received(event_id="x2", plate_number="", timestamp="2026-10-10T09:31:00.000Z")
        self.assertIsNone(self.store.get(b)["dup_of"])


class Anonymity(Base):
    def test_the_callers_address_is_not_logged_or_stored(self):
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            self.received()
            self.req("GET", "/")
        self.assertNotIn("127.0.0.1", err.getvalue())
        self.assertIn("POST /webhook/traffic-violation", err.getvalue())
        cols = [c[1] for c in self.store.db.execute("PRAGMA table_info(reports)")]
        self.assertEqual([c for c in cols if c in ("ip", "addr", "remote", "device", "user_agent")], [])


class ApiKey(Base):
    api_key = "k3y"

    def test_the_webhook_needs_the_key_when_one_is_set(self):
        self.assertEqual(self.post_report()[0], 401)
        self.assertEqual(self.post_report(headers={"X-Api-Key": "wrong"})[0], 401)
        self.assertEqual(self.post_report(headers={"X-Api-Key": "k3y"})[0], 201)


class Integrity(Base):
    def test_untouched_evidence_verifies(self):
        rid = self.received()
        self.assertTrue(self.store.verify(rid)["intact"])

    def test_a_changed_photo_is_detected(self):
        rid = self.received()
        (self.store.files_dir / rid / "frame.jpg").write_bytes(JPEG + b"edited")
        v = self.store.verify(rid)
        self.assertFalse(v["intact"])
        self.assertIn("frame.jpg has changed", v["problems"][0])

    def test_a_changed_record_is_detected(self):
        rid = self.received()
        self.store.db.execute("UPDATE reports SET lat=13.0 WHERE id=?", (rid,))
        self.store.db.commit()
        self.assertFalse(self.store.verify(rid)["intact"])

    def test_a_missing_photo_is_detected(self):
        rid = self.received()
        (self.store.files_dir / rid / "plate.jpg").unlink()
        self.assertFalse(self.store.verify(rid)["intact"])


class Review(Base):
    def test_pages_need_a_sign_in(self):
        self.assertEqual(self.req("GET", "/", auth=False)[0], 401)
        self.assertEqual(self.req("GET", "/healthz", auth=False)[0], 200)
        rid = self.received()
        self.assertEqual(self.req("GET", "/files/%s/frame.jpg" % rid, auth=False)[0], 401)

    def test_the_queue_and_detail_pages_render(self):
        rid = self.received()
        code, body, _ = self.req("GET", "/")
        self.assertEqual(code, 200)
        self.assertIn(rid.encode(), body)
        code, body, _ = self.req("GET", "/r/" + rid)
        self.assertEqual(code, 200)
        self.assertIn(b"Intact", body)

    def test_text_from_the_phone_cannot_inject_html(self):
        rid = self.received(note="<script>alert(1)</script>", plate_number="<img src=x onerror=alert(1)>")
        _, body, _ = self.req("GET", "/r/" + rid)
        self.assertNotIn(b"<script>alert(1)", body)
        self.assertNotIn(b"<img src=x onerror", body)

    def test_approve_reject_and_plate_correction(self):
        rid = self.received(plate_number="KA01AB123", plate_clear="false")
        code, _, h = self.decide(rid, "approved", "plate corrected from the photo", "KA01AB1234")
        self.assertEqual(code, 303)
        r = self.store.get(rid)
        self.assertEqual((r["status"], r["reviewer"], r["plate_final"]), ("approved", "rev", "KA01AB1234"))
        self.assertEqual(self.store.get(self.received(event_id="e2", plate_number="", timestamp="2026-10-10T12:00:00Z"))["status"], "pending")
        rid2 = self.received(event_id="e3", plate_number="", timestamp="2026-10-10T13:00:00Z")
        self.decide(rid2, "rejected", "not a violation")
        self.assertEqual(self.store.get(rid2)["status"], "rejected")

    def test_a_decision_without_the_csrf_token_is_refused(self):
        rid = self.received()
        form = urllib.parse.urlencode({"decision": "approved"}).encode()
        code, _, _ = self.req("POST", "/r/%s/review" % rid, form, {"Content-Type": "application/x-www-form-urlencoded"})
        self.assertEqual(code, 403)
        self.assertEqual(self.store.get(rid)["status"], "pending")

    def test_every_action_is_in_the_history(self):
        rid = self.received()
        self.decide(rid, "approved")
        acts = [a["action"] for a in self.store.audit_for(rid)]
        self.assertEqual(acts, ["received", "approved"])


class PacketAndForward(Base):
    def test_only_an_approved_report_has_a_packet(self):
        rid = self.received()
        self.assertEqual(self.req("GET", "/r/%s/packet.zip" % rid)[0], 404)
        self.decide(rid, "approved", "ok", "KA01AB1234")
        code, data, _ = self.req("GET", "/r/%s/packet.zip" % rid)
        self.assertEqual(code, 200)
        z = zipfile.ZipFile(io.BytesIO(data))
        self.assertEqual(sorted(z.namelist()), ["frame.jpg", "manifest.json", "packet.html", "plate.jpg"])
        m = json.loads(z.read("manifest.json"))
        self.assertEqual(m["plate_confirmed_by_reviewer"], "KA01AB1234")
        self.assertTrue(m["integrity"]["intact_at_export"])
        self.assertIn("not a challan", m["notice"])
        self.assertIn(b"Evidence packet", z.read("packet.html"))

    def test_forwarding_emails_the_packet_and_records_it(self):
        rid = self.received()
        ok, why = self.store.forward(rid, "rev")
        self.assertFalse(ok)  # not approved yet
        self.assertEqual(self.sent, [])
        self.decide(rid, "approved")
        ok, why = self.store.forward(rid, "rev")
        self.assertTrue(ok, why)
        self.assertEqual(len(self.sent), 1)
        msg = self.sent[0]
        self.assertEqual(msg["To"], "police@example.org")
        self.assertEqual([p.get_filename() for p in msg.iter_attachments()], [rid + ".zip"])
        self.assertIsNotNone(self.store.get(rid)["forwarded_at"])

    def test_a_mail_failure_is_reported_and_not_recorded_as_sent(self):
        rid = self.received()
        self.decide(rid, "approved")

        def boom(_):
            raise RuntimeError("smtp down")
        self.srv.store.cfg.send_mail = boom
        ok, why = self.store.forward(rid, "rev")
        self.assertFalse(ok)
        self.assertIn("smtp down", why)
        self.assertIsNone(self.store.get(rid)["forwarded_at"])


class RealMail(unittest.TestCase):
    """The email step through a real SMTP conversation (smtp_sink), not an injected fake."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.sink = smtp_sink.Sink(("127.0.0.1", 0), Path(self.tmp.name) / "inbox")
        threading.Thread(target=self.sink.serve_forever, daemon=True).start()
        self.port = self.sink.server_address[1]
        smtp = {"host": "127.0.0.1", "port": str(self.port), "security": "none", "to": "police@example.org, desk@example.org",
                "from": "verifier@example.org"}
        self.cfg = server.Config(Path(self.tmp.name) / "data", "s" * 64, "rev", "pw", "", smtp)  # no send_mail: the real path
        self.store = server.Store(self.cfg)

    def tearDown(self):
        self.sink.shutdown()
        self.sink.server_close()
        self.store.close()
        self.tmp.cleanup()

    def approved(self):
        code, out = self.store.ingest(fields(), {"frame": JPEG, "plate": JPEG, "vehicle": JPEG})
        self.assertEqual(code, 201)
        self.store.review(out["id"], "rev", "approved", "checked", "KA01AB1234")
        return out["id"]

    def test_the_test_email_arrives(self):
        ok, why = server.send_test_email(self.cfg)
        self.assertTrue(ok, why)
        self.assertEqual(self.sink.count, 1)

    def test_an_approved_report_is_emailed_with_its_packet(self):
        rid = self.approved()
        ok, why = self.store.forward(rid, "rev")
        self.assertTrue(ok, why)
        self.assertEqual(self.sink.count, 1)
        msg = email.message_from_bytes(self.sink.saved[0].read_bytes(), policy=email.policy.default)
        self.assertIn(rid, msg["Subject"])
        self.assertIn("desk@example.org", msg["To"])
        atts = list(msg.iter_attachments())
        self.assertEqual([a.get_filename() for a in atts], [rid + ".zip"])
        z = zipfile.ZipFile(io.BytesIO(atts[0].get_payload(decode=True)))
        self.assertEqual(sorted(z.namelist()), ["frame.jpg", "manifest.json", "packet.html", "plate.jpg", "vehicle.jpg"])
        m = json.loads(z.read("manifest.json"))
        self.assertEqual(m["plate_confirmed_by_reviewer"], "KA01AB1234")
        self.assertTrue(m["integrity"]["intact_at_export"])
        self.assertIsNotNone(self.store.get(rid)["forwarded_at"])

    def test_a_dead_mail_server_is_reported_and_nothing_is_marked_sent(self):
        rid = self.approved()
        self.cfg.smtp["port"] = "1"  # nothing listens here
        ok, why = self.store.forward(rid, "rev")
        self.assertFalse(ok)
        self.assertTrue(why)
        self.assertIsNone(self.store.get(rid)["forwarded_at"])
        self.assertIn("forward_failed", [a["action"] for a in self.store.audit_for(rid)])
        self.assertEqual(self.sink.count, 0)

    def test_unconfigured_and_bad_security_are_clear_errors(self):
        empty = server.Config(Path(self.tmp.name) / "d2", "s" * 64, "rev", "pw", "", {})
        ok, why = server.send_test_email(empty)
        self.assertFalse(ok)
        self.assertIn("SMTP is not configured", why)
        bad = server.Config(Path(self.tmp.name) / "d3", "s" * 64, "rev", "pw", "", {"host": "x", "to": "y", "security": "magic"})
        ok, why = server.send_test_email(bad)
        self.assertFalse(ok)
        self.assertIn("SMTP_SECURITY", why)

    def test_port_465_means_implicit_tls_by_default(self):
        # Nothing listens with TLS here, so it must fail as a TLS error, proving the ssl path was chosen.
        cfg = server.Config(Path(self.tmp.name) / "d4", "s" * 64, "rev", "pw", "", {"host": "127.0.0.1", "port": str(self.port), "to": "y"})
        cfg.smtp["port"] = "465"
        ok, why = server.send_test_email(cfg)
        self.assertFalse(ok)


@unittest.skipUnless(shutil.which("openssl"), "openssl is needed to make a test certificate")
class Https(unittest.TestCase):
    def test_the_console_can_serve_https(self):
        with tempfile.TemporaryDirectory() as d:
            cert, key = str(Path(d) / "c.pem"), str(Path(d) / "k.pem")
            subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", key, "-out", cert, "-days", "1",
                            "-subj", "/CN=localhost"], check=True, capture_output=True)
            cfg = server.Config(Path(d) / "data", "s" * 64, "rev", "pw", "")
            srv = server.make_server(cfg, "127.0.0.1", 0)
            server.enable_tls(srv, cert, key)
            threading.Thread(target=srv.serve_forever, daemon=True).start()
            try:
                ctx = ssl.create_default_context(cafile=cert)
                with urllib.request.urlopen("https://localhost:%d/healthz" % srv.server_address[1], context=ctx) as r:
                    self.assertEqual(json.loads(r.read()), {"ok": True})
                # Plain http to the same port is not understood.
                with self.assertRaises(Exception):
                    urllib.request.urlopen("http://127.0.0.1:%d/healthz" % srv.server_address[1], timeout=3)
            finally:
                srv.shutdown()
                srv.server_close()
                srv.store.close()


class Purge(Base):
    def test_old_reports_and_their_photos_are_deleted(self):
        rid = self.received()
        self.store.db.execute("UPDATE reports SET received_at='2020-01-01T00:00:00Z' WHERE id=?", (rid,))
        self.store.db.commit()
        self.assertEqual(self.store.purge(30), 1)
        self.assertIsNone(self.store.get(rid))
        self.assertFalse((self.store.files_dir / rid).exists())


if __name__ == "__main__":
    unittest.main()
