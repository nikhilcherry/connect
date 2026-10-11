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

## Reporting a violation (authorised)

A violation can be sent to a reporting webhook, but only when **a person authorises it** and the report
passes two checks. Nothing is sent automatically.

1. **Authorise.** In the Drive report, each triple-riding or no-helmet event has an **Authorise and
   report** button. It opens a dialog that says what will be sent; nothing leaves the phone until the
   button in that dialog is pressed.
2. **There must be a location.** The event needs a GPS fix so that latitude and longitude can be sent.
   Otherwise the card says "No location was recorded".

Potholes are never reported this way, and each violation can be reported once.

**What is sent** (a `multipart/form-data` POST):

| Part | Content |
| --- | --- |
| `frame` (file) | the evidence photo, with the violation marked |
| `plate` (file) | the cropped number plate, only when one was found |
| `latitude`, `longitude` | where it happened |
| `plate_number`, `plate_clear` | the plate text (empty if it was not read) and `true` or `false` |
| `violation` | `triple_riding` or `no_helmet` |
| `timestamp` | when, in UTC (ISO 8601) |
| `event_id`, `authorised`, `source`, `note` | an anonymous event id, `true`, `connect-drive-mode`, and how it was decided |

**Anonymous.** A report carries no name, account, phone number or device id. The event id is a one-way hash
of the on-phone id and a random secret kept only on the phone, so reports from one phone cannot be linked
by it and it does not reveal how many were made. The time is to the second, the multipart boundary is
random, the user agent is a plain `connect-report`, and the photos carry no metadata. What remains is what
the report is for: the place and time of the violation, the photos of the vehicle and its riders, and the
plate text. The network can still see the sender's address, so the receiving service should not log it
(the console in `verifier/` does not).

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
- **Reports go out even when the plate was not read.** The photo, the violation, the time and the
  coordinates are sent, with `plate_number` empty and `plate_clear` `false`, so the workflow can tell
  these apart and a person can check the photo. At normal video distance plates are a few pixels wide and
  were not read on the test clips; the full-resolution capture below is meant to raise this, and has been
  run on a phone but not yet shown reading a real plate.

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

## Live dashcam input

**More ways to scan -> Use a dashcam or video -> Connect a dashcam** runs the same on-device road scan on a dashcam's live view in place
of the phone's own camera. Enter its live-view address, for example `http://192.168.1.254:8192`, after joining the
dashcam's Wi-Fi. The address is remembered for next time. The live card is labelled "Live from a dashcam" and shows
"Dashcam: <host>", "Connecting to the dashcam..." or "Dashcam connection lost. Reconnecting...".

- **What it reads:** MJPEG over plain HTTP, the live preview many Wi-Fi dashcams and phone-as-camera apps serve.
  RTSP (H.264) is the other common choice and is **not supported yet**; the app says so if you enter an `rtsp://`
  address. Which address your dashcam uses is in its manual; I have not tested a real dashcam.
- **How:** a plain socket request (Android blocks ordinary HTTP clients from cleartext in release apps, and a
  dashcam on its own Wi-Fi speaks plain HTTP). The reader keeps only the newest frame, so a slow phone never builds
  up delay, and it reconnects with a growing wait if the stream drops. A `user:pass@host` sign-in is sent as
  Basic auth. Chunked streams are refused with a clear message in the log.
- **Place and time:** the phone is in the car, so events take the phone's place and the moment they are seen, exactly
  as with its own camera. There is no full-resolution still in this mode, so a plate is read from the stream frame.
- **Internet while on the dashcam's Wi-Fi:** the AI double-check and reports need the internet. Android normally keeps
  mobile data for that when the Wi-Fi has none; check this on your phone before relying on it.
- **Try it without a dashcam:** `tools/dashcam_sim.py clip.mp4` serves any video as a live MJPEG stream. On USB, run
  `adb reverse tcp:8190 tcp:8190` and connect to `http://127.0.0.1:8190/video`; on Wi-Fi use this computer's address.
  It needs OpenCV and serves plain HTTP with no sign-in, so use a trusted network.

## Scanning dashcam footage

**Use a dashcam or video** (the last row of the Safety tab, under "More ways to scan") offers **Pick videos** (one or more clips)
or **Pick a folder** (every clip in it, and in sub-folders a few levels down, oldest name first). The road scan
then runs on those clips in place of the camera, one after another, each once. The live card is labelled
"Footage from a video, not the camera" and shows "Clip 2 of 7: name". When the last clip ends, the scan stops
by itself and the Drive report opens. Frames are taken about every 66 ms of video time, up to 1280 px on the
long side. There is no full-resolution still in this mode, so a plate is read from the video frame itself.

**Every event carries the clip's own time and place, never the phone's.** Footage was not filmed where and when
it is scanned, so:

- **Time.** The first timed fix of a GPS log beside the clip (satellite time) wins. Without one, the container's
  creation date if it is believable (an unset 1970 date is not), then the clock in the file name
  (`2023_1001_133850_001.MP4`, `VID_20231001_133850.mp4`; read as local time). If none gives a time, the event has
  none and **cannot be reported** ("The clip has no recorded time").
- **Place.** The container's own location tag, and/or a GPS log with the clip's name in the same folder
  (`.gpx`, or `.nmea` / `.log` / `.txt` with `$GPRMC` lines; found for clips picked as a folder). With a timed log,
  the fix nearest the moment in the clip is used, and only if it is within five minutes of it. If there is no
  place, the event has none and **cannot be reported** ("No location was recorded").
- A GPS log that is not this clip's trip is ignored, not guessed at.

What I have not seen: how a given dashcam brand stores GPS. Some write it inside a proprietary track of the video
file, which this does not read; a sidecar log or the container location tag is what is supported.

The scan still asks for camera permission, because the scan service is declared as a camera service.

## AI answers and the evidence photo

The AI takes a second or two to answer. A vehicle that has moved or fallen by then may have a new track,
so answers are queued and acted on at the next frame, at the vehicle's last known place. The event's
photo is the frame the AI was asked about, not the later frame the answer arrived on.

Diagnostics: the log prints, once a second, how many bikes and people were seen, the most riders on one
bike, and the helmet checks with their helmet / no-helmet counts, plus each AI answer
(`adb logcat -s RoadGuard`).
