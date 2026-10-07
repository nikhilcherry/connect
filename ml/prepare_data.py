"""Convert the Roboflow license-plate dataset (COCO json) to YOLO format.

Dataset: keremberke/license-plate-object-detection on Hugging Face, CC BY 4.0,
8,823 images (train 6,176 / valid 1,765 / test 882), one class: license_plate.

    python3 prepare_data.py ~/ml-data/plates

Expects raw/{train,valid,test}/ (each with _annotations.coco.json and the
images) under the given directory and writes yolo/{train,val,test}/ with
images (symlinked) and labels, plus plates.yaml for ultralytics.
"""
import json
import os
import sys

root = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser("~/ml-data/plates"))
SPLITS = {"train": "train", "valid": "val", "test": "test"}

stats = {}
for src, dst in SPLITS.items():
    d = os.path.join(root, "raw", src)
    coco = json.load(open(os.path.join(d, "_annotations.coco.json")))
    img_dir = os.path.join(root, "yolo", dst, "images")
    lbl_dir = os.path.join(root, "yolo", dst, "labels")
    os.makedirs(img_dir, exist_ok=True)
    os.makedirs(lbl_dir, exist_ok=True)
    boxes = {}
    for a in coco["annotations"]:
        boxes.setdefault(a["image_id"], []).append(a["bbox"])
    n_boxes = 0
    for im in coco["images"]:
        name = im["file_name"]
        link = os.path.join(img_dir, name)
        if not os.path.exists(link):
            os.symlink(os.path.join(d, name), link)
        w, h = im["width"], im["height"]
        lines = []
        for x, y, bw, bh in boxes.get(im["id"], []):
            cx, cy = (x + bw / 2) / w, (y + bh / 2) / h
            nw, nh = bw / w, bh / h
            if nw <= 0 or nh <= 0:
                continue
            lines.append(f"0 {cx:.6f} {cy:.6f} {nw:.6f} {nh:.6f}")
        n_boxes += len(lines)
        with open(os.path.join(lbl_dir, os.path.splitext(name)[0] + ".txt"), "w") as f:
            f.write("\n".join(lines) + ("\n" if lines else ""))
    stats[dst] = {"images": len(coco["images"]), "boxes": n_boxes}

with open(os.path.join(root, "plates.yaml"), "w") as f:
    f.write(f"path: {os.path.join(root, 'yolo')}\ntrain: train/images\nval: val/images\ntest: test/images\nnames:\n  0: license_plate\n")
print(json.dumps(stats, indent=2))
