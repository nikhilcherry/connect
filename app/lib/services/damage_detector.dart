import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:onnxruntime/onnxruntime.dart';

import 'damage_cost.dart';
import 'plate_detector.dart';

/// The on-device car-damage detector: a YOLO11s we trained on ~10 000 labelled photos, INT8
/// (ml/README.md). Six classes, but only four are trustworthy: the training data has
/// 56 broken-lamp and 4 flat-tyre examples, so those two are reported as "low confidence".
const damageModelAsset = 'assets/models/damage_detector.onnx';
const damageModelSize = 512;
const damageClasses = 6;
const reliableDamage = {DamageType.scratch, DamageType.dent, DamageType.crack, DamageType.glassShatter};

/// Decodes the model output ([x, y, w, h, class0..class5] per candidate, channel-major, in
/// letterboxed pixels) into findings with boxes normalised to the original photo, after
/// per-class non-maximum suppression. Pure, so it is unit-tested without the model.
List<DamageFinding> decodeDamage(
  Float32List out,
  int candidates,
  Letterbox lb,
  int imgW,
  int imgH, {
  double minScore = 0.25,
  double iou = 0.5,
  int maxFindings = 12,
}) {
  final perClass = <int, List<PlateBox>>{};
  for (var i = 0; i < candidates; i++) {
    var best = 0;
    var bestScore = 0.0;
    for (var c = 0; c < damageClasses; c++) {
      final s = out[(4 + c) * candidates + i];
      if (s > bestScore) {
        bestScore = s;
        best = c;
      }
    }
    if (bestScore < minScore) continue;
    final cx = out[i], cy = out[candidates + i], w = out[2 * candidates + i], h = out[3 * candidates + i];
    final l = ((cx - w / 2 - lb.padX) / lb.scale).clamp(0, imgW).toDouble();
    final t = ((cy - h / 2 - lb.padY) / lb.scale).clamp(0, imgH).toDouble();
    final r = ((cx + w / 2 - lb.padX) / lb.scale).clamp(0, imgW).toDouble();
    final b = ((cy + h / 2 - lb.padY) / lb.scale).clamp(0, imgH).toDouble();
    if (r - l < 3 || b - t < 3) continue;
    (perClass[best] ??= []).add(PlateBox(l, t, r, b, bestScore));
  }
  final found = <DamageFinding>[];
  perClass.forEach((c, boxes) {
    for (final b in nonMaxSuppression(boxes, iou)) {
      found.add(DamageFinding(DamageType.values[c], b.score, b.left / imgW, b.top / imgH, b.right / imgW, b.bottom / imgH));
    }
  });
  found.sort((a, b) => b.score.compareTo(a.score));
  return found.take(maxFindings).toList();
}

class DamageDetector {
  DamageDetector._(this._session);
  final OrtSession _session;
  static DamageDetector? _shared;

  static Future<DamageDetector> load() async {
    if (_shared != null) return _shared!;
    OrtEnv.instance.init();
    final bytes = (await rootBundle.load(damageModelAsset)).buffer.asUint8List();
    final opts = OrtSessionOptions()..setIntraOpNumThreads(2);
    return _shared = DamageDetector._(OrtSession.fromBuffer(bytes, opts));
  }

  Future<List<DamageFinding>> detect(Pixels px, {double minScore = 0.25}) async {
    final lb = Letterbox.fit(px.width, px.height, damageModelSize);
    final input = rgbaToInput(px.rgba, px.width, px.height, lb);
    final tensor = OrtValueTensor.createTensorWithDataList(input, [1, 3, damageModelSize, damageModelSize]);
    final runOpts = OrtRunOptions();
    List<OrtValue?>? outputs;
    try {
      outputs = _session.run(runOpts, {_session.inputNames.first: tensor});
      final channels = (outputs.first!.value as List).first as List; // [4 + classes][candidates]
      final n = (channels.first as List).length;
      final flat = Float32List((4 + damageClasses) * n);
      for (var c = 0; c < 4 + damageClasses; c++) {
        final row = channels[c] as List;
        for (var i = 0; i < n; i++) {
          flat[c * n + i] = (row[i] as num).toDouble();
        }
      }
      return decodeDamage(flat, n, lb, px.width, px.height, minScore: minScore);
    } finally {
      tensor.release();
      runOpts.release();
      outputs?.forEach((o) => o?.release());
    }
  }
}
