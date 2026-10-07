"""Score a plate detector on a YOLO-format set.

    python eval_detector.py <weights .pt|.onnx> <data.yaml> [imgsz ...]

Prints mAP50, mAP50-95, precision, recall for each image size.
"""
import os
import sys

from ultralytics import YOLO

weights, data = sys.argv[1], sys.argv[2]
sizes = [int(s) for s in sys.argv[3:]] or [416]
model = YOLO(weights)
for s in sizes:
    m = model.val(data=data, imgsz=s, verbose=False, plots=False, conf=0.001, device=os.environ.get("DEVICE", "") or None)
    print(f"RESULT weights={weights} data={data} imgsz={s} mAP50={m.box.map50:.3f} mAP50-95={m.box.map:.3f} P={m.box.mp:.3f} R={m.box.mr:.3f}")
