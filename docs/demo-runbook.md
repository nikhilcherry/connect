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
3. **Plate is the QR (50 s).** Owner phone: Garage → *Reach a car by its plate* → **Live camera view**. Point at a plate: our own detector draws a box on it in real time (it shows the milliseconds). Tap the box: it reads the plate and finds the car. *Verified on an emulator camera scene, not a real iQOO camera.* Fallback: *Photograph the plate*, or type it; the lookup is identical.
4. **Translate (30 s).** Stranger sends a Hindi message; tap **Translate** → English, "Translated on this phone". Say it's offline after the pack downloads.
5. **Damage and cost (30 s, optional).** Garage → *Check damage and cost* → pick a photo of a scratched or dented car. The phone draws boxes and shows a rough ₹ range for the user's car; *Save report as PDF* shares an evidence report. *Verified on an emulator with a held-out dataset photo; accuracy is modest (mAP50 0.37), so use a clear photo.*
6. **Voice reply (20 s).** Tap the mic and speak a reply. *Recogniser starts (verified); spoken transcription not verified on a real phone.* Fallback: tap a quick reply.
7. **Privacy line (20 s).** Strangers see colour, make and model only; photos are read on the phone and never uploaded; Garage → *Delete my account* removes everything.
8. **Close (10 s).** "Every car gets a voice."

## Honest answers to likely questions
- *Did you build ML models?* Yes, three, all on the phone with ONNX Runtime (`ml/README.md`): a plate detector (YOLO11n, trained on 8,823 photos then fine-tuned for Indian close-ups; 0.73 mAP50 on 47 real Indian phone photos, up from 0.64), our own plate reader (CRNN trained on 360k synthetic Indian plates; 60.7% exact on 150 held-out real plates vs 49.3% for ML Kit with the same repair rules), and a damage detector (mAP50 0.37, only four classes reliable). Say the test sets are small and that the cost range is a hand-set estimate, not learned.
- *How good is the plate reader really?* Right first try about 65% of the time on held-out real Indian crops, and the correct plate is among the one or two candidates shown 73% of the time. It is not ML-Kit-beating everywhere: ML Kit is a bit more precise when it answers, so the app uses both.
- *Is the cost estimate accurate?* No. It is a rough range from a hand-set table scaled by car size, brand and damaged area, shown with a get-a-quote note.
- *Does it understand a photo of the problem?* Only on clear signs (wreck, tow truck, a gate in frame). ML Kit's base model labels every car "Vehicle, Car, Wheel, Road, Bumper", so for anything else it leaves the choice to the person. Say so before they find out.
- *Can someone squat my plate?* A plate claimed by two accounts is refused by the lookup, so a message is never routed to a possible squatter. Proof of ownership (RC photo) is the next step.
- *Cost?* ₹0 a month on free tiers; the free Supabase plan caps live connections at 200 and the app disconnects in the background once push is on.
- *Push when the app is closed?* Needs a Firebase project; until then alerts arrive live while the app process is alive (verified, including while backgrounded).
- *Release signing?* Debug-signed, fine for a demo, not for the Play Store.
