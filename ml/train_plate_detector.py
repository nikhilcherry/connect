"""Train the Connect plate detector (YOLO11n, one class) on the prepared data.

    ~/Projects/Drone_Ml/venv/bin/python train_plate_detector.py

Reuses the GPU-enabled venv from Drone_Ml. Small on purpose (2.6 M parameters):
it must run in real time on a phone CPU. Outputs land in runs/plate_n/.
"""
import os
import sys

from ultralytics import YOLO

data = os.path.expanduser(os.environ.get("PLATES_YAML", "~/ml-data/plates/plates.yaml"))
epochs = int(os.environ.get("EPOCHS", "40"))
imgsz = int(os.environ.get("IMGSZ", "416"))
base = os.environ.get("BASE", "yolo11n.pt")
name = os.environ.get("NAME", "plate_n")
lr0 = float(os.environ.get("LR0", "0.01"))

model = YOLO(base)
model.train(
    data=data,
    epochs=epochs,
    imgsz=imgsz,
    batch=32,
    workers=4,
    project=os.path.join(os.path.dirname(os.path.abspath(__file__)), "runs"),
    name=name,
    lr0=lr0,
    exist_ok=True,
    patience=12,
    seed=0,
    # Phone photos are rotated, blurred and badly lit: lean into that.
    degrees=8,
    perspective=0.0005,
    hsv_v=0.5,
    mosaic=1.0,
    close_mosaic=8,
)
if os.environ.get("TEST_SPLIT", "1") == "1":
    metrics = model.val(data=data, split="test", imgsz=imgsz)
    print("TEST mAP50", metrics.box.map50, "mAP50-95", metrics.box.map, "P", metrics.box.mp, "R", metrics.box.mr)
