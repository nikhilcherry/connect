# Connect plate detector (our own model)

A YOLO11n object detector we trained to find number plates in a photo or a live
camera frame, running **on the phone** with ONNX Runtime. It is the model behind
the live "who's on Connect" camera view and the first stage of plate-as-QR:
find the plate, then let the on-device text reader (ML Kit) read just that crop.

| | |
| --- | --- |
| **Architecture** | YOLO11n (Ultralytics 8.4), 1 class `license_plate`, 2.58 M parameters, 6.4 GFLOPs |
| **Input / output** | 416×416 letterboxed RGB → `[1, 5, 3549]` (x, y, w, h, score per candidate) |
| **Size on the phone** | 10 MB ONNX (`app/assets/models/plate_n.onnx`) |
| **Trained** | 40 epochs, 11 minutes on a laptop RTX 5050, from the pretrained `yolo11n.pt` |
| **Data** | 8,823 photos: train 6,176 / valid 1,765 / test 882 |

## Scores (held-out test split, 882 images / 902 plates)

| mAP50 | mAP50-95 | Precision | Recall |
| --- | --- | --- | --- |
| **0.991** | 0.709 | 0.992 | 0.977 |

Validation split (1,765 images): mAP50 0.974. Per-epoch numbers are in
`results/results.csv`.

**On a phone-class CPU path (Android 15 emulator, x86_64):** about 70 ms per
frame, and on a real photo it found the plate with confidence 0.89 and an IoU of
0.893 against the ground-truth box (`app/integration_test/ml_test.dart`).

## Data and licence

[`keremberke/license-plate-object-detection`](https://huggingface.co/datasets/keremberke/license-plate-object-detection)
on Hugging Face (Roboflow export of "Vehicle Registration Plates"), **CC BY 4.0**.
The photos are international and mostly from outside India. The data is not in
this repository.

## Reproduce

```bash
# 1. data: download train/valid/test.zip from the dataset page, unzip into
#    ~/ml-data/plates/raw/{train,valid,test}, then convert COCO → YOLO
python3 prepare_data.py ~/ml-data/plates

# 2. train (uses the GPU venv from the Drone_Ml project)
~/Projects/Drone_Ml/venv/bin/python train_plate_detector.py

# 3. export for the phone (opset 12 for ONNX Runtime 1.15)
python -c "from ultralytics import YOLO; YOLO('runs/plate_n/weights/best.pt').export(format='onnx', imgsz=416, opset=12, simplify=True)"
cp runs/plate_n/weights/best.onnx ../app/assets/models/plate_n.onnx
```

`weights/plate_n.pt` is the trained PyTorch checkpoint (5 MB).

## What it is and isn't good for

- **Good:** locating plates, several at once, so the camera view can draw a box
  on each and the text reader can read each crop on its own.
- **Not magic for tiny plates:** a plate only ~40 px wide has too little detail
  for any reader. On a real Bangalore street photo the detector found such a
  plate, the crop read as "KA02 N701…", and reading the whole photo got the full
  number, so the pipeline uses the crop when it yields a plate and otherwise
  falls back to the whole photo.
- **Indian plates:** the training photos are mostly not Indian. It has not been
  scored on an Indian test set; fine-tuning on a few hundred Indian plates is the
  obvious next step (the training script takes `PLATES_YAML` and `BASE`).
- **No claim about reading the characters.** The detector only localises; the
  characters are read by ML Kit.

## Licences

- Data: CC BY 4.0 (credit: Roboflow "Vehicle Registration Plates", via
  `keremberke/license-plate-object-detection`). `app/integration_test/assets/car_with_plate.jpg`
  is one photo from that dataset's test split.
- Training code: **Ultralytics YOLO is AGPL-3.0.** Fine for a hackathon and
  open-source release; a closed commercial product would need an Ultralytics
  Enterprise licence or the same recipe on a permissively licensed detector.
- Runtime: ONNX Runtime (MIT).

## Emulator note

`onnxruntime` 1.4.1 ships only ARM libraries. To test on an x86_64 emulator,
extract `jni/x86_64/libonnxruntime.so` from Microsoft's official
`onnxruntime-android` **1.15.1** AAR (the version the plugin bundles) into
`app/android/app/src/main/jniLibs/x86_64/` (git-ignored). Real phones use the
plugin's ARM libraries and need nothing extra.
