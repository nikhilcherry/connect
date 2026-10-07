import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:onnxruntime/onnxruntime.dart';

/// A detected number plate, in pixels of the image that was searched.
class PlateBox {
  const PlateBox(this.left, this.top, this.right, this.bottom, this.score);
  final double left, top, right, bottom, score;
  double get width => right - left;
  double get height => bottom - top;
  double get area => math.max(0, width) * math.max(0, height);

  @override
  String toString() => 'PlateBox(${left.toStringAsFixed(1)}, ${top.toStringAsFixed(1)}, ${right.toStringAsFixed(1)}, ${bottom.toStringAsFixed(1)}, ${score.toStringAsFixed(2)})';
}

/// How an image is scaled and padded to fit the model's square input without
/// distorting it (the same "letterbox" the model was trained with).
class Letterbox {
  Letterbox._(this.scale, this.padX, this.padY, this.size);
  final double scale, padX, padY;
  final int size;

  factory Letterbox.fit(int w, int h, int size) {
    final scale = math.min(size / w, size / h);
    final nw = (w * scale).round(), nh = (h * scale).round();
    return Letterbox._(scale, ((size - nw) ~/ 2).toDouble(), ((size - nh) ~/ 2).toDouble(), size);
  }
}

/// The detector's own tuning. Trained at 416 px; see ml/README.md.
const plateModelSize = 416;
const plateModelAsset = 'assets/models/plate_n.onnx';

/// Turns the model's raw output (channel-major [x, y, w, h, score] per
/// candidate, in letterboxed pixels) into boxes in the original image, after
/// non-maximum suppression. Pure, so it is unit-tested without the model.
List<PlateBox> decodePlates(
  Float32List out,
  int candidates,
  Letterbox lb,
  int imgW,
  int imgH, {
  double minScore = 0.35,
  double iou = 0.5,
  int maxBoxes = 5,
}) {
  final found = <PlateBox>[];
  for (var i = 0; i < candidates; i++) {
    final score = out[4 * candidates + i];
    if (score < minScore) continue;
    final cx = out[i], cy = out[candidates + i], w = out[2 * candidates + i], h = out[3 * candidates + i];
    final l = ((cx - w / 2 - lb.padX) / lb.scale).clamp(0, imgW).toDouble();
    final t = ((cy - h / 2 - lb.padY) / lb.scale).clamp(0, imgH).toDouble();
    final r = ((cx + w / 2 - lb.padX) / lb.scale).clamp(0, imgW).toDouble();
    final b = ((cy + h / 2 - lb.padY) / lb.scale).clamp(0, imgH).toDouble();
    if (r - l < 2 || b - t < 2) continue;
    found.add(PlateBox(l, t, r, b, score));
  }
  return nonMaxSuppression(found, iou).take(maxBoxes).toList();
}

double _iou(PlateBox a, PlateBox b) {
  final l = math.max(a.left, b.left), t = math.max(a.top, b.top);
  final r = math.min(a.right, b.right), bt = math.min(a.bottom, b.bottom);
  final inter = math.max(0, r - l) * math.max(0, bt - t);
  final union = a.area + b.area - inter;
  return union <= 0 ? 0 : inter / union;
}

List<PlateBox> nonMaxSuppression(List<PlateBox> boxes, double iouThreshold) {
  final sorted = [...boxes]..sort((a, b) => b.score.compareTo(a.score));
  final kept = <PlateBox>[];
  for (final b in sorted) {
    if (kept.every((k) => _iou(k, b) < iouThreshold)) kept.add(b);
  }
  return kept;
}

/// RGBA pixels → the model's NCHW float input, letterboxed with grey padding
/// and bilinear sampling.
Float32List rgbaToInput(Uint8List rgba, int w, int h, Letterbox lb) {
  final size = lb.size;
  final plane = size * size;
  final out = Float32List(3 * plane)..fillRange(0, 3 * plane, 114 / 255);
  final nw = (w * lb.scale).round(), nh = (h * lb.scale).round();
  final x0 = lb.padX.toInt(), y0 = lb.padY.toInt();
  for (var y = 0; y < nh; y++) {
    final sy = math.max(0.0, math.min(h - 1.0, (y + 0.5) / lb.scale - 0.5));
    final iy = sy.floor(), fy = sy - iy, iy2 = math.min(h - 1, iy + 1);
    for (var x = 0; x < nw; x++) {
      final sx = math.max(0.0, math.min(w - 1.0, (x + 0.5) / lb.scale - 0.5));
      final ix = sx.floor(), fx = sx - ix, ix2 = math.min(w - 1, ix + 1);
      final o = (y0 + y) * size + x0 + x;
      for (var c = 0; c < 3; c++) {
        final p00 = rgba[(iy * w + ix) * 4 + c], p01 = rgba[(iy * w + ix2) * 4 + c];
        final p10 = rgba[(iy2 * w + ix) * 4 + c], p11 = rgba[(iy2 * w + ix2) * 4 + c];
        final v = (p00 * (1 - fx) + p01 * fx) * (1 - fy) + (p10 * (1 - fx) + p11 * fx) * fy;
        out[c * plane + o] = v / 255.0;
      }
    }
  }
  return out;
}

