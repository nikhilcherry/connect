"""Train the plate reader on synthetic Indian plates + real train crops, and score it
on the held-out REAL crops (indian_plates.py split), never seen in training.

    ~/Projects/Drone_Ml/venv/bin/python train_ocr.py [steps]
"""
import csv
import os
import random
import sys
import time

import cv2
import numpy as np
import torch
import torch.nn as nn

import ocr_model as om
import synth_plates as sp

ROOT = os.path.expanduser("~/ml-data/indian-plates")
SET = os.path.join(ROOT, "ocr_set")  # from gen_ocr_data.py
STEPS = int(sys.argv[1]) if len(sys.argv) > 1 else 24000
BATCH = 256
REAL_FRACTION = 0.25
MAXLEN = 12


def load_real(split):
    d = os.path.join(ROOT, split)
    rows = list(csv.reader(open(os.path.join(d, "labels.csv"))))[1:]
    out = []
    for f, t in rows:
        im = cv2.imread(os.path.join(d, f), cv2.IMREAD_COLOR)
        out.append((t, cv2.cvtColor(im, cv2.COLOR_BGR2RGB)))
    return out


def real_augment(img, rng):
    """Light jitter for the (few) real training crops."""
    a = img.astype(np.float32) * rng.uniform(0.7, 1.3) + rng.uniform(-20, 20)
    h, w = img.shape[:2]
    if rng.random() < 0.5:
        s = rng.uniform(0.5, 1.0)
        a = cv2.resize(cv2.resize(a.clip(0, 255).astype(np.uint8), (max(8, int(w * s)), max(8, int(h * s)))), (w, h)).astype(np.float32)
    a = a + np.random.normal(0, rng.uniform(0, 6), a.shape)
    return a.clip(0, 255).astype(np.uint8)


def evaluate(model, items, device):
    model.eval()
    xs = torch.stack([torch.from_numpy(om.canonicalize(im))[None] for _, im in items]).to(device)
    with torch.no_grad():
        preds = om.decode(model(xs))
    exact = sum(p == t for (p, _), (t, _) in zip(preds, items))
    cer_num = cer_den = 0
    for (p, _), (t, _) in zip(preds, items):
        cer_num += editdist(p, t)
        cer_den += len(t)
    model.train()
    return exact, len(items), cer_num / max(1, cer_den), preds


def editdist(a, b):
    d = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        prev, d[0] = d[0], i
        for j, cb in enumerate(b, 1):
            prev, d[j] = d[j], min(d[j] + 1, d[j - 1] + 1, prev + (ca != cb))
    return d[len(b)]


def main():
    device = "cuda"
    real_test = load_real("real_test")
    rng = random.Random(123)
    synth_val = [sp.sample(rng) for _ in range(500)]
    x = np.load(os.path.join(SET, "x.npy"), mmap_mode="r")
    y = np.load(os.path.join(SET, "y.npy"))
    n = np.load(os.path.join(SET, "n.npy"))
    N = len(x)
    print(f"train samples {N}, real test crops {len(real_test)}, steps {STEPS}", flush=True)

    model = om.PlateCRNN().to(device)
    print("parameters", sum(p.numel() for p in model.parameters()), flush=True)
    opt = torch.optim.AdamW(model.parameters(), lr=2e-3, weight_decay=1e-4)
    sched = torch.optim.lr_scheduler.OneCycleLR(opt, max_lr=3e-3, total_steps=STEPS, pct_start=0.1)
    ctc = nn.CTCLoss(blank=om.BLANK, zero_infinity=True)
    scaler = torch.amp.GradScaler()
    g = np.random.default_rng(1)
    t0 = time.time()
    for step in range(1, STEPS + 1):
        idx = np.sort(g.choice(N, BATCH, replace=False))
        xb = torch.from_numpy(np.stack([x[i] for i in idx])).float().div(255).sub(0.5).div(0.5)[:, None].to(device)
        yb = torch.from_numpy(y[idx].astype(np.int64))
        nb = torch.from_numpy(n[idx].astype(np.int64))
        with torch.autocast("cuda", dtype=torch.float16):
            logits = model(xb)
        lp = logits.float().log_softmax(-1).permute(1, 0, 2)
        tgt = torch.cat([row[row >= 0] for row in yb]).to(device)
        loss = ctc(lp, tgt, torch.full((xb.shape[0],), lp.shape[0], dtype=torch.long), nb.to(device))
        opt.zero_grad(set_to_none=True)
        scaler.scale(loss).backward()
        scaler.unscale_(opt)
        nn.utils.clip_grad_norm_(model.parameters(), 5.0)
        scaler.step(opt)
        scaler.update()
        sched.step()
        if step % 1000 == 0 or step == STEPS:
            se, sn, scer, _ = evaluate(model, synth_val, device)
            re_, rn, rcer, _ = evaluate(model, real_test, device)
            print(f"step {step} loss {loss.item():.3f} | synth exact {se}/{sn} | REAL TEST exact {re_}/{rn} ({100*re_/rn:.1f}%) CER {rcer:.3f} | {time.time()-t0:.0f}s", flush=True)
            torch.save(model.state_dict(), "weights/plate_reader.pt")
    re_, rn, rcer, preds = evaluate(model, real_test, device)
    # contains real plate numbers, so it is kept out of the repository
    os.makedirs(os.path.join(ROOT, "private_results"), exist_ok=True)
    with open(os.path.join(ROOT, "private_results", "ocr_ours_predictions.csv"), "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["truth", "pred", "conf"])
        for (p, c), (t, _) in zip(preds, real_test):
            w.writerow([t, p, f"{c:.3f}"])
    print(f"FINAL REAL TEST exact {re_}/{rn} ({100*re_/rn:.1f}%) CER {rcer:.3f}")


if __name__ == "__main__":
    main()
