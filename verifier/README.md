# Verification console

A small service between the phone app and the authority that issues challans. It **does not issue
challans and is not a government system**. It makes a citizen report trustworthy and easy to act on, so a
traffic authority can decide quickly. Becoming an approved channel needs an agreement with that authority;
this is the technical layer that agreement would rest on.

## What it does

| Step | What happens |
| --- | --- |
| Receive | Accepts the app's `multipart/form-data` report (frame, optional plate and vehicle photos, coordinates, time, plate text). Optional `X-Api-Key` check. Reports are **anonymous**: no name, account or device id arrives, the event id is a one-way hash, and this server neither logs nor stores the caller's address. |
| Fingerprint | SHA-256 of every photo, and an HMAC signature over the whole record. Changing a photo or the record afterwards is detected. |
| De-duplicate | Same plate and violation within 10 minutes is flagged as a possible duplicate. An unread plate is never matched. Retries from the app are idempotent. |
| Review | A reviewer signs in, checks the photos, corrects the plate if needed, approves or rejects, and leaves a note. Every action is written to a history. |
| Packet | An approved report downloads as a zip: `manifest.json`, the photos, and a printable `packet.html`. |
| Forward | An approved report can be emailed to the authority (SMTP). A failed send is reported and never recorded as sent. |
| Retention | `--purge-days N` deletes older reports and their photos. |

## Run

```
python server.py                      # http://127.0.0.1:8787
```

It prints the reviewer login. Settings (environment variables):

| Variable | Meaning |
| --- | --- |
| `REVIEW_USER`, `REVIEW_PASS` | Reviewer sign-in. If no password is set, one is generated into `data/reviewer-password.txt`. |
| `VERIFIER_KEY` | If set, the webhook requires this value in the `X-Api-Key` header. Set it. |
| `SMTP_HOST`, `SMTP_PORT`, `SMTP_USER`, `SMTP_PASS`, `SMTP_FROM`, `SMTP_TO` | Where "Email to the authority" sends. |

Point the app at it: `--dart-define=VIOLATION_WEBHOOK_URL=http://<host>:8787/webhook/traffic-violation
--dart-define=VIOLATION_WEBHOOK_KEY=<VERIFIER_KEY>`. For a phone on USB: `adb reverse tcp:8787 tcp:8787`
and use `http://127.0.0.1:8787/...`.

Tests: `python -m unittest test_verifier` (21 tests, no network, standard library only).

## Before this is used for anything real

- **HTTPS and hosting.** It speaks plain HTTP and binds to `127.0.0.1`. Put it behind a TLS terminator
  (a reverse proxy) before exposing it; do not expose it as it is.
- **Reviewers.** There is one shared login. Real use needs individual accounts and roles.
- **Anonymous, but not untraceable.** The report carries nothing that names the reporter, but the network
  can still see who connected: the hosting provider, or any proxy in front of this server, sees the caller's
  address. Where the evidence was taken (the coordinates) and when also show that someone was there.
- **Privacy.** Reports hold photos of other people's vehicles and plates, and the reporter's location.
  Decide the retention period, who may see them and why, and consent for the reporter (India's DPDP Act
  applies). Run `--purge-days` on a schedule.
- **Who decides.** A report is evidence for the authority, not an offence. The packet says so.
- **Signing key.** `data/secret.key` signs receipts. Back it up and keep it private; losing it means old
  receipts can no longer be verified.
- **Single machine, SQLite.** Fine for a demo and a pilot, not for scale.
