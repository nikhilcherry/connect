"""Synthetic Indian number plates: text, rendering and camera-style damage.

Used by the plate-reader training (train_ocr.py) and to paste Indian plates onto
vehicle photos for detector fine-tuning (make_indian_scenes.py). Plates are
drawn from system fonts (the real HSRP font is not available), so the reader
also trains on real crops and is scored only on REAL held-out plates.
"""
import random

import cv2
import numpy as np
from PIL import Image, ImageDraw, ImageFont

CHARSET = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ"
STATES = {  # rough registration weight; the point is variety, not statistics
    "KA": 10, "MH": 12, "DL": 9, "TN": 8, "UP": 9, "GJ": 6, "RJ": 5, "AP": 5, "TS": 5, "KL": 5, "WB": 4,
    "HR": 4, "PB": 3, "MP": 4, "BR": 3, "OD": 2, "AS": 2, "JH": 2, "CG": 2, "UK": 1, "HP": 1, "GA": 1,
    "JK": 1, "CH": 1, "PY": 1, "ML": 1, "MN": 1, "TR": 1, "AR": 1, "NL": 1, "SK": 1, "MZ": 1, "DD": 1, "DN": 1, "AN": 1, "LA": 1, "LD": 1,
}
SERIES = "ABCDEFGHJKLMNPRSTUVWXYZ"  # I and O are not issued in series
FONTS = [
    "/usr/share/fonts/truetype/liberation/LiberationSans-Bold.ttf",
    "/usr/share/fonts/truetype/liberation/LiberationSansNarrow-Bold.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
    "/usr/share/fonts/truetype/noto/NotoSans-Bold.ttf",
    "/usr/share/fonts/truetype/open-sans/OpenSans-CondBold.ttf",
    "/usr/share/fonts/truetype/open-sans/OpenSans-Bold.ttf",
    "/usr/share/fonts/opentype/fira/FiraSansCompressed-Bold.otf",
    "/usr/share/fonts/opentype/fira/FiraSans-Bold.otf",
]
_font_cache = {}


def font(path, size):
    key = (path, size)
    if key not in _font_cache:
        _font_cache[key] = ImageFont.truetype(path, size)
    return _font_cache[key]


def random_text(rng: random.Random) -> str:
    """A plate number in one of the formats on Indian roads."""
    r = rng.random()
    state = rng.choices(list(STATES), weights=list(STATES.values()))[0]
    digits4 = f"{rng.randint(1, 9999):04d}" if rng.random() > 0.05 else f"{rng.randint(1, 9):04d}"
    if r < 0.03:  # Bharat series: 22 BH 1234 AA
        return f"{rng.randint(21, 27)}BH{digits4}{rng.choice(SERIES)}{rng.choice(SERIES)}"
    n_series = rng.choices([1, 2, 3], weights=[2, 10, 1])[0]
    series = "".join(rng.choice(SERIES) for _ in range(n_series))
    if r < 0.12:  # old style district with a letter: DL 3C AB 1234
        return f"{state}{rng.randint(1, 9)}{rng.choice(SERIES)}{series}{digits4}"
    if r < 0.18:  # single-digit district
        return f"{state}{rng.randint(1, 9)}{series}{digits4}"
    return f"{state}{rng.randint(1, 99):02d}{series}{digits4}"


def _groups(text: str, rng: random.Random):
    """Split into the printed groups: state+district, series, number."""
    if "BH" in text[2:4]:
        return [text[:2], text[2:4], text[4:8], text[8:]]
    num = text[-4:]
    rest = text[:-4]
    i = 2
    while i < len(rest) and rest[i].isdigit():
        i += 1
    if i < len(rest) and rest[i].isalpha() and i == 3 and rest[2].isdigit() and len(rest) > 4:
        pass
    head = rest[: i if i > 2 else 4]
    # State + district is the first 4 chars (KA01) except the one-digit district styles.
    if len(rest) >= 4 and rest[2:4].isdigit():
        head = rest[:4]
    series = rest[len(head):]
    return [g for g in (head, series, num) if g]


