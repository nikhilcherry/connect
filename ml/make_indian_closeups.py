"""Close-up training data for the plate detector.

The first Indian fine-tune (make_indian_scenes.py) did not help on real Indian phone
photos. The reason, from looking at the misses: those photos are hand-held close-ups of
worn, rusty, dark two-wheeler plates that fill 25-75% of the frame, nothing like the
small plates in CCTV views. This generates that situation:

  - "vehicle close-up": a zoomed window of a real vehicle photo around the plate, with a
    sharp synthetic or real Indian plate pasted at the (zoomed) plate box;
  - "texture close-up": a plate on a random dirt / concrete / metal texture, with rust,
    scratches, strong rotation and perspective;
  - "negative": zoomed windows with no plate at all (stickers, lamps, bumpers), so the
    detector stops firing on text-like rectangles.

Boxes are exact (the plate quad is warped, its bounding box is the label).

    python make_indian_closeups.py <plates_root> <real_root> <out_root> [n_per_kind]
"""
import csv
import os
import random
import sys

import cv2
import numpy as np

import synth_plates as sp

plates_root, real_root, out_root = (os.path.expanduser(a) for a in sys.argv[1:4])
N = int(sys.argv[4]) if len(sys.argv) > 4 else 2500
SEED = int(os.environ.get("SEED", "11"))
SPLIT = os.environ.get("SPLIT", "train")
rng = random.Random(SEED)
np.random.seed(SEED)
S = 640  # output square

real = []
d = os.path.join(real_root, "real_train")  # TRAIN split only
for f, t in list(csv.reader(open(os.path.join(d, "labels.csv"))))[1:]:
    real.append(cv2.imread(os.path.join(d, f), cv2.IMREAD_COLOR))


def plate_image(two_row=None):
    """A BGR plate, large and sharp."""
    if rng.random() < 0.35:
        im = rng.choice(real)
        if two_row is None or (im.shape[1] / im.shape[0] < 2.5) == two_row:
            return im
    pil = sp.render_plate(sp.random_text(rng), rng, two_row=two_row)
    return cv2.cvtColor(np.asarray(pil), cv2.COLOR_RGB2BGR)


