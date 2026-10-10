# Drive Mode road scan

When you tap **Start Drive Mode**, the app also watches the road through the rear camera and notes
**potholes**, **triple riding** and **riders without helmets**. It all runs on the phone's GPU. Nothing
is uploaded.

## What you see

- **Safety tab:** a switch, "Scan the road with the camera" (on by default, remembered).
- **Drive Mode screen:** one card under "Watching for crashes" with a **live view** of what the camera
  sees, with boxes drawn on the people, bikes, vehicles, potholes and any flagged violation, then the
  scan state, live counts of potholes and violations, and the last thing caught. If the phone is
  getting hot the card says so; the scan slows itself and pauses at Android's "critical" thermal level.
- **Stop:** if the scan caught anything, a **Drive report** opens with each photo, the time, the number
  plate (when it could be read) and an **Open map** button.
- A notification ("Drive Mode is scanning the road") stays up while the camera runs, so it keeps
  working with the screen off.

## Privacy

Photos, short before/after clips and GPS positions are kept in the app's own storage
(`Android/data/<app id>/files/events`) and **deleted after 7 days**, like alert photos. No network
calls. Turning the switch off means the camera is never opened.

## How it works

```
DriveModeScreen ──MethodChannel "connect/roadguard"──► MainActivity ──► RoadGuardBridge
                                                                           │
   DetectionService (foreground, camera|location) ──► CameraRunner ──► Pipeline
        Pipeline: pothole YOLOv8n ─┐
                  COCO YOLOv8n ────┼─ ncnn + Vulkan on the phone GPU
                  helmet YOLOv8n ──┤  (tracker, rules, evidence writer on the CPU)
                  plate YOLOv8n ───┘  plate text: ML Kit, on device
```

- Native code: `app/android/app/src/main/cpp` (ncnn wrapper) and
  `app/android/app/src/main/kotlin/com/iqoo/roadguard` (camera, tracking, rules, evidence).
- Models: `app/android/app/src/main/assets/roadguard/*.param|bin` (~47 MB).
- Dart: `lib/services/roadguard.dart`, `lib/screens/drive_report_screen.dart`, and the Drive Mode
  changes in `lib/screens/safety_tab.dart`.
- Every call from Dart is guarded. On an emulator, an unsupported phone or without camera permission
  the panel says so and Drive Mode keeps doing crash detection exactly as before.

## Building

```
cd app
bash tool/get_ncnn.sh          # once: downloads the prebuilt ncnn libraries (not committed)
flutter build apk --debug --target-platform android-arm64
```

Needs the Android NDK and CMake 3.22.1 (both from the SDK manager). Without a backend, build the lab
entry point, which opens the real Safety tab with a made-up car and contact:

```
CONNECT_ID_SUFFIX=.rg flutter build apk --debug --target-platform android-arm64 -t tool/drive_lab.dart
```

**Lab demo feed.** To test the whole screen without pointing a camera at a road, give the lab a folder
of JPEG frames (one sub-folder per clip) and it plays them through the same pipeline instead of the
camera, in a loop:

```
# frames: <app files>/demo/<clip>/00000.jpg, 00001.jpg ...
adb shell mkdir -p /sdcard/Android/data/app.connectcar.connect.rg/files/demo
adb push my_clip_frames /sdcard/Android/data/app.connectcar.connect.rg/files/demo/
MSYS_NO_PATHCONV=1 CONNECT_ID_SUFFIX=.rg flutter build apk --debug --target-platform android-arm64 \
  -t tool/drive_lab.dart --dart-define=DEMO_DIR=/sdcard/Android/data/app.connectcar.connect.rg/files/demo
```

The app itself never passes a demo folder; only `tool/drive_lab.dart` does.

## What it can and cannot do (measured)

Tested on an iQOO 15 (Snapdragon 8 Elite Gen 5, Adreno 840):