/// A decoded picture: RGBA bytes plus size.
class Pixels {
  Pixels(this.rgba, this.width, this.height);
  final Uint8List rgba;
  final int width, height;

  /// Decodes an image file, shrinking it while decoding so a 12 MP photo does
  /// not cost 48 MB of RGBA. EXIF rotation is applied by the codec.
  static Future<Pixels> fromFile(File f, {int maxSide = 1600}) async {
    final bytes = await f.readAsBytes();
    final probe = await ui.instantiateImageCodec(bytes);
    final first = (await probe.getNextFrame()).image;
    final big = math.max(first.width, first.height);
    first.dispose();
    probe.dispose();
    final codec = await ui.instantiateImageCodec(
      bytes,
      targetWidth: big > maxSide ? (first.width >= first.height ? maxSide : null) : null,
      targetHeight: big > maxSide ? (first.height > first.width ? maxSide : null) : null,
    );
    final img = (await codec.getNextFrame()).image;
    final data = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
    final px = Pixels(data!.buffer.asUint8List(), img.width, img.height);
    img.dispose();
    codec.dispose();
    return px;
  }

  /// A PNG of [box] grown by [pad] (a fraction of its size) on each side, for
  /// the text reader. Plates are read far better cropped than inside a scene.
  Future<Uint8List> cropPng(PlateBox box, {double pad = 0.12, int minWidth = 400}) async {
    final l = math.max(0, box.left - box.width * pad).floor();
    final t = math.max(0, box.top - box.height * pad).floor();
    final r = math.min(width, box.right + box.width * pad).ceil();
    final b = math.min(height, box.bottom + box.height * pad).ceil();
    final cw = r - l, ch = b - t;
    final src = Uint8List(cw * ch * 4);
    for (var y = 0; y < ch; y++) {
      src.setRange(y * cw * 4, (y + 1) * cw * 4, rgba, ((t + y) * width + l) * 4);
    }
    final comp = Completer<ui.Image>();
    ui.decodeImageFromPixels(src, cw, ch, ui.PixelFormat.rgba8888, comp.complete);
    final cropped = await comp.future;
    // Upscale small crops: the recogniser needs a few dozen pixels per character.
    final scale = cw < minWidth ? minWidth / cw : 1.0;
    final rec = ui.PictureRecorder();
    final canvas = ui.Canvas(rec);
    canvas.scale(scale);
    canvas.drawImage(cropped, ui.Offset.zero, ui.Paint()..filterQuality = ui.FilterQuality.high);
    final scaled = await rec.endRecording().toImage((cw * scale).round(), (ch * scale).round());
    final png = await scaled.toByteData(format: ui.ImageByteFormat.png);
    cropped.dispose();
    scaled.dispose();
    return png!.buffer.asUint8List();
  }
}

/// The on-device plate detector: a YOLO11n we trained on 8,823 plate photos,
/// run with ONNX Runtime. See ml/README.md for how it was built and scored.
class PlateDetector {
  PlateDetector._(this._session);
  final OrtSession _session;
  static PlateDetector? _shared;

  static Future<PlateDetector> load() async {
    if (_shared != null) return _shared!;
    OrtEnv.instance.init();
    final bytes = (await rootBundle.load(plateModelAsset)).buffer.asUint8List();
    final opts = OrtSessionOptions()..setIntraOpNumThreads(2);
    return _shared = PlateDetector._(OrtSession.fromBuffer(bytes, opts));
  }

  Future<List<PlateBox>> detect(Pixels px, {double minScore = 0.35}) async {
    final lb = Letterbox.fit(px.width, px.height, plateModelSize);
    final input = rgbaToInput(px.rgba, px.width, px.height, lb);
    final tensor = OrtValueTensor.createTensorWithDataList(input, [1, 3, plateModelSize, plateModelSize]);
    final runOpts = OrtRunOptions();
    List<OrtValue?>? outputs;
    try {
      outputs = _session.run(runOpts, {_session.inputNames.first: tensor});
      final raw = outputs.first!.value as List; // [1][5][candidates]
      final channels = raw.first as List;
      final n = (channels.first as List).length;
      final flat = Float32List(5 * n);
      for (var c = 0; c < 5; c++) {
        final row = channels[c] as List;
        for (var i = 0; i < n; i++) {
          flat[c * n + i] = (row[i] as num).toDouble();
        }
      }
      return decodePlates(flat, n, lb, px.width, px.height, minScore: minScore);
    } finally {
      tensor.release();
      runOpts.release();
      outputs?.forEach((o) => o?.release());
    }
  }
}
