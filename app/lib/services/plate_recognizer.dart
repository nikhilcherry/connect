import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:onnxruntime/onnxruntime.dart';

import 'plate_detector.dart';

/// Our own plate reader: a small CRNN + CTC (0.87 M parameters, 3.5 MB) trained on
/// synthetic Indian plates plus real crops. See ml/README.md for how it was trained
/// and how it scores against ML Kit on held-out real plates.
///
/// Input is a gray 32x160 image: a single-row plate resized to 160x32; a two-row
/// plate (width/height < 2.5) split into halves, each resized to 80x32, side by side.
/// This must match ml/canon.py exactly.
const recognizerAsset = 'assets/models/plate_reader.onnx';
const recH = 32, recW = 160;
const twoRowAspect = 2.5;
const recCharset = '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ';

/// RGBA → 8-bit gray, as OpenCV does it (0.299 R + 0.587 G + 0.114 B, rounded).
Uint8List rgbaToGray(Uint8List rgba, int w, int h) {
  final g = Uint8List(w * h);
  for (var i = 0; i < w * h; i++) {
    g[i] = (rgba[i * 4] * 0.299 + rgba[i * 4 + 1] * 0.587 + rgba[i * 4 + 2] * 0.114).round().clamp(0, 255);
  }
  return g;
}

/// Resizes a gray image like OpenCV: area averaging when shrinking in either axis,
/// bilinear with half-pixel centres otherwise.
Float32List resizeGray(Uint8List src, int sw, int sh, int dw, int dh) {
  final out = Float32List(dw * dh);
  final shrink = sw > dw || sh > dh;
  if (shrink) {
    final fx = sw / dw, fy = sh / dh;
    for (var y = 0; y < dh; y++) {
      final y0 = y * fy, y1 = (y + 1) * fy;
      for (var x = 0; x < dw; x++) {
        final x0 = x * fx, x1 = (x + 1) * fx;
        var sum = 0.0, wsum = 0.0;
        for (var yy = y0.floor(); yy < math.min(sh, y1.ceil()); yy++) {
          final wy = math.min(yy + 1.0, y1) - math.max(yy.toDouble(), y0);
          for (var xx = x0.floor(); xx < math.min(sw, x1.ceil()); xx++) {
            final wx = math.min(xx + 1.0, x1) - math.max(xx.toDouble(), x0);
            final wgt = wx * wy;
            sum += src[yy * sw + xx] * wgt;
            wsum += wgt;
          }
        }
        out[y * dw + x] = sum / wsum;
      }
    }
  } else {
    final fx = sw / dw, fy = sh / dh;
    for (var y = 0; y < dh; y++) {
      final sy = ((y + 0.5) * fy - 0.5).clamp(0.0, sh - 1.0).toDouble();
      final y0 = sy.floor(), y1 = math.min(sh - 1, y0 + 1), ay = sy - y0;
      for (var x = 0; x < dw; x++) {
        final sx = ((x + 0.5) * fx - 0.5).clamp(0.0, sw - 1.0).toDouble();
        final x0 = sx.floor(), x1 = math.min(sw - 1, x0 + 1), ax = sx - x0;
        final top = src[y0 * sw + x0] * (1 - ax) + src[y0 * sw + x1] * ax;
        final bot = src[y1 * sw + x0] * (1 - ax) + src[y1 * sw + x1] * ax;
        out[y * dw + x] = top * (1 - ay) + bot * ay;
      }
    }
  }
  return out;
}

/// A cropped plate (RGBA) → the model's float input in -1..1, [recH * recW].
Float32List canonicalizePlate(Uint8List rgba, int w, int h) {
  final gray = rgbaToGray(rgba, w, h);
  final out = Float32List(recH * recW);
  void put(Float32List part, int pw, int xOff) {
    for (var y = 0; y < recH; y++) {
      for (var x = 0; x < pw; x++) {
        // cv2 resizes to uint8, so round before normalising
        out[y * recW + xOff + x] = (part[y * pw + x].round().clamp(0, 255) / 255.0 - 0.5) / 0.5;
      }
    }
  }

  if (w / h < twoRowAspect) {
    final half = h ~/ 2;
    final top = Uint8List.sublistView(gray, 0, half * w);
    final bottom = Uint8List.sublistView(gray, half * w, h * w);
    put(resizeGray(top, w, half, recW ~/ 2, recH), recW ~/ 2, 0);
    put(resizeGray(bottom, w, h - half, recW ~/ 2, recH), recW ~/ 2, recW ~/ 2);
  } else {
    put(resizeGray(gray, w, h, recW, recH), recW, 0);
  }
  return out;
}

/// Greedy CTC decode of [steps] x [classes] logits (blank = last class).
({String text, double confidence}) decodeCtc(List<double> logits, int steps, int classes) {
  final blank = classes - 1;
  final chars = StringBuffer();
  final confs = <double>[];
  var prev = blank;
  for (var t = 0; t < steps; t++) {
    var best = 0;
    var maxv = -double.infinity;
    for (var c = 0; c < classes; c++) {
      final v = logits[t * classes + c];
      if (v > maxv) {
        maxv = v;
        best = c;
      }
    }
    if (best != prev && best != blank) {
      var denom = 0.0;
      for (var c = 0; c < classes; c++) {
        denom += math.exp(logits[t * classes + c] - maxv);
      }
      chars.write(recCharset[best]);
      confs.add(1 / denom);
    }
    prev = best;
  }
  final conf = confs.isEmpty ? 0.0 : confs.reduce((a, b) => a + b) / confs.length;
  return (text: chars.toString(), confidence: conf);
}

class PlateRecognizer {
  PlateRecognizer._(this._session);
  final OrtSession _session;
  static PlateRecognizer? _shared;

  static Future<PlateRecognizer> load() async {
    if (_shared != null) return _shared!;
    OrtEnv.instance.init();
    final bytes = (await rootBundle.load(recognizerAsset)).buffer.asUint8List();
    final opts = OrtSessionOptions()..setIntraOpNumThreads(2);
    return _shared = PlateRecognizer._(OrtSession.fromBuffer(bytes, opts));
  }

  /// Reads one cropped plate (RGBA, any size).
  ({String text, double confidence}) read(Uint8List rgba, int w, int h) {
    final input = canonicalizePlate(rgba, w, h);
    final tensor = OrtValueTensor.createTensorWithDataList(input, [1, 1, recH, recW]);
    final runOpts = OrtRunOptions();
    List<OrtValue?>? outputs;
    try {
      outputs = _session.run(runOpts, {_session.inputNames.first: tensor});
      final raw = (outputs.first!.value as List).first as List; // [steps][classes]
      final steps = raw.length, classes = (raw.first as List).length;
      final flat = <double>[
        for (final row in raw) for (final v in row as List) (v as num).toDouble(),
      ];
      return decodeCtc(flat, steps, classes);
    } finally {
      tensor.release();
      runOpts.release();
      outputs?.forEach((o) => o?.release());
    }
  }

  /// Reads the crop of [box] from [px] (with a little padding).
  ({String text, double confidence}) readBox(Pixels px, PlateBox box, {double pad = 0.06}) {
    final c = px.crop(box, pad: pad);
    return read(c.rgba, c.width, c.height);
  }
}
