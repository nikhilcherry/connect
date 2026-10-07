# Connect

**Anyone can reach you about your car, without either side sharing a phone number.**

A QR tag on the windshield turns "whose car is this?" into a private two-way chat. A stranger scans it with any phone camera, picks what's wrong (blocking a gate, lights on, being towed, an accident), proves they're standing at the car, and the owner and their family get the message instantly. Around that core, the app gives owners reasons to open it every week: parking, renewals, fuel and service logs, family safety and live trip sharing.

| | |
| --- | --- |
| **Platform** | Android (Flutter) + static web scan page + Supabase backend |
| **Running cost** | ₹0 / month on free tiers |
| **Languages** | English, हिन्दी, ಕನ್ನಡ, தமிழ் (app, scan page and trip page) |
| **Tests** | 112 backend end-to-end checks · 41 app tests |

---

## What the app does

### For the person at the car (no app needed)

1. **Scan** the tag: the page shows only the car's colour, make and model.
2. **Pick a reason**: blocking a car, lights on, being towed, window open, accident or damage, or a note. Optionally attach a photo, which is shrunk in the browser.
3. **Prove you're there**: type the last 4 characters of the number plate. A shared photo of the sticker isn't enough.
4. **Chat**: quick replies or free text; see "Owner is on the way", the owner's "back by 6:30" status and, on accident reports, any medical info the owner chose to share.

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
- **Family sharing**: a one-time 6-character code adds up to 5 people. Everyone gets the alerts; only the owner can change the plate or the tag.
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

1. **The plate is the QR. (Built.)** Garage → *Reach a car by its plate*: on-device OCR (ML Kit) reads a number plate, and if the owner is on Connect it opens the masked chat, so no sticker is needed. The photo never leaves the phone; the `plate` action only returns a tag code, shares the wrong-guess rate limit with plate checks, and is covered by the e2e suite.
2. **Situation understanding.** A photo of the problem (blocked in, lights on, flat tyre, dent) is classified by an on-device vision model, which drafts a clear message with an urgency level.
3. **Language bridge.** A voice note in Kannada, Hindi or Tamil is transcribed and translated on-device, so each side reads the other in their own language.

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

# 4. App
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

cd app && flutter build apk --release \
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
- **One vehicle per account** in the UI (the schema supports many).
- **Translations** have not had a native-speaker review.
- Car dimensions are typical figures for 39 popular models, shown as editable estimates.
- No real app icon yet (Flutter's default), no account deletion, no privacy policy page.
