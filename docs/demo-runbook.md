# Finals demo runbook

A 3-minute live demo using only flows that were run end to end. Where something was not verified on a real phone it says so, with a fallback.

## Before you go on stage
- Install the **arm64 release APK** (`app-arm64-v8a-release.apk`, ~68 MB) or the debug APK on the iQOO phone. Build: `cd app && flutter build apk --release --split-per-abi` with `--dart-define=SUPABASE_URL=… SUPABASE_ANON_KEY=… SCAN_BASE_URL=…` pointing at a real backend (see README).
- Open the app once on Wi-Fi: allow notifications, and let one translation pack download (open any thread, tap **Translate** on a Hindi message) so it works offline on stage.
- Add the demo car. Keep a second phone (or a laptop browser) ready to play the stranger.
- Have the plate on screen or printed large for the OCR step; clean, well-lit, straight-on works best.

## The 3 minutes
1. **The problem (20 s).** "Blocked in, lights on, no number to call."
2. **Stranger scans the QR (40 s).** Second phone scans the tag, picks *Lights are on*, types the last 4 plate characters, sends. Owner phone buzzes. Reply "Coming in 2 minutes". Both sides never see a number.
3. **Plate is the QR (40 s).** Owner phone: Garage → *Reach a car by its plate* → photograph the plate. It reads on the phone, finds the car. *Verified on an emulator, not a real iQOO camera.* Fallback: type the plate; the lookup is identical.
4. **Translate (30 s).** Stranger sends a Hindi message; tap **Translate** → English, "Translated on this phone". Say it's offline after the pack downloads.
5. **Voice reply (20 s).** Tap the mic and speak a reply. *Recogniser starts (verified); spoken transcription not verified on a real phone.* Fallback: tap a quick reply.
6. **Privacy line (20 s).** Strangers see colour, make and model only; photos are read on the phone and never uploaded; Garage → *Delete my account* removes everything.
7. **Close (10 s).** "Every car gets a voice."

## Honest answers to likely questions
- *Does it understand a photo of the problem?* Only on clear signs (wreck, tow truck, a gate in frame). ML Kit's base model labels every car "Vehicle, Car, Wheel, Road, Bumper", so for anything else it leaves the choice to the person. Say so before they find out.
- *Can someone squat my plate?* A plate claimed by two accounts is refused by the lookup, so a message is never routed to a possible squatter. Proof of ownership (RC photo) is the next step.
- *Cost?* ₹0 a month on free tiers; the free Supabase plan caps live connections at 200 and the app disconnects in the background once push is on.
- *Push when the app is closed?* Needs a Firebase project; until then alerts arrive live while the app process is alive (verified, including while backgrounded).
- *Release signing?* Debug-signed, fine for a demo, not for the Play Store.
