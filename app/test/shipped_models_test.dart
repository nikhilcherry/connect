import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

/// The phone runs ONNX Runtime 1.15.1 (bundled by the onnxruntime plugin). It reads IR
/// version <= 9 and only released opsets: a model exported or quantised with newer desktop
/// tooling can load fine on a laptop and still be rejected on the phone ("only guarantees
/// support for released opsets"). This reads each shipped model's header, so a bad export
/// fails in CI instead of showing up as "the camera isn't available" on a device.

class _Reader {
  _Reader(this.b);
  final Uint8List b;
  int pos = 0;
  bool get done => pos >= b.length;

  int varint() {
    var shift = 0, v = 0;
    while (true) {
      final x = b[pos++];
      v |= (x & 0x7F) << shift;
      if (x & 0x80 == 0) return v;
      shift += 7;
    }
  }

  Uint8List bytes() {
    final n = varint();
    final out = Uint8List.sublistView(b, pos, pos + n);
    pos += n;
    return out;
  }

  void skip(int wire) {
    switch (wire) {
      case 0:
        varint();
      case 1:
        pos += 8;
      case 2:
        bytes();
      case 5:
        pos += 4;
      default:
        throw StateError('unsupported wire type $wire');
    }
  }
}

({int irVersion, List<({String domain, int version})> opsets}) readHeader(Uint8List model) {
  final r = _Reader(model);
  var ir = 0;
  final opsets = <({String domain, int version})>[];
  while (!r.done) {
    final tag = r.varint();
    final field = tag >> 3, wire = tag & 7;
    if (field == 1 && wire == 0) {
      ir = r.varint();
    } else if (field == 8 && wire == 2) {
      final sub = _Reader(r.bytes());
      var domain = '', version = 0;
      while (!sub.done) {
        final t = sub.varint();
        if (t >> 3 == 1 && t & 7 == 2) {
          domain = String.fromCharCodes(sub.bytes());
        } else if (t >> 3 == 2 && t & 7 == 0) {
          version = sub.varint();
        } else {
          sub.skip(t & 7);
        }
      }
      opsets.add((domain: domain, version: version));
    } else {
      r.skip(wire);
    }
    if (field > 8 && r.pos > 4096) break; // the header fields come first; stop before the big graph
  }
  return (irVersion: ir, opsets: opsets);
}

void main() {
  final dir = Directory('assets/models');
  final models = dir.listSync().whereType<File>().where((f) => f.path.endsWith('.onnx')).toList();

  test('the app ships its three models', () {
    expect(models.map((f) => f.uri.pathSegments.last).toSet(), {'plate_detector.onnx', 'plate_reader.onnx', 'damage_n.onnx'});
  });

  for (final f in models) {
    test('${f.uri.pathSegments.last} can be loaded by ONNX Runtime 1.15 on the phone', () {
      final h = readHeader(f.readAsBytesSync());
      expect(h.irVersion, inInclusiveRange(3, 9), reason: 'IR version ${h.irVersion}');
      expect(h.opsets, isNotEmpty);
      for (final o in h.opsets) {
        expect(o.domain, anyOf('', 'ai.onnx'), reason: 'non-standard operator domain "${o.domain}" v${o.version} is rejected by ORT 1.15');
        expect(o.version, lessThanOrEqualTo(19), reason: 'opset ${o.version} is newer than ORT 1.15 supports');
      }
    });
  }

  test('the header reader catches the bad export we shipped by mistake', () {
    // ModelProto { ir_version: 7, opset_import: [{domain: "ai.onnx.ml", version: 5}] }
    final bad = Uint8List.fromList([0x08, 7, 0x42, 14, 0x0A, 10, ...'ai.onnx.ml'.codeUnits, 0x10, 5]);
    final h = readHeader(bad);
    expect(h.irVersion, 7);
    expect(h.opsets.single.domain, 'ai.onnx.ml');
    expect(h.opsets.single.version, 5);
  });
}
