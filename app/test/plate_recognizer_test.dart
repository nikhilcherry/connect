import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:connect/services/plate_recognizer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // test/golden/canonicalize_golden.json is written by ml/export_reader.py from the
  // Python code the reader was trained with (ml/canon.py), on synthetic plates.
  final golden = (jsonDecode(File('test/golden/canonicalize_golden.json').readAsStringSync()) as List).cast<Map<String, dynamic>>();

  test('Dart preprocessing matches the training code (synthetic plates)', () {
    expect(golden, isNotEmpty);
    for (final g in golden) {
      final w = g['w'] as int, h = g['h'] as int;
      final rgb = (g['rgba'] as List).cast<List>();
      final rgba = Uint8List(w * h * 4);
      for (var i = 0; i < w * h; i++) {
        rgba[i * 4] = rgb[i][0] as int;
        rgba[i * 4 + 1] = rgb[i][1] as int;
        rgba[i * 4 + 2] = rgb[i][2] as int;
        rgba[i * 4 + 3] = 255;
      }
      final got = canonicalizePlate(rgba, w, h);
      final want = (g['canon'] as List).cast<num>();
      expect(got.length, want.length);
      var maxDiff = 0.0, sum = 0.0;
      for (var i = 0; i < got.length; i++) {
        final d = (got[i] - want[i]).abs();
        if (d > maxDiff) maxDiff = d;
        sum += d;
      }
      final mean = sum / got.length;
      // A different resize implementation may differ by a grey level or two.
      expect(mean, lessThan(0.02), reason: '${g['file']} ($w x $h) mean abs diff $mean, max $maxDiff');
    }
  });

  test('CTC decoding collapses repeats and drops blanks', () {
    // classes = 37 (36 chars + blank). Sequence: K K blank A A blank 1 -> "KA1"
    const classes = 37;
    List<double> row(int k) => [for (var c = 0; c < classes; c++) c == k ? 10.0 : 0.0];
    final k = recCharset.indexOf('K'), a = recCharset.indexOf('A'), one = recCharset.indexOf('1');
    final flat = <double>[...row(k), ...row(k), ...row(36), ...row(a), ...row(a), ...row(36), ...row(one)];
    final r = decodeCtc(flat, 7, classes);
    expect(r.text, 'KA1');
    expect(r.confidence, greaterThan(0.99));
  });

  test('the same letter twice in a row needs a blank between', () {
    const classes = 37;
    List<double> row(int k) => [for (var c = 0; c < classes; c++) c == k ? 10.0 : 0.0];
    final z = recCharset.indexOf('Z');
    expect(decodeCtc([...row(z), ...row(36), ...row(z)], 3, classes).text, 'ZZ');
    expect(decodeCtc([...row(z), ...row(z)], 2, classes).text, 'Z');
  });

  test('an empty reading has zero confidence', () {
    const classes = 37;
    final blanks = [for (var t = 0; t < 4; t++) for (var c = 0; c < classes; c++) c == 36 ? 10.0 : 0.0];
    final r = decodeCtc(blanks, 4, classes);
    expect(r.text, '');
    expect(r.confidence, 0);
  });
}
