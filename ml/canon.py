"""Canonical input for the plate reader (cv2 + numpy only, no torch), shared by data
generation, training and the Dart port in app/lib/services/plate_recognizer.dart.

Gray, 32 px high, 160 px wide. A single-row plate is resized to 160x32. A two-row
plate (width/height < 2.5) is split into its top and bottom halves, each resized
to 80x32, and laid side by side.
"""
import cv2
import numpy as np

from synth_plates import CHARSET

H, W = 32, 160
TWO_ROW_ASPECT = 2.5
BLANK = len(CHARSET)  # CTC blank index
NUM_CLASSES = len(CHARSET) + 1


def _resize(a: np.ndarray, w: int, h: int) -> np.ndarray:
    interp = cv2.INTER_AREA if (a.shape[1] > w or a.shape[0] > h) else cv2.INTER_LINEAR
    return cv2.resize(a, (w, h), interpolation=interp)


def canonicalize(img: np.ndarray) -> np.ndarray:
    """RGB/BGR/gray uint8 crop -> float32 [H, W] in -1..1."""
    g = img if img.ndim == 2 else cv2.cvtColor(img, cv2.COLOR_RGB2GRAY)
    h, w = g.shape
    if w / h < TWO_ROW_ASPECT:
        top, bot = g[: h // 2], g[h // 2 :]
        g = np.hstack([_resize(top, W // 2, H), _resize(bot, W // 2, H)])
    else:
        g = _resize(g, W, H)
    return (g.astype(np.float32) / 255.0 - 0.5) / 0.5