| | |
| --- | --- |
| Speed | Vehicle and rider detector is YOLOv8s at 640 px (~60 ms a frame); with the pothole model the whole frame takes ~70 ms, so about 13 FPS. The phone stayed at thermal status 0 for a minute of continuous use. The governor lowers the rate further as it warms. (The earlier small detector ran ~30 FPS but missed far-away riders.) |
| Heat | Reaches Android thermal status 2 within a couple of minutes of full load, with the phone charging |
| Potholes | Own YOLOv8n fine-tuned on ~2,800 dashcam frames: mAP50 0.45 on held-out frames; the phone matches the laptop (0.449 vs 0.450) |
| Plates (detector) | mAP50 0.76 on 300 Hugging Face plate-test images (not India-specific) |
| Triple riding / no helmet | Worked on clear, close bikes in 7 public Indian clips. About 7 of 11 events looked right by eye (no labels). Weak on distant bikes; a pedestrian beside a parked scooter was read as a rider before the final filters. |
| Plate text | **Read 0 of 10** at video distances: plates are a few pixels wide in 720p. Needs a full-resolution still at the moment of violation (not built). |
| Potholes on non-dashcam views | Unreliable (1 of 9 pothole events was real on CCTV-style clips). Filters on size and position help but do not solve it. |

These are suggestions for the driver to check, not evidence of an offence.

## Open items

- **Licences.** Ultralytics YOLOv8 is AGPL-3.0. Check that against how this app is distributed. The
  helmet (Apache-2.0) and plate (MIT) weights came from public Hugging Face repos; the pothole data is
  Figshare and Mendeley (check their terms before redistributing the trained model).
- **Hindi, Kannada and Tamil strings** for this feature were machine-written. Please have a native
  speaker review them.
- Models are stored uncompressed (47 MB). Half-precision files would roughly halve that.
- Not tested on a bike in motion yet.

## AI second opinion (optional, off by default)

The on-device models are good at finding "a bike with people on it" and weak at the judgement calls
(is that a third person, is that rider bare-headed). With **Double-check with AI** on, the phone sends
**one tight crop of a suspect vehicle** (never the whole frame) to a vision model on OpenRouter and gets
back how many people are seated on it and who wears a helmet. A confident answer (>= 0.75) decides; if
it is off, offline, capped or times out, the on-device rules apply exactly as before.

- **What is sent:** a JPEG crop of one vehicle and its seated riders, at most 512 px. It can show faces
  and plates, so this is opt-in and the switch says so. Everything else still stays on the phone.
- **Limits:** one check per vehicle, at most one every 1.2 s, 150 per drive, 15 s timeout.
- **Cost:** about 0.005 US cents a check on `google/gemini-2.5-flash-lite` (19 checks on the demo clips
  cost $0.0012). The app counts the real cost OpenRouter reports.
- **Key:** read at build time from the git-ignored `android/local.properties`
  (`roadguard.openrouter.key=...`) or the `OPENROUTER_API_KEY` environment variable. **A key inside an APK
  can be extracted.** For anything beyond a demo, keep the key on a server (for example a Supabase edge
  function that checks the signed-in user and rate-limits) and set a credit limit on the key in the
  OpenRouter dashboard. Rotate any key that has been shared.

Measured, on real data:

| Test | On-device | AI (`gemini-2.5-flash-lite`) |
| --- | --- | --- |
| Bare head or not, 60 labeled helmet photos | 88% right | **95% right** |
| Real bike crops from 7 Indian clips, people on the bike | the rule counted 2 on a bike carrying 3 | counted 3 on all 8 crops of the two genuine three-up bikes |
| The "4 people on a motorcycle" bike | missed entirely | caught |

A tighter prompt ("count only people sitting on the vehicle, ignore bystanders") cut false "3 people"
answers on the real crops from 12 to 9. On tiny far-away bikes the AI guesses with a flat confidence;
those answers came back at 0.6 while correct ones were 0.9 or higher, so 0.75 filters them.
These are small tests, judged by eye on 7 clips, not a benchmark.

## Reporting a violation (authorised, plate must be clear)

A violation can be sent to a reporting webhook, but only when **a person authorises it** and the report
passes three checks. Nothing is sent automatically.

1. **Authorise.** In the Drive report, each triple-riding or no-helmet event has an **Authorise and
   report** button. It opens a dialog that says what will be sent; nothing leaves the phone until the
   button in that dialog is pressed.
