"""Turn the Datacluster "Indian Number Plates" free sample (Pascal VOC) into a
YOLO-format evaluation set. EVALUATION ONLY: the sample is CC BY-NC-ND 4.0 and
meant for evaluation, so it is never used for training and never redistributed.

    python3 prepare_dc_eval.py ~/ml-data/dc-eval
"""
import os
import sys
import xml.etree.ElementTree as ET

root = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser("~/ml-data/dc-eval"))
img_dir, ann_dir = os.path.join(root, "images"), os.path.join(root, "ann")
out_img, out_lbl = os.path.join(root, "yolo", "val", "images"), os.path.join(root, "yolo", "val", "labels")
os.makedirs(out_img, exist_ok=True)
os.makedirs(out_lbl, exist_ok=True)
n_img = n_box = 0
for name in sorted(os.listdir(ann_dir)):
    tree = ET.parse(os.path.join(ann_dir, name)).getroot()
    w = float(tree.findtext("size/width"))
    h = float(tree.findtext("size/height"))
    lines = []
    for o in tree.findall("object"):
        b = o.find("bndbox")
        x0, y0, x1, y1 = (float(b.findtext(k)) for k in ("xmin", "ymin", "xmax", "ymax"))
        lines.append(f"0 {(x0 + x1) / 2 / w:.6f} {(y0 + y1) / 2 / h:.6f} {(x1 - x0) / w:.6f} {(y1 - y0) / h:.6f}")
    stem = os.path.splitext(name)[0]
    link = os.path.join(out_img, stem + ".jpg")
    if not os.path.exists(link):
        os.symlink(os.path.join(img_dir, stem + ".jpg"), link)
    open(os.path.join(out_lbl, stem + ".txt"), "w").write("\n".join(lines) + "\n")
    n_img += 1
    n_box += len(lines)
open(os.path.join(root, "dc.yaml"), "w").write(f"path: {os.path.join(root, 'yolo')}\ntrain: val/images\nval: val/images\nnames:\n  0: license_plate\n")
print(f"{n_img} images, {n_box} boxes")
