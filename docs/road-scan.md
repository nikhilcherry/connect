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
