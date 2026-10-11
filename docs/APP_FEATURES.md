# Connect: what's in the app today

A feature inventory of the app as of 10 October 2026. For the pitch and architecture see `README.md`; for model data and scores see `ml/README.md`.

**One line:** a QR tag (or just the number plate) on a car lets anyone reach its owner through a private chat, with no phone numbers exchanged. Around that sits a set of owner tools and an on-device AI layer.

## 1. The stranger's side (web, no app)

The scan page is `web/index.html`, served as a static page and talking only to the `scan` edge function.

| Feature | Notes |
| --- | --- |
| Scan the tag | Shows only the car's colour, make and model |
| Pick a reason | Blocking a car, lights on, being towed, window open, accident or damage, or a note |
| Photo attachment | Shrunk in the browser; stored privately, deleted after 7 days |
| Proof of presence | Type the last 4 characters of the plate; the server only answers yes or no |
| Chat | Quick replies or free text; offline outbox resends on reconnect, and a resend can no longer reach the owner twice |
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
- **RC check when adding a car**: the plate is looked up and the owner photographs the Registration Certificate. *Demo data only*: no RC provider is connected, the record is generated from the plate, and the ownership comparison is simulated (it always passes). The screen says "Demo data".
- **Opens without a connection**: the car, tag and alerts are kept on the phone, so the app opens on them at once and shows an "Offline" strip until the server answers. It retries by itself.
- A build pointed at a new server address keeps the account (the session used to be lost, and with it the car).
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
- **Witness mode** (new): a phone left watching from a parked car. Our plate detector and reader run on the camera about three times a second and the last 90 seconds of plates are kept in memory. A bump (three sensitivities, 0.3 g to 1.8 g) or the *Mark this moment* button freezes it: the plates seen in the 12 s before and 3 s after, voted across frames, two frames, the time and the force. From the incident: reach that car's owner through Connect, or save a PDF record. The camera only runs while the screen is open, so the screen is kept awake.

### Garage tab
- **Tag**: the 8-character QR, shareable as an image for a print shop; can be paused or replaced.
- **Reach a car by its plate**: photograph a plate, or use the live camera view, and open the masked chat if that car is on Connect.
- **Check damage and cost**: dents, scratches, cracks and shattered glass, a rough ₹ range, and an evidence PDF.
- **Fuel, expenses and service log**: full-to-full mileage, six months of spend, service history exported as a PDF for resale. Stays on the phone.
- **Documents**: photos of RC, insurance, PUC and licence, with pinch-zoom viewer. Stays on the phone.
- **Renewals**: PUC, insurance and service reminders at 30 days, 7 days and on the day.
- **Where did I park**: location, note, photo, paid-parking reminder. Stays on the phone.
- **Say it with sound** (new): for a car parked where there is no signal. The phone says which car (the plate) and what is wrong as about two seconds of sound, ultrasonic first and audible tones as a fallback. Any Connect phone with this screen open answers by sound. The owner's phone shows it and notifies at once. Any other phone carries it and delivers it to the server when it is back online, and so does the sender's own phone. The server lets the same message in once however many phones deliver it. The alert reaches the owner marked "Carried here by sound".
- **Bluetooth relay** (new, same screen): while *Say it with sound* is open the phone also passes whispers over Bluetooth Low Energy: no pairing, the carried messages (plate + reason, a few bytes) ride in a broadcast advert and every Connect phone in range hears them. Reaches further than sound and feeds the same store-carry-forward path. It asks for Bluetooth permission on that screen only, and stops when the screen closes. Only the advert codec is unit-tested; two phones relaying over Bluetooth has not been run live.
- **Test this phone**: plays a frame on each band and listens for its own voice, to show whether this phone's speaker and microphone reach ultrasound.
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
| Sound link | Own 16-tone MFSK modem in plain Dart (`acoustic_modem.dart`): 48 kHz, 60 ms symbols, CRC-16, an ultrasonic band (18.0–19.7 kHz) and an audible one (1.5–3.2 kHz); one open microphone decodes both (`sound_link.dart`) | **Measured on an iQOO 15** with `tool/sound_lab.dart`: its speaker-to-mic path is flat from 17 to 19.25 kHz and falls away above 19.5 kHz. Frames played by the phone were decoded from a laptop microphone on the same desk at full volume and 20 dB quieter (12 of 12), and 40 dB quieter (6 of 8). Three of those recordings are test fixtures. The app's own sound link was then run against itself on a second iQOO 15: every frame on both bands was heard by the phone that sent it, and all six were also decoded at the laptop microphone. Two phones answering each other live has not been run yet |
| Witness mode | Plate detector + reader on the camera stream, votes across frames (`witness.dart`), accelerometer bump trigger | On an Android 15 emulator: a two-row plate in the camera scene read in 44 of the frames around a simulated 1.5 g bump, then found on Connect. Not yet run on a real camera or a real knock |
| Voice dictation | Phone speech recogniser | Starts on the emulator; real speech untested |

