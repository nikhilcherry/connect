"""Our plate reader: a small CRNN + CTC that reads a cropped Indian number plate.

Canonical input (shared with the Dart code in app/lib/services/plate_recognizer.dart):
  gray, 32 px high, 160 px wide. A single-row plate is resized to 160x32. A
  two-row plate (width/height < 2.5) is split into its top and bottom halves,
  each resized to 80x32, and laid side by side.
"""
import numpy as np
import torch
import torch.nn as nn

from synth_plates import CHARSET

from canon import BLANK, H, NUM_CLASSES, TWO_ROW_ASPECT, W, canonicalize  # noqa: F401


class PlateCRNN(nn.Module):
    def __init__(self):
        super().__init__()

        def block(i, o):
            return nn.Sequential(nn.Conv2d(i, o, 3, padding=1, bias=False), nn.BatchNorm2d(o), nn.ReLU(inplace=True))

        self.cnn = nn.Sequential(
            block(1, 32), nn.MaxPool2d(2, 2),          # 16 x 80
            block(32, 64), nn.MaxPool2d(2, 2),         # 8 x 40
            block(64, 128), block(128, 128), nn.MaxPool2d((2, 1)),  # 4 x 40
            block(128, 192), nn.MaxPool2d((2, 1)),     # 2 x 40
        )
        self.rnn = nn.GRU(192 * 2, 128, bidirectional=True, batch_first=True)
        self.head = nn.Linear(256, NUM_CLASSES)

    def forward(self, x):  # x: [B, 1, 32, 160]
        f = self.cnn(x)                                # [B, 192, 2, 40]
        b, c, h, w = f.shape
        f = f.permute(0, 3, 1, 2).reshape(b, w, c * h)  # [B, 40, 384]
        f, _ = self.rnn(f)
        return self.head(f)                            # [B, 40, 37]  (logits, time-major later for CTC)


def decode(logits: torch.Tensor):
    """Greedy CTC decode: list of (text, confidence)."""
    probs = logits.softmax(-1)
    best = probs.argmax(-1)
    out = []
    for p, row in zip(probs, best):
        chars, confs, prev = [], [], BLANK
        for t, k in enumerate(row.tolist()):
            if k != prev and k != BLANK:
                chars.append(CHARSET[k])
                confs.append(p[t, k].item())
            prev = k
        out.append(("".join(chars), float(np.mean(confs)) if confs else 0.0))
    return out
