"""Prepare the AutoDamageIQ vehicle-damage dataset (HF tugberkkalay/autodamageiq-vehicle-damage-dataset)
for YOLO training: drop unreadable images (with their labels) and write a yaml with
English class names.

    python3 prepare_damage.py ~/ml-data/damage/autodamageiq

Licence: the dataset page says CC BY 4.0, but it is assembled from CarDD (research /
non-commercial licence) and VehiDE plus GPT-4o-assisted labels, so treat models trained
on it as research-grade.
"""
import collections
import os
import sys

from PIL import Image

root = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser("~/ml-data/damage/autodamageiq"))
NAMES = ["crack", "dent", "glass_shatter", "lamp_broken", "scratch", "tire_flat"]
dropped = 0
counts = {s: collections.Counter() for s in ("train", "val")}
for split in ("train", "val"):
    for f in sorted(os.listdir(os.path.join(root, "images", split))):
        p = os.path.join(root, "images", split, f)
        lbl = os.path.join(root, "labels", split, os.path.splitext(f)[0] + ".txt")
        try:
            if os.path.getsize(p) < 2000:
                raise ValueError("tiny")
            with Image.open(p) as im:
                im.verify()
        except Exception:
            os.remove(p)
            if os.path.exists(lbl):
                os.remove(lbl)
            dropped += 1
            continue
        if os.path.exists(lbl):
            for line in open(lbl).read().split("\n"):
                if line.strip():
                    counts[split][NAMES[int(line.split()[0])]] += 1
with open(os.path.join(root, "damage.yaml"), "w") as fh:
    fh.write(f"path: {root}\ntrain: images/train\nval: images/val\nnames:\n" + "".join(f"  {i}: {n}\n" for i, n in enumerate(NAMES)))
print("dropped", dropped)
for s in counts:
    print(s, dict(counts[s]))