The cost range is an assumption-based estimate, never a quote.

## 4. Backend (Supabase)

- **Tables and security**: Postgres with row-level security; default grants revoked and re-added per table and column. 12 migrations in `supabase/migrations/`.
- **One alert, once**: an alert can carry a sender-chosen reference. A retry after a lost reply, or a second phone delivering a message it also heard by sound, gets the alert that already exists instead of making another, and does not count against the rate limits.
- **Edge functions**: `scan` (the only door for strangers) and `notify` (society notices), plus shared push code in `_shared/`.
- **Storage**: a private bucket for alert photos, opened through expiring links.
- **Realtime**: owner's app subscribes to alerts.
- **Push**: FCM, which needs Firebase to be configured at build time.

## 5. What stays on the phone

Parking spot, fuel and expense log, service history, document photos, damage photos and reports, and every ML inference. The server never receives these.

## 6. Tests and tooling

- 139 backend end-to-end checks (`supabase/tests/e2e.mjs`).
- 146 app tests, including `shipped_models_test.dart`, which guards against an ONNX model the phone's runtime would reject.
- Modem tests (`test/acoustic_modem_test.dart`) for both bands: an odd offset, noise, a frame a thousand times quieter than full scale, silence, a hole, one wrong tone, two frames in one recording. `test/sound_recordings_test.dart` decodes three real recordings of an iQOO 15's speaker.
- `tool/sound_lab.dart` and `tool/modem_wav.dart`: play and record test signals on a real phone under a separate app id, and decode the recordings on a laptop.
- `scripts/demo-up.sh`: starts the stack, the functions and the scan page, and with `--watch` restarts the tunnel when it drops.
- On-device ML checks on an Android 15 emulator (`integration_test/ml_test.dart`).
- CI workflow with the Flutter version pinned to 3.44.0.
- `ml/`: training, data prep and export scripts for the three models.
- `docs/connect-iqoo-deck.pptx` (10-slide deck), `docs/demo-runbook.md`, `docs/hackathon-48h-plan.md`, `docs/free-features-roadmap.md`.

## 7. Current status and known limits

- **Backend for the phones**: the phones' builds talk to `https://connect-api.premortem.tech`, a Cloudflare tunnel to the Supabase stack on the team laptop. It works only while that laptop is on and online; `scripts/demo-up.sh --watch` keeps it up. There is no hosted backend yet. Without it the app now opens on its saved copy instead of an error screen.
- **Scan page**: the phones' QR tags point at `https://connect.premortem.tech`. The page is served on the laptop (`:8093`) but is **not published** until `scripts/demo-up.sh --publish` is run, so scanning a tag from another phone does not work yet.
- **Placeholders** in the repository: `connect.example.com` for the scan and app domain, and no real Supabase project ref or Firebase keys.
- **Real-device testing**: the sound link was measured on one iQOO 15 and its sending, listening, volume handling and decoding were run on a second. The new screens (Say it with sound, Witness mode, offline start) were run on an emulator. Still not confirmed on a physical phone: two phones answering each other by sound, Witness mode on a real camera and a real knock, mic dictation, and the live plate view.
- **Sound link limits**: a phone listens only while the *Say it with sound* screen is open; range is a few metres and walls stop it; one frame in a few can be lost when a tone lands in a dead spot between two devices, which is why a send is tried three times.
- **RC check**: demo data and a simulated comparison, as above.
- **Models**: not trained on a large Indian dataset. Plate recall is 28 of 46 on a small hand-labelled set; damage mAP50 is modest.
- **Voice notes from the stranger** are not handled, because the scan page has no on-device model.
- **Licences**: Ultralytics (YOLO) is AGPL-3.0, and the plate test set is evaluation-only.
