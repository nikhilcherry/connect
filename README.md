# Connect

**Anyone can reach you about your car, without either side sharing a phone number.**

A QR tag on the windshield turns "whose car is this?" into a private two-way chat. A stranger scans it with any phone camera, picks what's wrong (blocking a gate, lights on, being towed, an accident), proves they're standing at the car, and the owner and their family get the message instantly. Around that core, the app gives owners reasons to open it every week: parking, renewals, fuel and service logs, family safety and live trip sharing.

| | |
| --- | --- |
| **Platform** | Android (Flutter) + static web scan page + Supabase backend |
| **Running cost** | ₹0 / month on free tiers |
| **Languages** | English, हिन्दी, ಕನ್ನಡ, தமிழ் (app, scan page and trip page) |
| **Tests** | 130 backend end-to-end checks · 63 app tests · 8 on-device ML checks |


<p align="center">
  <img src="docs/screens/home.png" width="18%" alt="Home">
  <img src="docs/screens/tag.png" width="18%" alt="Your tag">
  <img src="docs/screens/plate.png" width="18%" alt="Reach a car by its plate">
  <img src="docs/screens/live-plate.png" width="18%" alt="Live view: our detector boxes the plate">
  <img src="docs/screens/alert-translate.png" width="18%" alt="Alert thread with on-device translation">
</p>
<p align="center"><sub>Captured from the release build on an Android 15 emulator: home, the tag, plate-as-QR, the live view where our own detector boxes the plate, and an alert translated on the phone.</sub></p>

---

## What the app does

### For the person at the car (no app needed)

1. **Scan** the tag: the page shows only the car's colour, make and model.
2. **Pick a reason**: blocking a car, lights on, being towed, window open, accident or damage, or a note. Optionally attach a photo, which is shrunk in the browser.
3. **Prove you're there**: type the last 4 characters of the number plate. A shared photo of the sticker isn't enough.
4. **Chat**: quick replies or free text; if the signal drops (a basement, a lift) the page keeps your message and sends it by itself when you are back online; a line tells you when "the owner has seen your message", and after five minutes of silence the page suggests what to do next (ask nearby security or a neighbour) (set when the owner opens the thread, before any reply); see "Owner is on the way", the owner's "back by 6:30" status and, on accident reports, any medical info the owner chose to share.

### For the owner (Android app)

| Tab | What's there |
| --- | --- |
| **Home** | Alerts that need a reply, stat cards (open alerts, days to next renewal, family), the tag, "back by" status, where-did-I-park, society notices, live-trip banner |
| **Alerts** | Every conversation, photo attachments, block-and-report |
| **Safety** | Drive Mode crash detection with a 15-second cancel countdown, one-tap 112 and SOS to contacts, live trip sharing, medical info |
| **Garage** | Fuel and expenses with mileage, service history PDF, document photos, renewals, challan check, family, society, Fit Check, tag settings, language |


**Feature details**

