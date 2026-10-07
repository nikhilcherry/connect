"""Strip non-standard opset domains from an ONNX model so ONNX Runtime 1.15 (on the phone) loads it.
    python fix_opset.py model.onnx
"""
import sys

import onnx

p = sys.argv[1]
m = onnx.load(p)
used = {(n.domain or "ai.onnx") for n in m.graph.node}
assert used <= {"ai.onnx"}, f"model uses non-standard domains: {used}"
keep = [o for o in m.opset_import if o.domain in ("", "ai.onnx")]
del m.opset_import[:]
m.opset_import.extend(keep)
m.ir_version = min(m.ir_version, 8)
onnx.save(m, p)
print("ok", p, [(o.domain or "ai.onnx", o.version) for o in m.opset_import], "ir", m.ir_version)
