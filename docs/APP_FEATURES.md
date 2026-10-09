# Connect: what's in the app today

A feature inventory of the app as of commit `ae788ec` (2026-10-09). For the pitch and architecture see `README.md`; for model data and scores see `ml/README.md`.

**One line:** a QR tag (or just the number plate) on a car lets anyone reach its owner through a private chat, with no phone numbers exchanged. Around that sits a set of owner tools and an on-device AI layer.

## 1. The stranger's side (web, no app)

The scan page is `web/index.html`, served as a static page and talking only to the `scan` edge function.

| Feature | Notes |
| --- | --- |
| Scan the tag | Shows only the car's colour, make and model |
| Pick a reason | Blocking a car, lights on, being towed, window open, accident or damage, or a note |
| Photo attachment | Shrunk in the browser; stored privately, deleted after 7 days |
| Proof of presence | Type the last 4 characters of the plate; the server only answers yes or no |
| Chat | Quick replies or free text; offline outbox resends on reconnect |
| "Seen" receipt | Shows when the owner has opened the thread |
| Five-minute nudge | After 5 min of silence, suggests asking nearby security or a neighbour |
| "Owner is on the way" | Shown when a family member taps the button |
| "Back by 6:30" | Owner's return time, shown only after the plate check |
| Medical info | Shown only on an accident report, and only if the owner opted in |
| Languages | English, हिन्दी, ಕನ್ನಡ, தமிழ் |
| Live trip viewer | `web/trip.html`: follows a shared drive on a private link |
| Privacy page | `web/privacy.html` |

Abuse protection: 5 alerts per sender per 10 min, 10 per tag per hour, hashed IPs, wrong-guess rate limit, silent drop of blocked senders.

## 2. The owner's app (Flutter, Android)

### Onboarding and account
- Anonymous sign-in (no OTP or form); car setup from a built-in car catalog.
- Several cars per account.
- Join a family member's car with a one-time 6-character code.
- Account deletion (Garage button, backed by a server RPC).
- Languages: English, Hindi, Kannada, Tamil.

### Home tab
- Alerts that need a reply, with stat cards: open alerts, days to the next renewal, family count.
- Tag preview, "back by" status card, where-I-parked card, society notices, live-trip banner.

