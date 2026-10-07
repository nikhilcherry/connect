"""Pre-generate the plate-reader training set into numpy files (no torch, so the
worker processes are small).

    python gen_ocr_data.py <n_synthetic> <out_dir>

Writes x.npy (N,32,160 uint8 canonical gray, 0..255), y.npy (N,12 int8, -1 padded),
n.npy (lengths) and kind.npy (0 synthetic, 1 real-augmented). Real crops come from
real_train only (never the held-out test plates).
"""
import csv
import multiprocessing as mp
import os
import random
import sys

import cv2
import numpy as np

import canon
import synth_plates as sp

ROOT = os.path.expanduser("~/ml-data/indian-plates")
MAXLEN = 12


def to_u8(a):
    return np.clip((a * 0.5 + 0.5) * 255.0 + 0.5, 0, 255).astype(np.uint8)


def enc(t):
    return [sp.CHARSET.index(c) for c in t] + [-1] * (MAXLEN - len(t))


def real_augment(img, rng):
    a = img.astype(np.float32) * rng.uniform(0.7, 1.3) + rng.uniform(-20, 20)
    h, w = img.shape[:2]
    if rng.random() < 0.5:
        s = rng.uniform(0.5, 1.0)
        a = cv2.resize(cv2.resize(a.clip(0, 255).astype(np.uint8), (max(8, int(w * s)), max(8, int(h * s)))), (w, h)).astype(np.float32)
    a = a + np.random.normal(0, rng.uniform(0, 6), a.shape)
    return a.clip(0, 255).astype(np.uint8)


def work(args):
    seed, n, real_copies = args
    cv2.setNumThreads(1)
    rng = random.Random(seed)
    np.random.seed(seed)
    xs, ys, ns, kinds = [], [], [], []
    for _ in range(n):
        t, im = sp.sample(rng)
        xs.append(to_u8(canon.canonicalize(im)))
        ys.append(enc(t))
        ns.append(len(t))
        kinds.append(0)
    if real_copies:
        d = os.path.join(ROOT, "real_train")
        rows = list(csv.reader(open(os.path.join(d, "labels.csv"))))[1:]
        for f, t in rows:
            im = cv2.cvtColor(cv2.imread(os.path.join(d, f), cv2.IMREAD_COLOR), cv2.COLOR_BGR2RGB)
            for _ in range(real_copies):
                xs.append(to_u8(canon.canonicalize(real_augment(im, rng))))
                ys.append(enc(t))
                ns.append(len(t))
                kinds.append(1)
    return np.stack(xs), np.array(ys, np.int8), np.array(ns, np.int16), np.array(kinds, np.int8)


if __name__ == "__main__":
    total, out = int(sys.argv[1]), sys.argv[2]
    os.makedirs(out, exist_ok=True)
    procs = 12
    per = total // procs
    # Each process also makes a share of augmented copies of every real training crop.
    jobs = [(1000 + i, per, 4) for i in range(procs)]
    with mp.Pool(procs) as pool:
        parts = pool.map(work, jobs)
    x = np.concatenate([p[0] for p in parts])
    y = np.concatenate([p[1] for p in parts])
    n = np.concatenate([p[2] for p in parts])
    k = np.concatenate([p[3] for p in parts])
    perm = np.random.default_rng(0).permutation(len(x))
    np.save(os.path.join(out, "x.npy"), x[perm])
    np.save(os.path.join(out, "y.npy"), y[perm])
    np.save(os.path.join(out, "n.npy"), n[perm])
    np.save(os.path.join(out, "kind.npy"), k[perm])
    print(f"wrote {len(x)} samples ({int(k.sum())} real-augmented) to {out}; {x.nbytes/1e6:.0f} MB")