def weather_plate(p):
    """Rust, dirt, scratches and fading, as on real two-wheeler plates."""
    p = p.astype(np.float32)
    h, w = p.shape[:2]
    if rng.random() < 0.5:  # fade / tint
        tint = np.array([rng.uniform(0.75, 1.05), rng.uniform(0.8, 1.0), rng.uniform(0.85, 1.1)])
        p *= tint
    if rng.random() < 0.4:  # rust blotches
        for _ in range(rng.randint(2, 8)):
            c = (rng.randint(0, w), rng.randint(0, h))
            cv2.ellipse(p, c, (rng.randint(w // 40 + 2, w // 8 + 3), rng.randint(h // 30 + 2, h // 5 + 3)), rng.randint(0, 180), 0, 360,
                        (rng.randint(20, 60), rng.randint(60, 110), rng.randint(110, 170)), -1)
        p = cv2.addWeighted(p, 0.6, cv2.GaussianBlur(p, (0, 0), 3), 0.4, 0)
    for _ in range(rng.randint(0, 6)):  # scratches
        cv2.line(p, (rng.randint(0, w), rng.randint(0, h)), (rng.randint(0, w), rng.randint(0, h)), [rng.randint(80, 200)] * 3, 1)
    return np.clip(p, 0, 255).astype(np.uint8)


def warp_onto(bg, plate, cx, cy, width, rot, persp):
    """Warp `plate` onto `bg` centred at (cx,cy) with the given width. Returns bbox."""
    ph, pw = plate.shape[:2]
    scale = width / pw
    w, h = width, ph * scale
    quad = np.float32([[-w / 2, -h / 2], [w / 2, -h / 2], [w / 2, h / 2], [-w / 2, h / 2]])
    a = np.deg2rad(rot)
    R = np.array([[np.cos(a), -np.sin(a)], [np.sin(a), np.cos(a)]])
    quad = quad @ R.T
    quad += np.float32([[rng.uniform(-persp, persp) * w, rng.uniform(-persp, persp) * h] for _ in range(4)])
    quad += np.float32([cx, cy])
    src = np.float32([[0, 0], [pw, 0], [pw, ph], [0, ph]])
    M = cv2.getPerspectiveTransform(src, quad.astype(np.float32))
    H, W = bg.shape[:2]
    warped = cv2.warpPerspective(plate, M, (W, H), flags=cv2.INTER_LINEAR, borderMode=cv2.BORDER_CONSTANT, borderValue=0)
    mask = cv2.warpPerspective(np.full((ph, pw), 255, np.uint8), M, (W, H))
    mask = cv2.GaussianBlur(mask, (0, 0), 1.2).astype(np.float32)[..., None] / 255.0
    out = (warped.astype(np.float32) * mask + bg.astype(np.float32) * (1 - mask)).astype(np.uint8)
    xs, ys = quad[:, 0], quad[:, 1]
    box = (max(0, xs.min()), max(0, ys.min()), min(W, xs.max()), min(H, ys.max()))
    return out, box


def phone_look(img):
    """Hand-held phone shot: uneven light, often dark, blur, noise, JPEG."""
    a = img.astype(np.float32)
    gx = np.linspace(rng.uniform(0.5, 1.2), rng.uniform(0.5, 1.2), a.shape[1])[None, :, None]
    gy = np.linspace(rng.uniform(0.6, 1.2), rng.uniform(0.6, 1.2), a.shape[0])[:, None, None]
    a = a * gx * gy * rng.uniform(0.45, 1.3) + rng.uniform(-15, 15)
    a = np.clip(a, 0, 255).astype(np.uint8)
    if rng.random() < 0.5:
        k = rng.choice([3, 5, 7])
        a = cv2.GaussianBlur(a, (k, k), rng.uniform(0.5, 2.0))
    a = np.clip(a.astype(np.float32) + np.random.normal(0, rng.uniform(1, 9), a.shape), 0, 255).astype(np.uint8)
    ok, enc = cv2.imencode(".jpg", a, [cv2.IMWRITE_JPEG_QUALITY, rng.randint(35, 90)])
    return cv2.imdecode(enc, cv2.IMREAD_COLOR)


def texture_bg():
    base = np.array([rng.randint(20, 220) for _ in range(3)], np.float32)
    noise = np.random.normal(0, rng.uniform(8, 35), (S // 8, S // 8, 3)).astype(np.float32)
    bg = cv2.resize(noise, (S, S), interpolation=cv2.INTER_CUBIC) + base
    bg += cv2.resize(np.random.normal(0, 12, (S // 2, S // 2, 3)).astype(np.float32), (S, S))
    if rng.random() < 0.5:  # a lamp / reflector / bumper-ish blob nearby, so plates are not the only rectangle
        cv2.rectangle(bg, (rng.randint(0, S), rng.randint(0, S)), (rng.randint(0, S), rng.randint(0, S)), [rng.randint(0, 255) for _ in range(3)], -1)
    return np.clip(bg, 0, 255).astype(np.uint8)


vroot = os.path.join(plates_root, "yolo", "train")
vfiles = sorted(os.listdir(os.path.join(vroot, "images")))


def vehicle_window():
    """A zoomed window of a vehicle photo around one of its plates (or, if `neg`, away from it)."""
    while True:
        name = rng.choice(vfiles)
        stem = os.path.splitext(name)[0]
        lines = [l.split() for l in open(os.path.join(vroot, "labels", stem + ".txt")).read().split("\n") if l.strip()]
        if not lines:
            continue
        img = cv2.imread(os.path.join(vroot, "images", name))
        H, W = img.shape[:2]
        _, cx, cy, bw, bh = map(float, rng.choice(lines))
        return img, cx * W, cy * H, bw * W, bh * H


def make(kind, idx, outdir):
    two = rng.random() < 0.45
    if kind == "texture":
        bg = texture_bg()
        plate = weather_plate(plate_image(two))
        w = rng.uniform(0.25, 0.8) * S
        cx = rng.uniform(w / 2 * 0.9, S - w / 2 * 0.9)
        cy = rng.uniform(S * 0.2, S * 0.8)
        out, box = warp_onto(bg, plate, cx, cy, w, rng.uniform(-18, 18), 0.09)
        boxes = [box]
    else:
        img, px, py, pw, ph = vehicle_window()
        H, W = img.shape[:2]
        m = rng.uniform(2.0, 7.0)  # window = m x the plate width
        side = max(pw * m, 24)
        if kind == "negative":
            # a window that does NOT contain the plate: shift away
            ang = rng.uniform(0, 2 * np.pi)
            px2, py2 = px + np.cos(ang) * side * 1.2, py + np.sin(ang) * side * 1.2
            px2 = float(np.clip(px2, side / 2, W - side / 2)) if W > side else W / 2
            py2 = float(np.clip(py2, side / 2, H - side / 2)) if H > side else H / 2
            x0, y0 = int(px2 - side / 2), int(py2 - side / 2)
        else:
            jx, jy = rng.uniform(-0.25, 0.25) * side, rng.uniform(-0.25, 0.25) * side
            x0, y0 = int(px + jx - side / 2), int(py + jy - side / 2)
        x0 = max(0, min(W - 8, x0))
        y0 = max(0, min(H - 8, y0))
        s = int(max(8, min(side, W - x0, H - y0)))
        win = cv2.resize(img[y0 : y0 + s, x0 : x0 + s], (S, S), interpolation=cv2.INTER_CUBIC)
        k = S / s
        if kind == "negative":
            # blank the original plate if it still intrudes into the window
            if x0 < px + pw / 2 and px - pw / 2 < x0 + s and y0 < py + ph / 2 and py - ph / 2 < y0 + s:
                return None
            out, boxes = win, []
        else:
            ocx, ocy = (px - x0) * k, (py - y0) * k
            plate = weather_plate(plate_image(two))
            out, box = warp_onto(win, plate, ocx, ocy, pw * k * rng.uniform(0.95, 1.1), rng.uniform(-8, 8), 0.05)
            boxes = [box]
    out = phone_look(out)
    stem = f"{kind}_{idx:05d}"
    cv2.imwrite(os.path.join(outdir, "images", stem + ".jpg"), out, [cv2.IMWRITE_JPEG_QUALITY, 90])
    lines = []
    for (x0, y0, x1, y1) in boxes:
        if x1 - x0 < 6 or y1 - y0 < 4:
            return None
        lines.append(f"0 {(x0 + x1) / 2 / S:.6f} {(y0 + y1) / 2 / S:.6f} {(x1 - x0) / S:.6f} {(y1 - y0) / S:.6f}")
    open(os.path.join(outdir, "labels", stem + ".txt"), "w").write("\n".join(lines) + ("\n" if lines else ""))
    return stem


outdir = os.path.join(out_root, SPLIT)
os.makedirs(os.path.join(outdir, "images"), exist_ok=True)
os.makedirs(os.path.join(outdir, "labels"), exist_ok=True)
counts = {}
for kind, n in (("vehicle", N), ("texture", N // 2), ("negative", N // 4)):
    made, i = 0, 0
    while made < n:
        i += 1
        if make(kind, i, outdir):
            made += 1
    counts[kind] = made
print(counts)
