import 'dart:io';
import 'dart:typed_data';

import 'package:connect/services/damage_cost.dart';
import 'package:connect/services/damage_report.dart';
import 'package:connect/services/plate_detector.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('the evidence PDF builds, with the annotated photo and the estimate', (tester) async {
    final findings = [
      const DamageFinding(DamageType.scratch, 0.72, 0.1, 0.5, 0.4, 0.8),
      const DamageFinding(DamageType.crack, 0.45, 0.5, 0.8, 0.6, 0.9),
    ];
    final estimate = estimateRepairCost(findings, make: 'Maruti Suzuki', lengthMm: 3860);
    late Uint8List pdf;
    await tester.runAsync(() async {
      // a plain 320x200 grey photo is enough: this tests the report, not the model
      final px = Pixels(Uint8List.fromList(List.generate(320 * 200 * 4, (i) => i % 4 == 3 ? 255 : 150)), 320, 200);
      final png = await annotatedPhoto(px, findings);
      expect(png.sublist(1, 4), [0x50, 0x4E, 0x47], reason: 'annotated photo is a PNG');
      pdf = await buildDamageReport(annotatedPng: png, findings: findings, estimate: estimate, car: 'Maruti Suzuki Swift', plate: 'KA01AB1234', when: DateTime(2026, 10, 7, 16, 45));
    });
    expect(String.fromCharCodes(pdf.sublist(0, 5)), '%PDF-');
    expect(pdf.length, greaterThan(5000));
    final out = Platform.environment['DAMAGE_PDF_OUT'];
    if (out != null) File(out).writeAsBytesSync(pdf);
  });

  testWidgets('a report with nothing found still builds', (tester) async {
    late Uint8List pdf;
    await tester.runAsync(() async {
      final px = Pixels(Uint8List.fromList(List.generate(64 * 64 * 4, (i) => 200)), 64, 64);
      pdf = await buildDamageReport(annotatedPng: await annotatedPhoto(px, const []), findings: const [], estimate: estimateRepairCost(const []));
    });
    expect(String.fromCharCodes(pdf.sublist(0, 5)), '%PDF-');
  });
}
