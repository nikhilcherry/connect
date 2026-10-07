# Connect's own models

Three models we trained, running **on the phone** with ONNX Runtime, plus a rule-based
cost estimator. Everything below was measured; where a number is weak it says so.

| | What it does | Size on the phone | Headline number |
| --- | --- | --- | --- |
| **Plate detector** | finds plates in a photo or live frame | 4.3 MB (INT8) | mAP50 **0.732** on real Indian phone photos (0.643 before fine-tuning) |
| **Plate reader** | reads the characters of a cropped plate | 3.4 MB | **60.7%** exact on 150 held-out real Indian plates (ML Kit + our parser: 49.3%) |
| **Damage detector** | finds dents, scratches, cracks, shattered glass | 10.5 MB | mAP50 **0.365**, honest and modest (see below) |
| **Cost estimator** | rough repair cost range from the findings | n/a (hand-set table) | not learned, not a quote |

## 1. Plate detector (YOLO11n, 2.6 M parameters)

Trained in two stages. Stage 1 on 8,823 mostly non-Indian plate photos
([`keremberke/license-plate-object-detection`](https://huggingface.co/datasets/keremberke/license-plate-object-detection),
CC BY 4.0): test mAP50 **0.991**. That number is flattering. On **real Indian phone
photos** it fell to 0.65-0.69.

**Test set for the Indian claim:** the 47 phone photos / 52 plates of the Datacluster
"Indian Number Plates" free sample (CC BY-NC-ND 4.0, for evaluation only). They are
**never trained on and never used to pick a checkpoint.**

Looking at the misses showed why: those photos are hand-held close-ups of worn, dark,
rusty two-wheeler plates that fill 25-75% of the frame; training had small CCTV-gate
plates. So:

| Variant | Real Indian photos mAP50 (416) | (640) | Original test mAP50 (416) |
| --- | --- | --- | --- |
| Stage 1 only (baseline) | 0.653 | 0.689 | 0.991 |
| + Indian plates pasted at CCTV scale (`make_indian_scenes.py`) | 0.721 | 0.663 | n/a |
| **+ close-up / dirty / negative data (`make_indian_closeups.py`)** | **0.753** | **0.743** | 0.983 |

The close-up variant is the shipped one: it was the planned fix for the failure we saw,
and it is the best at 416 (the size the phone runs). Small test (47 photos), so read
these as "clearly better than before", not as a precise figure. The original-test cost
of the fine-tune is under one point.

**As deployed** (ONNX at 416, the format the phone runs): baseline float 0.643, close-up
float 0.719, **close-up INT8 0.732**. ONNX numbers differ slightly from the PyTorch ones
above (different pre-processing at export), so compare within a column.

### Compression (`compress_detector.py`)

INT8 static quantisation with 200 calibration images. **Naive INT8 breaks the detector
(mAP 0):** the head mixes box coordinates in the hundreds with probabilities in 0..1 under
one scale. Keeping the detection head (`model.23`) in float and quantising the rest:

| | Size | Speed (ORT CPU, 1 thread, laptop) | Test mAP50 | Real Indian mAP50 |
| --- | --- | --- | --- | --- |
| Float | 10.5 MB | 31 ms | 0.983 | 0.719 |
| **INT8, head in float** | **4.3 MB** | **19 ms** | 0.983 | 0.732 |

Speed is an x86 proxy; real-phone latency is untested.

## 2. Plate reader (CRNN + CTC, 0.87 M parameters)

Input: gray 32×160 (two-row plates split into halves and laid side by side,
`canon.py`; the Dart port is checked against golden vectors). Trained on
**360,000 synthetic Indian plates** (`synth_plates.py`: real state/series formats, white /
yellow / green / black plates, one- and two-row, IND strip, rotation, perspective,
glare, dirt, blur, noise, JPEG) plus augmented copies of real crops, 14,000 steps, 14
minutes on one GPU.

**Test set:** 150 real Indian plate crops from
[`zenitsu09/indian-number-plate`](https://huggingface.co/datasets/zenitsu09/indian-number-plate),
**split by plate text** so no plate appears in both train and test (the dataset holds each
plate several times as augmented copies); clean labels only; one copy per plate.
ML Kit was measured **before** training, on the same crops, upscaled the way the app does.

| Reader | Exact match (n=150) | 95% interval |
| --- | --- | --- |
| ML Kit, raw text | 46 (30.7%) | |
| ML Kit + our plate-pattern repair | 74 (49.3%) | 41.3-57.3% |
| **Our reader** | **91 (60.7%)** | 52.7-68.0% |
| **Ours if it is a valid plate, else ML Kit** (what the app does) | **98 (65.3%)** | |

Paired: ours right where ML Kit was wrong 35 times, the reverse 18 times (sign test
p = 0.027). ML Kit is slightly more precise when it answers (76% vs 71%) but answers on
only 97 of 150. The Dart/ONNX version run on the Android emulator scores the same 91/150
at 18 ms per plate.

Limits: 150 plates is a small test; the real training crops come from a dataset whose
licence is unspecified (research use, not redistributed, none of its pixels committed);
fonts are system fonts, not the real HSRP typeface.

## 3. Damage detector (YOLO11n, 6 classes, 512 px)

Trained on [`tugberkkalay/autodamageiq-vehicle-damage-dataset`](https://huggingface.co/datasets/tugberkkalay/autodamageiq-vehicle-damage-dataset)
(10,000 train / 2,094 val photos). The page says CC BY 4.0 but it is assembled from CarDD
(research / non-commercial) and VehiDE with GPT-4o-assisted labels, so treat this model as
**research-grade**.

| Class | mAP50 (val) | Training labels |
| --- | --- | --- |
| shattered glass | **0.662** | 1,282 |
| crack | 0.318 | 1,488 |
| dent | 0.266 | 5,413 |
| scratch | 0.212 | 13,413 |
| broken lamp | not scored (none in val) | **56** |
| flat tyre | not scored (none in val) | **4** |
| **all (4 scored classes)** | **0.365** (float) / 0.352 (INT8) | |

This is a hard task for a nano model: dents and scratches are small and subtle. **Only four
classes are reliable**; lamp and tyre had too few examples, and the app says so. The model
on-device reproduces the Python result (scratch 0.72 / crack 0.42 vs 0.72 / 0.45 on a
held-out photo).

## 4. Cost estimator (`app/lib/services/damage_cost.dart`)

Not a model. A rough INR range per damage type from a **hand-set** table (an assumption,
not learned from data or from real quotes), scaled by car size (length from the
catalogue), brand tier, and how large each damaged area is in the photo; extra damage of
one kind overlaps (each costs 70% of the one before). Shown as a range, never a quote, with
a "get a written quote" note. Change the numbers in one place: `baseCostInr`.

## Reproduce

```bash
# data (not in the repo): see the dataset links and licences above
python3 prepare_data.py ~/ml-data/plates                      # plate detector stage 1 (COCO -> YOLO)
python3 prepare_dc_eval.py ~/ml-data/dc-eval                  # Indian phone photos, EVALUATION ONLY
python3 indian_plates.py ~/ml-data/indian-plates/train.parquet ~/ml-data/indian-plates   # real crops split by plate
python3 prepare_damage.py ~/ml-data/damage/autodamageiq

PY=~/Projects/Drone_Ml/venv/bin/python                         # GPU venv reused from the Drone_Ml project
$PY train_plate_detector.py                                    # stage 1
$PY make_indian_closeups.py ~/ml-data/plates ~/ml-data/indian-plates ~/ml-data/indian-closeups 3000
PLATES_YAML=... BASE=weights/plate_n.pt NAME=plate_closeup EPOCHS=30 LR0=0.004 TEST_SPLIT=0 $PY train_plate_detector.py
$PY gen_ocr_data.py 360000 ~/ml-data/indian-plates/ocr_set && $PY train_ocr.py 14000
PLATES_YAML=.../damage.yaml NAME=damage_n IMGSZ=512 TEST_SPLIT=0 $PY train_plate_detector.py
$PY eval_detector.py <weights> <data.yaml> 416                 # score a detector
$PY compress_detector.py <fp32.onnx> <calibration images> <int8.onnx>
$PY export_reader.py weights/plate_reader.pt ../app/assets/models/plate_reader.onnx
```

Raw training curves and logs are in `results/`; weights in `weights/` (small `.pt` files).

## Gotchas we hit

- **A model that loads on the laptop can be rejected on the phone.** The phone's ONNX Runtime
  is 1.15.1; the newer desktop `onnx` / `onnxruntime` used for quantisation stamps extra
  operator domains (`ai.onnx.ml` v5, `ai.onnx.training`, `com.microsoft.nchwc` ...) that 1.15
  refuses. It showed up as "the camera isn't available" in the live view, and only a run on the
  device logged the real error. `compress_detector.py` and `fix_opset.py` now strip those
  domains (checking no node uses them), and `app/test/shipped_models_test.dart` reads the header
  of every shipped model in CI, so it cannot ship silently again.
- **Naive INT8 breaks a YOLO head** (see Compression).
- The training machine has little free RAM: pre-generate data (`gen_ocr_data.py`) instead of
  loading PyTorch in many data-loader workers.

## Emulator notes

`onnxruntime` 1.4.1 ships only ARM libraries. To test on an x86_64 emulator, extract
`jni/x86_64/libonnxruntime.so` from Microsoft's official `onnxruntime-android` **1.15.1**
AAR (the version the plugin bundles) into `app/android/app/src/main/jniLibs/x86_64/`
(git-ignored). `make_test_poster.py` builds the virtual-camera scene for the live view.
Real phones use the plugin's ARM libraries and need nothing extra.

## Licences

- Plate detector stage 1 data: CC BY 4.0 (Roboflow "Vehicle Registration Plates").
- Indian plate crops: licence unspecified (research use only). Datacluster sample: CC BY-NC-ND 4.0, evaluation only.
- Damage data: see above (research-grade).
- **Ultralytics YOLO is AGPL-3.0.** Fine for a hackathon and open-source release; a closed
  commercial product would need an Ultralytics Enterprise licence or the same recipe on a
  permissively licensed detector.
- Runtime: ONNX Runtime (MIT).