2. **The plate must be clear.** A plate crop must exist **and** the text read from it must be a valid
   Indian plate (for example `KA01AB1234`). Otherwise the card says "Plate not clear enough to report"
   and the report cannot be sent, because a report without a clear plate identifies nobody.
3. **There must be a location.** The event needs a GPS fix so that latitude and longitude can be sent.
   Otherwise the card says "No location was recorded".

Potholes are never reported this way, and each violation can be reported once.

**What is sent** (a `multipart/form-data` POST):

| Part | Content |
| --- | --- |
| `frame` (file) | the evidence photo, with the violation marked |
| `plate` (file) | the cropped number plate |
| `latitude`, `longitude` | where it happened |
| `plate_number`, `plate_clear` | the plate text and `true` |
| `violation` | `triple_riding` or `no_helmet` |
| `timestamp` | when, in UTC (ISO 8601) |
| `event_id`, `authorised`, `source`, `note` | the event, `true`, `connect-drive-mode`, and how it was decided |

**Setup.** Reporting is hidden unless the build is given an address. Keep the real address out of the
repository:

```
flutter build apk --dart-define=VIOLATION_WEBHOOK_URL=https://your-host/webhook/traffic-violation
```

Things to decide before real use:

- **Privacy and law.** A report contains a photo of someone else's vehicle, their number plate and a
  location. Check the rules that apply (in India, the Digital Personal Data Protection Act) and who
  receives and keeps these reports.
- **Authentication.** An open webhook accepts anything from anyone. Protect it with a secret header or
  a token that the app sends, and rate-limit it.
- **Clear plates are rare at road distance.** At normal video distance, plates are a few pixels wide;
  on the test clips none of the plates could be read. A report is only possible when the plate really is
  readable, which today means close, sharp, well-lit vehicles. The full-resolution capture below is meant
  to raise this; it has been run on a phone but not yet shown reading a real plate.

## Full-resolution plate capture

When a violation is confirmed, the app takes one full-resolution photo (about 12 MP; 3264x2448 on the
iQOO 15) through CameraX `ImageCapture`, which runs alongside the analysis stream. The vehicle is cut out
of that photo (`BitmapRegionDecoder`, so the whole image is never held in memory), a plate detector looks
for the plate in it, and the plate is cut from the full-resolution pixels and read with ML Kit.

- The vehicle's box in the analysis frame is mapped into the stored JPEG by `StillMapper`, allowing for the
  JPEG's rotation. It is unit-tested for all four rotations.
- If the first photo misses because the vehicle moved, it tries once more where the tracker now has it.
- Saved with the event: `plate.jpg` (full-resolution crop), `vehicle_hr.jpg` (vehicle, longest side at most
  1600 px), and `plateHiRes` in the record. The report sends the vehicle photo too.
- One pass at a time and at least 1.2 s apart, so it cannot pile up behind a busy road.

Lab test hook (lab build only, while Drive Mode is running): saves a capture event from whatever the
camera sees now, to check the plate crop and text.

```
adb shell "run-as <package> am start-foreground-service --user 0 -n <package>/com.iqoo.roadguard.DetectionService -a com.iqoo.roadguard.TEST_CAPTURE"
```

## Scanning a video

**Scan a video instead** (under Start Drive Mode on the Safety tab) opens the phone's video picker and runs
the road scan on that video in place of the camera, for one drive. Frames are taken about every 66 ms of
video time, up to 1280 px on the long side, and the video loops until you stop. The live card is labelled
"Test feed, not the camera". There is no full-resolution still in this mode, so a plate is read from the
video frame itself.

## AI answers and the evidence photo

The AI takes a second or two to answer. A vehicle that has moved or fallen by then may have a new track,
so answers are queued and acted on at the next frame, at the vehicle's last known place. The event's
photo is the frame the AI was asked about, not the later frame the answer arrived on.

Diagnostics: the log prints, once a second, how many bikes and people were seen, the most riders on one
bike, and the helmet checks with their helmet / no-helmet counts, plus each AI answer
(`adb logcat -s RoadGuard`).
