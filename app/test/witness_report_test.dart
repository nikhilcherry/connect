import 'dart:io';
import 'dart:typed_data';

import 'package:connect/services/plate_detector.dart';
import 'package:connect/services/witness.dart';
import 'package:connect/services/witness_report.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final at = DateTime(2026, 10, 10, 0, 19, 19);

  testWidgets('the incident record builds, with the frames and the plates around the bump', (tester) async {
    late Uint8List pdf;
    await tester.runAsync(() async {
      // Two plain frames are enough: this tests the record, not the camera.
      final dir = Directory.systemTemp.createTempSync('witness');
      final photos = <String>[];
      for (final (i, shade) in const [120, 170].indexed) {
        final px = Pixels(Uint8List.fromList(List.generate(180 * 320 * 4, (k) => k % 4 == 3 ? 255 : shade)), 180, 320);
        final f = File('${dir.path}/$i.png')..writeAsBytesSync(await px.toPng());
        photos.add(f.path);
      }
      final plates = rankPlates([
        for (var k = 0; k < 6; k++) PlateSighting('KA13LV3970', at.add(Duration(milliseconds: -9000 + k * 2200)), 0.9),
        PlateSighting('MH12DE1433', at.add(const Duration(seconds: 2)), 0.95),
      ]);
      pdf = await buildWitnessReport(Incident(at: at, peakG: 1.5, plates: plates, photos: photos), car: 'Maruti Suzuki Swift', plate: 'KA 05 EM 2026');
      dir.deleteSync(recursive: true);
    });
    expect(String.fromCharCodes(pdf.sublist(0, 5)), '%PDF-');
    expect(pdf.length, greaterThan(5000));
    final out = Platform.environment['WITNESS_PDF_OUT'];
    if (out != null) File(out).writeAsBytesSync(pdf);
  });

  testWidgets('a moment marked by hand with nothing in view still makes a record', (tester) async {
    late Uint8List pdf;
    await tester.runAsync(() async {
      pdf = await buildWitnessReport(Incident(at: at, peakG: 0, plates: const [], photos: const ['/nowhere/gone.png'], manual: true));
    });
    expect(String.fromCharCodes(pdf.sublist(0, 5)), '%PDF-');
  });
}
