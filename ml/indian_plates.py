"""Split the real Indian plate crops (HF zenitsu09/indian-number-plate) into a
held-out TEST set and a TRAIN set, **by plate text**, so no plate appears on
both sides (the dataset holds each plate several times as augmented copies).

    python3 indian_plates.py ~/ml-data/indian-plates/train.parquet ~/ml-data/indian-plates

Only clean labels are used: ^LL dd L{1,3} dddd$ with a real state code. Writes
real_train/ and real_test/ (png + labels.csv). The licence of this dataset is
unspecified, so it is used here for research and is not redistributed.
"""
import csv
import io
import os
import random
import re
import sys

import pyarrow.parquet as pq
from PIL import Image

STATES = set("AN AP AR AS BR CG CH DD DL DN GA GJ HP HR JH JK KA KL LA LD MH ML MN MP MZ NL OD OR PB PY RJ SK TN TR TS UK UP WB".split())
PAT = re.compile(r"^([A-Z]{2})\d{2}[A-Z]{1,3}\d{4}$")
TEST_PLATES = 150

src, out = sys.argv[1], sys.argv[2]
rows = pq.read_table(src).to_pylist()
by_text = {}
for r in rows:
    text = (r["plate_text"] or "").upper().replace(" ", "")
    m = PAT.match(text)
    if not m or m.group(1) not in STATES:
        continue
    im = Image.open(io.BytesIO(r["image"]["bytes"])).convert("RGB")
    if im.width > 700:  # a full scene, not a crop
        continue
    by_text.setdefault(text, []).append((im, r["orig_filename"]))

texts = sorted(by_text)
random.Random(0).shuffle(texts)
test_texts, train_texts = set(texts[:TEST_PLATES]), set(texts[TEST_PLATES:])


def write(split, items):
    d = os.path.join(out, split)
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, "labels.csv"), "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["file", "text"])
        for i, (text, im) in enumerate(items):
            name = f"{split}_{i:04d}.png"
            im.save(os.path.join(d, name))
            w.writerow([name, text])


# Test: one copy per plate (the median-sized one), never the augmented siblings.
test = []
for t in sorted(test_texts):
    ims = sorted(by_text[t], key=lambda x: x[0].width * x[0].height)
    test.append((t, ims[len(ims) // 2][0]))
train = [(t, im) for t in sorted(train_texts) for im, _ in by_text[t]]
write("real_test", test)
write("real_train", train)
two_row = sum(1 for _, im in test if im.width / im.height < 2.5)
print(f"unique clean plates {len(texts)}: test {len(test)} (two-row {two_row}), train {len(train)} images from {len(train_texts)} plates")
