import 'dart:io';

import 'package:connect/l10n.dart';
import 'package:connect/services/bridge.dart';
import 'package:connect/services/plate_reader.dart';
import 'package:connect/services/situation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_mlkit_image_labeling/google_mlkit_image_labeling.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // adb push integration_test/assets/plate.png /data/local/tmp/plate.png
  Future<File> asset(String name) async {
    final f = File('${(await getTemporaryDirectory()).path}/$name');
    return File('/data/local/tmp/$name').copy(f.path);
  }

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
