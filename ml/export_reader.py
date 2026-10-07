"""Export the trained plate reader to ONNX and check it against PyTorch.

    python export_reader.py weights/plate_reader.pt ../app/assets/models/plate_reader.onnx
"""
import csv
import os
import sys

import numpy as np
import onnxruntime as ort
import torch

import canon
import ocr_model as om

src, dst = sys.argv[1], sys.argv[2]
m = om.PlateCRNN()
m.load_state_dict(torch.load(src, map_location="cpu"))
m.eval()
x = torch.zeros(1, 1, canon.H, canon.W)
torch.onnx.export(m, x, dst, input_names=["input"], output_names=["logits"], opset_version=14, dynamo=False)
print("exported", dst, os.path.getsize(dst) // 1024, "KB")

# parity on real held-out crops
sess = ort.InferenceSession(dst, providers=["CPUExecutionProvider"])
d = os.path.expanduser("~/ml-data/indian-plates/real_test")
import cv2

rows = list(csv.reader(open(os.path.join(d, "labels.csv"))))[1:60]
worst, agree = 0.0, 0
for f, t in rows:
    im = cv2.cvtColor(cv2.imread(os.path.join(d, f)), cv2.COLOR_BGR2RGB)
    inp = torch.from_numpy(canon.canonicalize(im))[None, None]
    with torch.no_grad():
        a = m(inp).numpy()
    b = sess.run(None, {"input": inp.numpy()})[0]
    worst = max(worst, float(np.abs(a - b).max()))
    agree += om.decode(torch.from_numpy(a))[0][0] == om.decode(torch.from_numpy(b))[0][0]
print(f"max |torch - onnx| logits = {worst:.2e}; identical decodes {agree}/{len(rows)}")

# golden vectors so the Dart port of canonicalize can be tested for parity. SYNTHETIC
# plates only: real crops come from a dataset whose licence is unspecified, so none of
# its pixels are committed.
import json
import random

import synth_plates as sp

rng = random.Random(2026)
gold = []
while len(gold) < 5:
    t, im = sp.sample(rng)
    if im.shape[1] > 170:  # keep the committed file small
        continue
    i = len(gold)
    g = canon.canonicalize(im)
    gold.append({"file": f"synthetic_{i}", "w": im.shape[1], "h": im.shape[0], "rgba": im.reshape(-1, 3).tolist(), "canon": g.flatten().round(5).tolist(), "text": t})
os.makedirs("golden", exist_ok=True)
json.dump(gold, open("golden/canonicalize_golden.json", "w"), separators=(",", ":"))
print("wrote golden vectors", len(gold))
