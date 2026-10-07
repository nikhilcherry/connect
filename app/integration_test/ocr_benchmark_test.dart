// ignore_for_file: avoid_print, unnecessary_import
// Benchmark: how well does ML Kit read the held-out real Indian plate crops?
//   adb push ~/ml-data/indian-plates/real_test /data/local/tmp/ocr_test
//   flutter test integration_test/ocr_benchmark_test.dart -d <device>
import 'dart:io';

import 'package:connect/services/plate_detector.dart';
import 'package:connect/services/plate_reader.dart';
import 'package:connect/services/plate_recognizer.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('ML Kit on held-out real Indian plate crops', (t) async {
    final dir = Directory('/data/local/tmp/ocr_test');
    if (!dir.existsSync()) return;
    final rows = File('${dir.path}/labels.csv').readAsLinesSync().skip(1).map((l) => l.split(','));
    final rec = TextRecognizer(script: TextRecognitionScript.latin);
    var n = 0, rawOk = 0, parsedOk = 0;
    for (final r in rows) {
      final file = File('${dir.path}/${r[0]}'), truth = r[1];
      final text = (await rec.processImage(InputImage.fromFile(file))).text;
      final raw = text.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
      final parsed = extractPlates(text);
      final pick = parsed.isEmpty ? '' : parsed.first;
      n++;
      if (raw == truth) rawOk++;
      if (pick == truth) parsedOk++;
      print('MLKIT,${r[0]},$truth,$raw,$pick');
    }
    await rec.close();
    print('MLKIT_SUMMARY n=$n raw_exact=$rawOk parsed_exact=$parsedOk');
  });

  // Our own reader, run on the device through ONNX Runtime, on the same raw crops.
  //   adb push ~/ml-data/indian-plates/real_test /data/local/tmp/ocr_raw
  testWidgets('our reader on held-out real Indian plate crops (on device)', (t) async {
    final dir = Directory('/data/local/tmp/ocr_raw');
    if (!dir.existsSync()) return;
    final rows = File('${dir.path}/labels.csv').readAsLinesSync().skip(1).map((l) => l.split(','));
    final reader = await PlateRecognizer.load();
    var n = 0, ok = 0;
    final sw = Stopwatch()..start();
    for (final r in rows) {
      final px = await Pixels.fromFile(File('${dir.path}/${r[0]}'), maxSide: 4000);
      final res = reader.read(px.rgba, px.width, px.height);
      n++;
      if (res.text == r[1]) ok++;
      print('OURS,${r[0]},${r[1]},${res.text},${res.confidence.toStringAsFixed(3)}');
    }
    print('OURS_SUMMARY n=$n exact=$ok ms_per_plate=${sw.elapsedMilliseconds ~/ n}');
  });
}
