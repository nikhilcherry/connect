// ignore_for_file: unnecessary_import
import 'dart:io';

import 'package:connect/l10n.dart';
import 'package:connect/services/bridge.dart';
import 'package:connect/services/plate_detector.dart';
import 'package:connect/services/plate_reader.dart';
import 'package:connect/services/situation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:google_mlkit_image_labeling/google_mlkit_image_labeling.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

// adb push integration_test/assets/*.{png,jpg} /data/local/tmp/
Future<File> asset(String name) async {
  final f = File('${(await getTemporaryDirectory()).path}/$name');
  return File('/data/local/tmp/$name').copy(f.path);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('OCR reads a plate photo on the device', (t) async {
    final plates = await readPlates(await asset('plate.png'));
    // ignore: avoid_print
    print('PLATES $plates');
    expect(plates, ['KA01AB1234']);
  });

  testWidgets('image labelling runs on the device', (t) async {
    final s = await readSituation(await asset('plate.png'));
    // ignore: avoid_print
    print('SITUATION ${s?.kind}');
  });

  carPhoto();
  realWorldPlates();

  // Our own YOLO11n plate detector, run on the device with ONNX Runtime.
  // adb push integration_test/assets/car_with_plate.jpg /data/local/tmp/
  // Ground truth (472x303 test photo): plate at x 233..331, y 106..193.
  testWidgets('our plate detector finds the plate in a real photo', (t) async {
    final f = await asset('car_with_plate.jpg');
    final px = await Pixels.fromFile(f);
    final detector = await PlateDetector.load();
    final sw = Stopwatch()..start();
    final boxes = await detector.detect(px);
    sw.stop();
    final sw2 = Stopwatch()..start();
    for (var i = 0; i < 5; i++) {
      await detector.detect(px);
    }
    sw2.stop();
    // ignore: avoid_print
    print('DETECT ${px.width}x${px.height} first=${sw.elapsedMilliseconds}ms avg5=${sw2.elapsedMilliseconds ~/ 5}ms boxes=$boxes');
    expect(boxes, isNotEmpty);
    final s = px.width / 472;
    final gt = PlateBox(233 * s, 106 * s, 331 * s, 193 * s, 1);
    final b = boxes.first;
    final l = [b.left, gt.left].reduce((a, c) => a > c ? a : c), tp = [b.top, gt.top].reduce((a, c) => a > c ? a : c);
    final r = [b.right, gt.right].reduce((a, c) => a < c ? a : c), bt = [b.bottom, gt.bottom].reduce((a, c) => a < c ? a : c);
    final inter = (r - l).clamp(0, 1e9) * (bt - tp).clamp(0, 1e9);
    final iou = inter / (b.area + gt.area - inter);
    // ignore: avoid_print
    print('IOU ${iou.toStringAsFixed(3)}');
    expect(iou, greaterThan(0.6));
  });

  testWidgets('owner reply is translated into the stranger\'s language on the device', (t) async {
    final r = await translateReply('I am coming in five minutes, please wait', assumed: AppLang.en, to: AppLang.kn);
    // ignore: avoid_print
    print('REPLY_KN ${r.text}');
    expect(r.same, isFalse);
    expect(r.text, isNot(contains('coming')));
    expect(RegExp(r'[\u0C80-\u0CFF]').hasMatch(r.text), isTrue, reason: 'should contain Kannada script');
  });

  testWidgets('language id + translation run on the device', (t) async {
    final r = await translateTo('आपकी गाड़ी रास्ता रोक रही है', AppLang.en);
    // ignore: avoid_print
    print('TRANSLATED ${r?.text}');
    expect(r, isNotNull);
    expect(r!.text.toLowerCase(), anyOf(contains('car'), contains('vehicle')));
  });
}

// Real photo test: adb push a car photo to /data/local/tmp/car.jpg first.
void carPhoto() {
  testWidgets('image labelling on a real car photo', (t) async {
    final src = File('/data/local/tmp/car.jpg');
    if (!src.existsSync()) return;
    final f = await src.copy('${(await getTemporaryDirectory()).path}/car.jpg');
    final labeler = ImageLabeler(options: ImageLabelerOptions(confidenceThreshold: 0.3));
    final labels = await labeler.processImage(InputImage.fromFile(f));
    await labeler.close();
    // ignore: avoid_print
    print('LABELS ${labels.map((l) => '${l.label}:${l.confidence.toStringAsFixed(2)}').join(', ')}');
    final s = interpretLabels({for (final l in labels) l.label: l.confidence});
    // ignore: avoid_print
    print('SUGGESTION ${s?.kind} ${s?.urgency}');
  });
}


/// Real photos: adb push /tmp/.../kolkata.jpg bangalore.jpg to /data/local/tmp/.
void realWorldPlates() {
  for (final name in ['kolkata.jpg', 'bangalore.jpg']) {
    testWidgets('pipeline on $name', (t) async {
      final src = File('/data/local/tmp/$name');
      if (!src.existsSync()) return;
      final f = await asset(name);
      final sw = Stopwatch()..start();
      final r = await readPlatesInPhoto(f);
      // ignore: avoid_print
      print('PIPELINE $name ${sw.elapsedMilliseconds}ms detector=${r.usedDetector} boxes=${r.boxes} plates=${r.plates}');
      final whole = await readPlates(f);
      // ignore: avoid_print
      print('WHOLE    $name plates=$whole');
    });
  }
}