- **Tag**: an 8-character code printed as a QR sticker (share it as an image for a print shop), which can be paused or replaced.
- **"Back by 6:30"**: tells people who message you when you'll return. Shown only after the plate check, never from a bare scan, and it clears itself when the time passes.
- **Family sharing**: a one-time 6-character code adds up to 5 people. Everyone gets the alerts, and when someone taps "On my way" or "Sorted" the others see who ("Priya is on the way"), so two people don't both rush to the car; the person at the car is never told who; only the owner can change the plate or the tag.
- **Where did I park**: location, note, photo and a paid-parking reminder, stored only on the phone.
- **Medical info**: opt-in blood group and allergies, shown to a stranger only on an accident report.
- **Photos on alerts**: kept in a private bucket, opened through expiring links, deleted after 7 days.
- **Housing society mode**: the admin gets a join code for the notice board, member and tagged-car counts, a roster (flat and car model, never plates) and push notices.
- **Live trip sharing**: family follows a drive on a web link with the route so far. It stops by itself (1–12 h) and shows a visible notification the whole time.
- **Fuel and expenses**: full-to-full mileage, six months of spend, and a service history exported as a PDF for resale. On the phone only.
- **Documents**: photos of RC, insurance, PUC and licence, on the phone only, clearly marked as not a legal copy (that's DigiLocker).
- **Renewals**: PUC, insurance and service reminders 30 days, 7 days and on the day.
- **Challan check**: copies the plate and opens the official Parivahan e-challan site.
- **Protect a friend's car**: referral share.

---

## How it works

```
stranger's phone ──► web/index.html ──► functions/v1/scan ──(service role)──► Postgres + Storage
family's browser ──► web/trip.html  ──►        │                                   │ realtime
owner's app ◄──────────────────────── REST + RLS ◄─────────────────────────────────┘
      ▲                                          │
      └──────────── FCM push ◄── _shared/push.ts ┘ (and functions/v1/notify for society notices)
```

- **Strangers never touch tables.** The `scan` edge function is their only door. It checks the plate digits, rate-limits (5 alerts per sender per 10 min, 10 per tag per hour), hashes IPs with a secret salt, and silently drops blocked senders.
- **Owners sign in anonymously** (no OTP, no form) and read or write only their own rows through row-level security. Default Supabase grants are revoked; each grant is added back explicitly, down to individual columns.
- **Information is revealed late**: "back by" only after the plate check, medical info only on accidents, trip positions only with the private link and only while the trip is live.
- **Personal logs never leave the phone**: parking, fuel and documents.

### Privacy at a glance

| A stranger can see | A stranger never sees |
| --- | --- |
| Colour, make and model | The owner's name, number or address |
| The owner's replies in their own thread | The number plate (they type 4 characters; we only say yes or no) |
| "Back by", after the plate check | Other people's alerts or messages |
| Medical info, only on an accident and only if shared | Parking spot, documents, fuel log |
| A live trip, only via the owner's link | A trip's position after it ends |

---

## Planned: on-device AI layer

Built for phone-first use, with audio and images processed on the device:

1. **The plate is the QR. (Built.)** Garage → *Reach a car by its plate*: our own plate detector (a YOLO11n we trained, 10 MB, on-device; see `ml/`) finds the plate and the on-device text reader (ML Kit) reads the crop, and if the owner is on Connect it opens the masked chat, so no sticker is needed. The photo never leaves the phone; the `plate` action only returns a tag code (and nothing when a plate is claimed by more than one account, so a squatter never receives your messages), shares the wrong-guess rate limit with plate checks, and is covered by the e2e suite. A **live camera view** (Garage → Reach a car by its plate → Live camera view) runs that detector on the camera stream at ~80–130 ms a frame (Android 15 emulator, CPU) and draws a box on every plate in view; tapping one photographs it, reads the crop and does the single lookup. Nothing is sent while you look around. The model, its training data, scores (test mAP50 0.991 on 882 held-out photos) and limits are in `ml/README.md`; it has not been scored on Indian plates.
2. **Situation understanding. (Built, deliberately conservative.)** After finding a car by plate, a photo of the problem is labelled on-device (ML Kit). ML Kit's base model labels every car photo "Vehicle, Car, Wheel, Road, Bumper…", so generic parts prove nothing; a suggestion (reason, drafted message, urgency flag) appears only on distinctive signs such as a wreck, a tow truck or a gate in frame, and otherwise the person picks the reason. Measured on a real car photo on an emulator: no suggestion. The suggestion rides to the scan page in the URL fragment (never sent to a server) and the sender still reviews and sends it.
3. **Language bridge. (Built.)** In an alert thread, a stranger's message has a *Translate* action: the language is detected and translated into the app's language by ML Kit models on the phone (a ~30 MB pack per language downloads once). The owner can also dictate a reply with the phone's speech recogniser. Going the other way, the scan page sends the stranger's chosen language with the alert, and the owner's quick replies are sent in that language from the app's own translation tables (no machine translation), so a Kannada speaker gets "2 ನಿಮಿಷದಲ್ಲಿ ಬರುತ್ತೇನೆ" even when the owner's app is in English. Free-text replies, typed or spoken, are translated into the stranger's language on the phone too, with a preview ("They will read: …" next to what you wrote) before anything is sent; verified on an Android 15 emulator. Voice notes from the *stranger* are not handled, since the scan page has no on-device model.

## Repository

```
app/          Flutter app (Android first)
  lib/data/       AppState (all server calls), models, car catalog
  lib/screens/    17 screens
  lib/services/   notifications, push, parking, garage log, wallet, trip share, PDF, crash detector
  lib/widgets/    shared components + motion primitives
  lib/l10n.dart   tr() and language switching; translations in assets/l10n/*.json
web/          Scan page (index.html) and live-trip viewer (trip.html): static, 4 languages
supabase/
  migrations/     schema, RLS, grants, RPCs
  functions/      scan (strangers' API), notify (society push), _shared/push.ts (FCM)
  tests/e2e.mjs   109 black-box checks against a running stack
docs/         Roadmap notes
```

## Run locally

Needs Docker, the Supabase CLI, Node 20+ and Flutter 3.44; JDK 17 for Android builds.

```bash
# 1. Backend
supabase start && supabase db reset
supabase functions serve --no-verify-jwt --env-file supabase/functions/.env.local

# 2. Backend tests: privacy/RLS, blocking, lockout, family, photos, medical, society, trips
node supabase/tests/e2e.mjs

# 3. Scan and trip pages on :8093 (serves config.local.js when present)
python3 web/serve.py                       # /t/<TAG CODE> and /trip#<TOKEN>

# 4. App (on-device ML checks need an emulator/phone: adb push app/integration_test/assets/plate.png /data/local/tmp/ && flutter test integration_test -d <device>)
cd app && flutter test
flutter run -d chrome --dart-define=SCAN_BASE_URL=http://127.0.0.1:8093   # quickest UI loop
flutter build apk --debug                                                # emulator reaches the host at 10.0.2.2
```

`supabase/functions/.env.local` sets `SCAN_IP_HOP=first`, which trusts the client-sent IP so the tests can simulate many senders. **Never use it in production.**

## Configure your own backend

The repo ships with placeholders, not a live backend:

- `web/config.js`: set `supabaseUrl` and `anonKey` (the publishable key is public by design).
- `app/lib/config.dart`: `scanBaseUrl` and `appUrl` default to `connect.example.com`; pass `--dart-define=SCAN_BASE_URL=...` or change the defaults to your domain. Printed QR stickers can't be changed, so pick the domain before printing.

```bash
supabase link --project-ref <your-project-ref>
supabase secrets set SCAN_IP_SALT=$(openssl rand -hex 32)   # without it `scan` returns 503
supabase db push
supabase functions deploy scan notify --no-verify-jwt
# host web/ on Vercel (rewrites in web/vercel.json)

# --split-per-abi: arm64 is ~68 MB; one fat APK is ~180 MB because of ML Kit
cd app && flutter build apk --release --split-per-abi \
  --dart-define=SUPABASE_URL=https://<your-project-ref>.supabase.co \
  --dart-define=SUPABASE_ANON_KEY=<publishable key> \
  --dart-define=SCAN_BASE_URL=https://<your-domain>
```

Push is optional: create a Firebase project with Android app `app.connectcar.connect`, add the four `FIREBASE_*` dart-defines, and `supabase secrets set FCM_SERVICE_ACCOUNT="$(cat key.json)"`.

## Known gaps

- **Push isn't switched on** until a Firebase project exists; until then alerts only notify while the app process is alive.
- **SOS opens the SMS app pre-filled** and can't send silently: Play only grants SEND_SMS to default SMS apps.
- **Crash detection runs only while Drive Mode is on screen** (4 g threshold, 15 s countdown, not validated against real crashes).
- **Accounts live on one phone**: reinstalling loses the car.
- Several cars per account: switch from the chips at the top of Garage. Alerts are account-wide, and local logs (parking, fuel, documents) are shared across cars.
- **Translations** have not had a native-speaker review.
- Car dimensions are typical figures for 39 popular models, shown as editable estimates.
- Account deletion (Garage → Delete my account) and a privacy page (`web/privacy.html`, served at `/privacy`) exist.
