import 'dart:typed_data';

import 'package:connect/services/plate_detector.dart';
import 'package:flutter_test/flutter_test.dart';

/// A model output with every candidate at score 0, then [hits] filled in.
/// Layout is channel-major: [x..., y..., w..., h..., score...].
Float32List output(int n, List<List<double>> hits) {
  final o = Float32List(5 * n);
  for (var k = 0; k < hits.length; k++) {
    for (var c = 0; c < 5; c++) {
      o[c * n + k] = hits[k][c];
    }
  }
  return o;
}

void main() {
  yuvTests();
  group('Letterbox', () {
    test('a wide photo is scaled to the width and padded top and bottom', () {
      final lb = Letterbox.fit(832, 416, 416);
      expect(lb.scale, 0.5);
      expect(lb.padX, 0);
      expect(lb.padY, 104); // (416 - 208) / 2
    });

    test('a tall photo is padded left and right', () {
      final lb = Letterbox.fit(208, 416, 416);
      expect(lb.scale, 1.0);
      expect(lb.padX, 104);
      expect(lb.padY, 0);
    });
  });

  group('decodePlates', () {
    final lb = Letterbox.fit(832, 416, 416); // scale 0.5, padY 104

    test('maps a box from model pixels back to the original image', () {
      // Centre (208, 208) in the 416 square, 100 x 40: model box x 158..258, y 188..228.
      final boxes = decodePlates(output(10, [[208, 208, 100, 40, 0.9]]), 10, lb, 832, 416);
      expect(boxes, hasLength(1));
      expect(boxes.single.left, closeTo(316, 0.01)); // 158 / 0.5
      expect(boxes.single.right, closeTo(516, 0.01));
      expect(boxes.single.top, closeTo(168, 0.01)); // (188 - 104) / 0.5
      expect(boxes.single.bottom, closeTo(248, 0.01));
      expect(boxes.single.score, closeTo(0.9, 1e-6));
    });

    test('drops low scores and keeps the best of overlapping boxes', () {
      final boxes = decodePlates(
        output(10, [
          [208, 208, 100, 40, 0.9],
          [210, 208, 100, 40, 0.7], // same plate, lower score
          [100, 150, 60, 30, 0.2], // below threshold
          [320, 300, 80, 30, 0.8], // a second plate
        ]),
        10,
        lb,
        832,
        416,
      );
      expect(boxes.map((b) => b.score), [closeTo(0.9, 1e-6), closeTo(0.8, 1e-6)]);
    });

    test('clamps boxes that run off the image and ignores slivers', () {
      final off = decodePlates(output(4, [[2, 208, 100, 40, 0.9]]), 4, lb, 832, 416);
      expect(off.single.left, 0);
      expect(decodePlates(output(4, [[208, 208, 0.5, 0.5, 0.9]]), 4, lb, 832, 416), isEmpty);
    });
  });

  test('rgbaToInput letterboxes with grey and normalises to 0..1 in NCHW', () {
    // A 4x2 solid red image into a 4x4 square: scale 1, pad 1 row top and bottom.
    final rgba = Uint8List(4 * 2 * 4);
    for (var i = 0; i < 8; i++) {
      rgba.setAll(i * 4, [255, 0, 0, 255]);
    }
    final lb = Letterbox.fit(4, 2, 4);
    final input = rgbaToInput(rgba, 4, 2, lb);
    const plane = 16;
    expect(input.length, 3 * plane);
    expect(input[0], closeTo(114 / 255, 1e-6)); // padded row, red channel
    expect(input[1 * 4 + 0], 1.0); // image row, red
    expect(input[plane + 1 * 4 + 0], 0.0); // image row, green
    expect(input[3 * 4 + 0], closeTo(114 / 255, 1e-6)); // bottom padding
  });
}

void yuvTests() {
  group('yuv420ToPixels', () {
    // 4x2 frame: left half bright (Y 200), right half dark (Y 50), neutral chroma.
    final y = Uint8List.fromList([200, 200, 50, 50, 200, 200, 50, 50]);
    final u = Uint8List.fromList([128, 128]); // (4/2) x (2/2) chroma samples
    final v = Uint8List.fromList([128, 128]);

    test('neutral chroma gives grey of the luma value', () {
      final px = yuv420ToPixels(y: y, u: u, v: v, width: 4, height: 2, yRowStride: 4, uvRowStride: 2, uvPixelStride: 1);
      expect(px.width, 4);
      expect(px.height, 2);
      expect(px.rgba.sublist(0, 4), [200, 200, 200, 255]);
      expect(px.rgba.sublist(12, 16), [50, 50, 50, 255]);
    });

    test('rotating 90 degrees swaps the size and turns the picture clockwise', () {
      final px = yuv420ToPixels(y: y, u: u, v: v, width: 4, height: 2, yRowStride: 4, uvRowStride: 2, uvPixelStride: 1, rotation: 90);
      expect(px.width, 2);
      expect(px.height, 4);
      // Turned clockwise, the bright left half ends up on top, the dark right half below.
      expect(px.rgba[0], 200); // top row
      expect(px.rgba[(3 * 2) * 4], 50); // bottom row
    });

    test('honours a padded row stride', () {
      // Same frame but each Y row padded to 6 bytes.
      final padded = Uint8List.fromList([200, 200, 50, 50, 0, 0, 200, 200, 50, 50, 0, 0]);
      final px = yuv420ToPixels(y: padded, u: u, v: v, width: 4, height: 2, yRowStride: 6, uvRowStride: 2, uvPixelStride: 1);
      expect(px.rgba.sublist(16, 20), [200, 200, 200, 255]); // second row, first pixel
    });

    test('saturated red chroma comes out red', () {
      final px = yuv420ToPixels(
        y: Uint8List.fromList([76, 76]),
        u: Uint8List.fromList([85]),
        v: Uint8List.fromList([255]),
        width: 2,
        height: 1,
        yRowStride: 2,
        uvRowStride: 1,
        uvPixelStride: 1,
      );
      expect(px.rgba[0], greaterThan(200));
      expect(px.rgba[1], lessThan(60));
      expect(px.rgba[2], lessThan(60));
    });
  });
}
