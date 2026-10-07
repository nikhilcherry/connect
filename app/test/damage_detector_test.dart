import 'dart:typed_data';

import 'package:connect/services/damage_cost.dart';
import 'package:connect/services/damage_detector.dart';
import 'package:connect/services/plate_detector.dart';
import 'package:flutter_test/flutter_test.dart';

/// Output tensor, channel-major: 4 box rows + 6 class rows, [n] candidates each.
Float32List out(int n, List<({double cx, double cy, double w, double h, int cls, double score})> hits) {
  final o = Float32List((4 + damageClasses) * n);
  for (var k = 0; k < hits.length; k++) {
    final h = hits[k];
    o[0 * n + k] = h.cx;
    o[1 * n + k] = h.cy;
    o[2 * n + k] = h.w;
    o[3 * n + k] = h.h;
    o[(4 + h.cls) * n + k] = h.score;
  }
  return o;
}

void main() {
  final lb = Letterbox.fit(1024, 1024, damageModelSize); // scale 0.5, no padding

  test('maps a box back to a normalised box in the photo, with its class', () {
    final r = decodeDamage(out(8, [(cx: 256, cy: 256, w: 100, h: 50, cls: 1, score: 0.8)]), 8, lb, 1024, 1024);
    expect(r, hasLength(1));
    expect(r.single.type, DamageType.dent);
    expect(r.single.left, closeTo((256 - 50) / 512, 1e-6));
    expect(r.single.right, closeTo((256 + 50) / 512, 1e-6));
    expect(r.single.top, closeTo((256 - 25) / 512, 1e-6));
    expect(r.single.score, closeTo(0.8, 1e-6));
  });

  test('suppression is per class: a scratch over a dent keeps both', () {
    final r = decodeDamage(
      out(8, [
        (cx: 200, cy: 200, w: 80, h: 60, cls: 1, score: 0.7), // dent
        (cx: 202, cy: 200, w: 80, h: 60, cls: 4, score: 0.6), // scratch, same place
        (cx: 204, cy: 200, w: 80, h: 60, cls: 1, score: 0.5), // duplicate dent
      ]),
      8,
      lb,
      1024,
      1024,
    );
    expect(r.map((f) => f.type).toSet(), {DamageType.dent, DamageType.scratch});
    expect(r.where((f) => f.type == DamageType.dent), hasLength(1));
  });

  test('low scores are dropped and results come back best first', () {
    final r = decodeDamage(
      out(8, [
        (cx: 100, cy: 100, w: 40, h: 40, cls: 4, score: 0.9),
        (cx: 300, cy: 300, w: 40, h: 40, cls: 0, score: 0.15),
        (cx: 400, cy: 100, w: 40, h: 40, cls: 2, score: 0.6),
      ]),
      8,
      lb,
      1024,
      1024,
    );
    expect(r.map((f) => f.score), [closeTo(0.9, 1e-6), closeTo(0.6, 1e-6)]);
  });

  test('only four classes are marked reliable', () {
    expect(reliableDamage, {DamageType.scratch, DamageType.dent, DamageType.crack, DamageType.glassShatter});
    expect(reliableDamage.contains(DamageType.lampBroken), isFalse);
    expect(reliableDamage.contains(DamageType.tireFlat), isFalse);
  });
}
