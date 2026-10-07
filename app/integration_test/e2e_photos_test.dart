// ignore_for_file: avoid_print, unnecessary_import
// End to end, photo in and plate text out, on real Indian phone photos: the whole app
// pipeline (our detector + our reader + ML Kit on the crop) against the old way (ML Kit
// reading the whole photo). The photos and the plate labels stay out of the repository.
//   adb push ~/ml-data/dc-eval/e2e/photos /data/local/tmp/dc_photos
//   flutter test integration_test/e2e_photos_test.dart -d <device>
import 'dart:io';

import 'package:connect/services/plate_reader.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('real Indian phone photos: our pipeline vs ML Kit on the whole photo', (t) async {
    final dir = Directory('/data/local/tmp/dc_photos');
    if (!dir.existsSync()) return;
    final truth = <String, Set<String>>{};
    for (final l in File('${dir.path}/labels.csv').readAsLinesSync().skip(1)) {
      final p = l.split(',');
      (truth[p[0]] ??= {}).add(p[1]);
    }
    var plates = 0, baseFound = 0, ourFound = 0, baseTop1 = 0, ourTop1 = 0, usedDetector = 0;
    var baseMs = 0, ourMs = 0;
    for (final e in truth.entries) {
      final f = File('${dir.path}/${e.key}');
      plates += e.value.length;
      var sw = Stopwatch()..start();
      final base = await readPlates(f);
      baseMs += sw.elapsedMilliseconds;
      sw = Stopwatch()..start();
      final ours = await readPlatesInPhoto(f);
      ourMs += sw.elapsedMilliseconds;
      if (ours.usedDetector) usedDetector++;
      baseFound += e.value.where(base.contains).length;
      ourFound += e.value.where(ours.plates.contains).length;
      if (base.isNotEmpty && e.value.contains(base.first)) baseTop1++;
      if (ours.plates.isNotEmpty && e.value.contains(ours.plates.first)) ourTop1++;
    }
    print('E2E photos=${truth.length} plates=$plates');
    print('E2E mlkit_whole_photo  found=$baseFound/$plates  right_first=$baseTop1/${truth.length}  avg_ms=${baseMs ~/ truth.length}');
    print('E2E app_pipeline       found=$ourFound/$plates  right_first=$ourTop1/${truth.length}  avg_ms=${ourMs ~/ truth.length}  detector_used=$usedDetector');
  });
}