def render_plate(text: str, rng: random.Random, two_row: bool | None = None) -> Image.Image:
    """A clean synthetic plate on a transparent-ish white/yellow/green/black plate."""
    two = rng.random() < 0.3 if two_row is None else two_row
    style = rng.choices(["white", "yellow", "green", "black"], weights=[62, 25, 6, 7])[0]
    bg, fg = {
        "white": ((245, 245, 240), (15, 15, 15)),
        "yellow": ((250, 200, 20), (15, 15, 15)),
        "green": ((20, 130, 70), (245, 245, 245)),
        "black": ((20, 20, 20), (240, 200, 30)),
    }[style]
    bg = tuple(max(0, min(255, c + rng.randint(-12, 12))) for c in bg)
    gs = _groups(text, rng)
    fpath = rng.choice(FONTS)
    if two:
        w, h = 220 + rng.randint(-15, 20), 160 + rng.randint(-15, 15)
        lines = [" ".join(gs[:2]) if len(gs) > 2 else gs[0], " ".join(gs[2:]) if len(gs) > 2 else gs[-1]]
    else:
        w, h = 380 + rng.randint(-30, 30), 84 + rng.randint(-8, 10)
        lines = [" ".join(gs) if rng.random() > 0.15 else "".join(gs)]
    img = Image.new("RGB", (w, h), bg)
    d = ImageDraw.Draw(img)
    border = rng.randint(2, 5)
    d.rounded_rectangle([2, 2, w - 3, h - 3], radius=rng.randint(6, 16), outline=fg, width=border)
    left = border + 8
    if rng.random() < 0.35 and style != "black":  # blue IND strip
        sw = int(h * (0.22 if not two else 0.2))
        d.rectangle([border + 3, border + 3, border + 3 + sw, h - border - 3], fill=(24, 60, 150))
        d.text((border + 3 + sw // 2, h // 2), "IND", fill=(255, 255, 255), font=font(FONTS[0], max(8, sw // 3)), anchor="mm")
        left = border + 3 + sw + 6
    avail_w = w - left - border - 8
    rows = len(lines)
    row_h = (h - 2 * border - 10) / rows
    for k, line in enumerate(lines):
        size = int(row_h * rng.uniform(0.72, 0.92))
        f = font(fpath, size)
        while f.getlength(line) > avail_w and size > 10:
            size -= 2
            f = font(fpath, size)
        cx = left + avail_w / 2 + rng.randint(-4, 4)
        cy = border + 5 + row_h * (k + 0.5) + rng.randint(-3, 3)
        d.text((cx, cy), line, fill=fg, font=f, anchor="mm")
    return img


def damage(img: Image.Image, rng: random.Random) -> np.ndarray:
    """Make a clean plate look like a phone photo of a real, dirty, tilted plate."""
    a = np.asarray(img, dtype=np.uint8)
    h, w = a.shape[:2]
    # background margin (car body / bumper colours)
    mh, mw = int(h * rng.uniform(0.05, 0.35)), int(w * rng.uniform(0.02, 0.15))
    body = np.array([rng.randint(0, 255) for _ in range(3)], dtype=np.uint8)
    canvas = np.empty((h + 2 * mh, w + 2 * mw, 3), np.uint8)
    canvas[:] = body
    canvas[mh : mh + h, mw : mw + w] = a
    H, W = canvas.shape[:2]
    # perspective + rotation
    j = rng.uniform(0.0, 0.10)
    src = np.float32([[0, 0], [W, 0], [W, H], [0, H]])
    dst = src + np.float32([[rng.uniform(-j, j) * W, rng.uniform(-j, j) * H] for _ in range(4)])
    ang = rng.uniform(-6, 6)
    M = cv2.getPerspectiveTransform(src, dst)
    R = cv2.getRotationMatrix2D((W / 2, H / 2), ang, 1.0)
    canvas = cv2.warpPerspective(canvas, M, (W, H), borderMode=cv2.BORDER_REPLICATE)
    canvas = cv2.warpAffine(canvas, R, (W, H), borderMode=cv2.BORDER_REPLICATE)
    # lighting: gradient glare / shadow, brightness, contrast
    gx = np.linspace(rng.uniform(0.6, 1.1), rng.uniform(0.6, 1.1), W)[None, :, None]
    gy = np.linspace(rng.uniform(0.8, 1.1), rng.uniform(0.8, 1.1), H)[:, None, None]
    canvas = np.clip(canvas.astype(np.float32) * gx * gy * rng.uniform(0.6, 1.3) + rng.uniform(-25, 25), 0, 255)
    if rng.random() < 0.25:  # specular glare blob
        cx, cy = rng.randint(0, W), rng.randint(0, H)
        yy, xx = np.ogrid[:H, :W]
        blob = np.exp(-(((xx - cx) / (W * 0.2)) ** 2 + ((yy - cy) / (H * 0.3)) ** 2)) * rng.uniform(40, 140)
        canvas = np.clip(canvas + blob[..., None], 0, 255)
    if rng.random() < 0.3:  # dirt / speckle
        n = rng.randint(20, 200)
        for _ in range(n):
            cv2.circle(canvas, (rng.randint(0, W), rng.randint(0, H)), rng.randint(1, 3), [rng.randint(30, 120)] * 3, -1)
    canvas = canvas.astype(np.uint8)
    # resolution loss: phone crops are small
    target_w = int(np.exp(rng.uniform(np.log(56), np.log(420))))
    scale = target_w / W
    small = cv2.resize(canvas, (max(8, int(W * scale)), max(8, int(H * scale))), interpolation=cv2.INTER_AREA)
    if rng.random() < 0.35:
        k = rng.choice([3, 5])
        small = cv2.GaussianBlur(small, (k, k), rng.uniform(0.3, 1.2))
    if rng.random() < 0.3:  # motion blur
        k = rng.randint(3, 9)
        kern = np.zeros((k, k), np.float32)
        kern[k // 2, :] = 1.0 / k
        M2 = cv2.getRotationMatrix2D((k / 2 - 0.5, k / 2 - 0.5), rng.uniform(0, 180), 1)
        kern = cv2.warpAffine(kern, M2, (k, k))
        kern /= kern.sum() + 1e-6
        small = cv2.filter2D(small, -1, kern)
    noise = np.random.default_rng(rng.randint(0, 1 << 30)).normal(0, rng.uniform(0, 9), small.shape)
    small = np.clip(small.astype(np.float32) + noise, 0, 255).astype(np.uint8)
    if rng.random() < 0.6:  # JPEG artefacts
        ok, enc = cv2.imencode(".jpg", small, [cv2.IMWRITE_JPEG_QUALITY, rng.randint(25, 85)])
        small = cv2.imdecode(enc, cv2.IMREAD_COLOR)
    return small


def sample(rng: random.Random):
    text = random_text(rng)
    return text, damage(render_plate(text, rng), rng)


if __name__ == "__main__":
    import sys

    rng = random.Random(int(sys.argv[1]) if len(sys.argv) > 1 else 0)
    tiles = []
    for _ in range(24):
        t, im = sample(rng)
        tile = cv2.resize(im, (260, 90))
        cv2.putText(tile, t, (4, 12), cv2.FONT_HERSHEY_SIMPLEX, 0.4, (0, 0, 255), 1)
        tiles.append(tile)
    rows = [np.hstack(tiles[i : i + 4]) for i in range(0, 24, 4)]
    cv2.imwrite(sys.argv[2] if len(sys.argv) > 2 else "synth_preview.png", np.vstack(rows))
