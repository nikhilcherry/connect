import 'dart:io';

import 'package:connect/l10n.dart';
import 'package:connect/services/bridge.dart';
import 'package:connect/services/plate_reader.dart';
import 'package:connect/services/situation.dart';
import 'package:flutter_test/flutter_test.dart';
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

  testWidgets('language id + translation run on the device', (t) async {
    final r = await translateTo('आपकी गाड़ी रास्ता रोक रही है', AppLang.en);
    // ignore: avoid_print
    print('TRANSLATED ${r?.text}');
    expect(r, isNotNull);
    expect(r!.text.toLowerCase(), anyOf(contains('car'), contains('vehicle')));
  });
}
