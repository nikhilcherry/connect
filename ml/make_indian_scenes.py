"""Fine-tuning data for the plate detector: Indian plates on real vehicle photos.

The original detector saw mostly non-Indian plates and scores mAP50 0.65-0.69 on real
Indian phone photos. This builds a training set by taking the existing vehicle photos
(their plate boxes are exact) and replacing each plate with an Indian-format one: a
real Indian plate crop (train split only) or a synthetic one, matched to the box's
aspect ratio, brightness and sharpness, with a soft edge and a small perspective
jitter. The labels stay the same, so they are exact.

    python make_indian_scenes.py <plates_root> <real_root> <out_root>
"""
import csv
import os
import random
import sys

import cv2
import numpy as np

import synth_plates as sp

plates_root, real_root, out_root = (os.path.expanduser(a) for a in sys.argv[1:4])
rng = random.Random(7)
np.random.seed(7)

# Real Indian crops (TRAIN split only: never the held-out test plates)
real = []
d = os.path.join(real_root, "real_train")
for f, t in list(csv.reader(open(os.path.join(d, "labels.csv"))))[1:]:
    im = cv2.imread(os.path.join(d, f), cv2.IMREAD_COLOR)
    real.append((im.shape[1] / im.shape[0], im))


def pick_plate(box_aspect):
    """A BGR plate whose shape suits the box."""
    if rng.random() < 0.5:
        near = [im for a, im in real if abs(a - box_aspect) / box_aspect < 0.35]
        if near:
            return rng.choice(near)
    two = box_aspect < 2.5
    text = sp.random_text(rng)
    pil = sp.render_plate(text, rng, two_row=two)
    return cv2.cvtColor(np.asarray(pil), cv2.COLOR_RGB2BGR)


def sharpness(g):
    return cv2.Laplacian(g, cv2.CV_64F).var()


def paste(img, box):
    x0, y0, x1, y1 = box
    w, h = x1 - x0, y1 - y0
    if w < 12 or h < 6:
        return
    plate = pick_plate(w / h)
    plate = cv2.resize(plate, (w, h), interpolation=cv2.INTER_AREA if plate.shape[1] > w else cv2.INTER_LINEAR)
    region = img[y0:y1, x0:x1]
    # match brightness and softness of the plate it replaces
    pm, rm = plate.mean(), max(30.0, region.mean())
    plate = np.clip(plate.astype(np.float32) * np.clip(rm / max(pm, 1) * rng.uniform(0.9, 1.4), 0.3, 1.6), 0, 255)
    rs = sharpness(cv2.cvtColor(region, cv2.COLOR_BGR2GRAY))
    if sharpness(cv2.cvtColor(plate.astype(np.uint8), cv2.COLOR_BGR2GRAY)) > rs * 2 and rs < 400:
        k = rng.choice([3, 5])
        plate = cv2.GaussianBlur(plate, (k, k), rng.uniform(0.6, 1.6))
    plate = np.clip(plate + np.random.normal(0, rng.uniform(0, 5), plate.shape), 0, 255)
    # tiny perspective jitter, inside the box
    j = 0.04
    src = np.float32([[0, 0], [w, 0], [w, h], [0, h]])
    dst = src + np.float32([[rng.uniform(-j, j) * w, rng.uniform(-j, j) * h] for _ in range(4)])
    M = cv2.getPerspectiveTransform(src, dst)
    plate = cv2.warpPerspective(plate, M, (w, h), borderMode=cv2.BORDER_REPLICATE)
    # soft edges
    m = np.zeros((h, w), np.float32)
    e = max(1, int(min(w, h) * 0.06))
    m[e:-e, e:-e] = 1.0
    m = cv2.GaussianBlur(m, (0, 0), max(0.8, e / 2))[..., None]
    img[y0:y1, x0:x1] = (plate * m + region.astype(np.float32) * (1 - m)).astype(np.uint8)


def process(split_in, split_out, composite_p, keep_original):
    ids = os.path.join(plates_root, "yolo", split_in, "images")
    lbl = os.path.join(plates_root, "yolo", split_in, "labels")
    oi = os.path.join(out_root, split_out, "images")
    ol = os.path.join(out_root, split_out, "labels")
    os.makedirs(oi, exist_ok=True)
    os.makedirs(ol, exist_ok=True)
    n = c = 0
    for name in sorted(os.listdir(ids)):
        stem = os.path.splitext(name)[0]
        lines = [l.split() for l in open(os.path.join(lbl, stem + ".txt")).read().strip().splitlines() if l.strip()]
        if not lines:
            continue
        img = cv2.imread(os.path.join(ids, name), cv2.IMREAD_COLOR)
        if img is None:
            continue
        H, W = img.shape[:2]
        text = "\n".join(" ".join(l) for l in lines) + "\n"
        if keep_original and rng.random() < keep_original:
            cv2.imwrite(os.path.join(oi, "o_" + stem + ".jpg"), img, [cv2.IMWRITE_JPEG_QUALITY, 92])
            open(os.path.join(ol, "o_" + stem + ".txt"), "w").write(text)
        if rng.random() < composite_p:
            out = img.copy()
            for _, cx, cy, bw, bh in lines:
                cx, cy, bw, bh = float(cx) * W, float(cy) * H, float(bw) * W, float(bh) * H
                box = (max(0, int(cx - bw / 2)), max(0, int(cy - bh / 2)), min(W, int(cx + bw / 2)), min(H, int(cy + bh / 2)))
                paste(out, box)
            cv2.imwrite(os.path.join(oi, "i_" + stem + ".jpg"), out, [cv2.IMWRITE_JPEG_QUALITY, rng.randint(70, 95)])
            open(os.path.join(ol, "i_" + stem + ".txt"), "w").write(text)
            c += 1
        n += 1
    print(f"{split_out}: {n} source images, {c} composited with Indian plates")


# train: Indian-composited versions of every vehicle photo + half the originals (to avoid forgetting)
process("train", "train", composite_p=1.0, keep_original=0.5)
# val: composited, to track progress; the REAL test is the Datacluster phone photos (never trained on)
process("val", "val", composite_p=1.0, keep_original=0.0)
with open(os.path.join(out_root, "indian_mix.yaml"), "w") as f:
    f.write(f"path: {out_root}\ntrain: train/images\nval: val/images\nnames:\n  0: license_plate\n")