### Alerts tab
- Every conversation, with photo attachments and block-and-report.
- Quick replies, sent in the stranger's chosen language from the app's own translation tables.
- On-device **Translate** on a stranger's message; free-text replies are translated with a "They will read: …" preview.
- Voice dictation for replies (the phone's speech recogniser).
- **Estimate damage** button on a photo a stranger sent.
- Family "who's on it" status: "Priya is on the way".
- Live in-app notification while the app is open, FCM push when it is closed.

### Safety tab
- **Drive Mode** crash detection from the accelerometer, with a 15-second cancel countdown.
- One-tap 112, and an SOS SMS to saved contacts with a location link.
- **Live trip sharing**: position every 15 s, auto-stops after 1–12 h, with a visible notification the whole time.
- Medical info: opt-in blood group and allergies.

### Garage tab
- **Tag**: the 8-character QR, shareable as an image for a print shop; can be paused or replaced.
- **Reach a car by its plate**: photograph a plate, or use the live camera view, and open the masked chat if that car is on Connect.
- **Check damage and cost**: dents, scratches, cracks and shattered glass, a rough ₹ range, and an evidence PDF.
- **Fuel, expenses and service log**: full-to-full mileage, six months of spend, service history exported as a PDF for resale. Stays on the phone.
- **Documents**: photos of RC, insurance, PUC and licence, with pinch-zoom viewer. Stays on the phone.
- **Renewals**: PUC, insurance and service reminders at 30 days, 7 days and on the day.
- **Where did I park**: location, note, photo, paid-parking reminder. Stays on the phone.
- **Sound check** (new, experimental): the phone sends and receives short messages as sound, with no internet, Wi-Fi or Bluetooth. Pick ultrasonic (about 17.6–20 kHz) or audible tones, then Send on one phone and Listen on another, or Loopback on one phone. It is the groundwork for a sound-based proof of presence.
- **Fit Check**: space rules of thumb for a parking slot (length and door-opening width).
- **Challan check**: copies the plate and opens the official Parivahan e-challan site.
- **Family**: invite up to 5 people; only the owner can change the plate or tag.
- **Housing society mode**: join code, member and tagged-car counts, a roster (flat and model, never plates), push notices.
- **Away status**: the "Back by 6:30" setting, which clears itself.
- **Protect a friend's car**: referral share.

## 3. On-device AI layer

All inference runs on the phone; nothing is sent while you look around.

| Capability | How it works | Measured |
| --- | --- | --- |
| Plate detection | Own YOLO11n, INT8, 4.3 MB, ONNX Runtime | mAP50 0.73 on 47 real Indian phone photos |
| Plate reading | Own CRNN+CTC, 3.4 MB, tried before ML Kit; both shown as chips | 60.7% exact vs 49.3% for ML Kit on 150 held-out Indian crops; right plate in top 2 for 73% |
| End to end | Detector + reader merged with whole-photo ML Kit | 28 of 46 plates found, right first on 25 (ML Kit alone: 22 and 21) on 44 hand-labelled photos |
| Live camera view | Detector on every few frames, boxes drawn on screen | ~80–130 ms/frame on an x86 emulator |
| Damage detection | Own YOLO11s, INT8, 12.5 MB, plus a hand-set ₹ cost table | mAP50 0.40; reliable on glass, crack, dent, scratch only; lamp and tyre flagged low confidence |
| Situation understanding | ML Kit image labelling, conservative | Suggests a reason only on distinctive signs (wreck, tow truck, gate); otherwise the person picks |
| Language bridge | ML Kit language-id and translation, packs of ~30 MB downloaded once | Verified on an emulator |
| Sound link | Own 16-tone MFSK modem in plain Dart (`acoustic_modem.dart`), CRC-8 checked, ultrasonic and audible profiles; speaker and mic glue in `sound_link.dart` | 8 software tests pass (offset, noise, silence, corruption). **Not yet confirmed on real speakers and mics**; whether ultrasound works depends on the phone |
| Voice dictation | Phone speech recogniser | Starts on the emulator; real speech untested |

The cost range is an assumption-based estimate, never a quote.

## 4. Backend (Supabase)

- **Tables and security**: Postgres with row-level security; default grants revoked and re-added per table and column. 10 migrations in `supabase/migrations/`.
- **Edge functions**: `scan` (the only door for strangers) and `notify` (society notices), plus shared push code in `_shared/`.
- **Storage**: a private bucket for alert photos, opened through expiring links.
- **Realtime**: owner's app subscribes to alerts.
- **Push**: FCM, which needs Firebase to be configured at build time.

## 5. What stays on the phone

Parking spot, fuel and expense log, service history, document photos, damage photos and reports, and every ML inference. The server never receives these.

## 6. Tests and tooling

- 130 backend end-to-end checks (`supabase/tests/e2e.mjs`).
- 87 app tests, including `shipped_models_test.dart`, which guards against an ONNX model the phone's runtime would reject.
- 8 modem tests (`test/acoustic_modem_test.dart`): round trip at an odd offset, noise, silence, and a corrupted frame, for both profiles.
- On-device ML checks on an Android 15 emulator (`integration_test/ml_test.dart`).
- CI workflow with the Flutter version pinned to 3.44.0.
- `ml/`: training, data prep and export scripts for the three models.
- `docs/connect-iqoo-deck.pptx` (10-slide deck), `docs/demo-runbook.md`, `docs/hackathon-48h-plan.md`, `docs/free-features-roadmap.md`.

## 7. Current status and known limits

- **Backend for the phones**: the installed builds point at `http://127.0.0.1:54321`, the local Supabase stack, and rely on `adb reverse tcp:54321 tcp:54321` over USB. There is no hosted backend yet, so the app says "offline" without the cable and the running stack.
- **Scan page and edge functions** are not forwarded to the phones, so the stranger flow and the `scan` function are untested from a real phone.
- **Placeholders**: `connect.example.com` for the scan and app domain, and no real Supabase project ref or Firebase keys.
- **Real-device testing**: the app has run on an emulator only. Camera, mic dictation and the live plate view are not yet confirmed on a physical phone.
- **Sound link**: only proven in software. The speaker and mic test on a real phone is the next step, and the ultrasonic profile may not work on every phone. Sound check is installed on one iQOO.
- **Models**: not trained on a large Indian dataset. Plate recall is 28 of 46 on a small hand-labelled set; damage mAP50 is modest.
- **Voice notes from the stranger** are not handled, because the scan page has no on-device model.
- **Licences**: Ultralytics (YOLO) is AGPL-3.0, and the plate test set is evaluation-only.
