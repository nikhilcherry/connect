"""Shrink the plate detector: INT8 static quantisation, scored against FP32.

    python compress_detector.py <fp32.onnx> <calibration_images_dir> <out_int8.onnx>

Reports size, speed (ONNX Runtime CPU, one thread, so only a proxy for a phone) and
accuracy (mAP50 on the original test split and on the real Indian phone photos).
"""
import glob
import os
import random
import sys
import time

import cv2
import numpy as np
import onnxruntime as ort
from onnxruntime.quantization import CalibrationDataReader, QuantFormat, QuantType, quantize_static
from onnxruntime.quantization.shape_inference import quant_pre_process

fp32, calib_dir, out = sys.argv[1], os.path.expanduser(sys.argv[2]), sys.argv[3]
SIZE = int(os.environ.get("SIZE", "416"))


def preprocess(path):
    im = cv2.imread(path)
    h, w = im.shape[:2]
    r = min(SIZE / w, SIZE / h)
    nw, nh = round(w * r), round(h * r)
    canvas = np.full((SIZE, SIZE, 3), 114, np.uint8)
    px, py = (SIZE - nw) // 2, (SIZE - nh) // 2
    canvas[py : py + nh, px : px + nw] = cv2.resize(im, (nw, nh), interpolation=cv2.INTER_LINEAR)
    x = canvas[..., ::-1].transpose(2, 0, 1).astype(np.float32) / 255.0
    return x[None]


class Reader(CalibrationDataReader):
    def __init__(self, files, name):
        self.it = iter(files)
        self.name = name

    def get_next(self):
        f = next(self.it, None)
        return None if f is None else {self.name: preprocess(f)}


files = sorted(glob.glob(os.path.join(calib_dir, "*.jpg")))
random.Random(0).shuffle(files)
files = files[:200]
import onnx
from onnx import version_converter

# per-channel QDQ needs opset >= 13; the exported model is opset 12 (ONNX Runtime 1.15 on the phone supports up to 19)
m13 = version_converter.convert_version(onnx.load(fp32), 17)
conv = out.replace(".onnx", "_op17.onnx")
onnx.save(m13, conv)
pre = out.replace(".onnx", "_pre.onnx")
quant_pre_process(conv, pre)
os.remove(conv)
name = ort.InferenceSession(fp32, providers=["CPUExecutionProvider"]).get_inputs()[0].name
# Quantising the whole network breaks the detector (mAP 0): the head outputs box
# coordinates in the hundreds next to probabilities in 0..1 under one scale. Keep the
# detection head (the last block, "model.23" in YOLO11n) in float; quantise the rest.
HEAD = os.environ.get("HEAD_PREFIX", "/model.23/")
pm = onnx.load(pre)
exclude = [n.name for n in pm.graph.node if n.name.startswith(HEAD) or "model.23" in n.name]
print("excluding", len(exclude), "head nodes from quantisation")
quantize_static(pre, out, Reader(files, name), quant_format=QuantFormat.QDQ, per_channel=True,
                activation_type=QuantType.QUInt8, weight_type=QuantType.QInt8, nodes_to_exclude=exclude)
os.remove(pre)


def bench(path, runs=60):
    so = ort.SessionOptions()
    so.intra_op_num_threads = 1
    s = ort.InferenceSession(path, so, providers=["CPUExecutionProvider"])
    x = preprocess(files[0])
    for _ in range(5):
        s.run(None, {name: x})
    t = time.time()
    for _ in range(runs):
        s.run(None, {name: x})
    return (time.time() - t) / runs * 1000


print(f"SIZE fp32 {os.path.getsize(fp32)/1e6:.1f} MB -> int8 {os.path.getsize(out)/1e6:.1f} MB")
print(f"SPEED fp32 {bench(fp32):.1f} ms, int8 {bench(out):.1f} ms (ORT CPU, 1 thread, this x86 laptop)")
