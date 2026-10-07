import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/services.dart' show rootBundle;
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'damage_cost.dart';
import 'plate_detector.dart';

const _typeColors = {
  DamageType.crack: ui.Color(0xFFE5484D),
  DamageType.dent: ui.Color(0xFF5A45C9),
  DamageType.glassShatter: ui.Color(0xFF0090FF),
  DamageType.lampBroken: ui.Color(0xFFF76B15),
  DamageType.scratch: ui.Color(0xFF30A46C),
  DamageType.tireFlat: ui.Color(0xFF8E4EC6),
};

ui.Color damageColor(DamageType t) => _typeColors[t]!;

/// The photo with a box around each finding, as PNG bytes (for the PDF).
Future<Uint8List> annotatedPhoto(Pixels px, List<DamageFinding> findings) async {
  final comp = Completer<ui.Image>();
  ui.decodeImageFromPixels(px.rgba, px.width, px.height, ui.PixelFormat.rgba8888, comp.complete);
  final img = await comp.future;
  final rec = ui.PictureRecorder();
  final canvas = ui.Canvas(rec);
  canvas.drawImage(img, ui.Offset.zero, ui.Paint());
  final stroke = (px.width / 200).clamp(2.0, 10.0);
  for (final f in findings) {
    final r = ui.Rect.fromLTRB(f.left * px.width, f.top * px.height, f.right * px.width, f.bottom * px.height);
    canvas.drawRect(
      r,
      ui.Paint()
        ..style = ui.PaintingStyle.stroke
        ..strokeWidth = stroke
        ..color = damageColor(f.type),
    );
  }
  final out = await rec.endRecording().toImage(px.width, px.height);
  final png = await out.toByteData(format: ui.ImageByteFormat.png);
  img.dispose();
  out.dispose();
  return png!.buffer.asUint8List();
}

/// An evidence report for the owner or an insurer: the annotated photo, what was found
/// and a rough cost range. Always English with Latin digits (the bundled fonts cover
/// Latin only). The estimate is stated as indicative, never as a quote.
Future<Uint8List> buildDamageReport({
  required Uint8List annotatedPng,
  required List<DamageFinding> findings,
  required CostEstimate estimate,
  String? car,
  String? plate,
  DateTime? when,
}) async {
  await initializeDateFormatting('en');
  final regular = pw.Font.ttf(await rootBundle.load('assets/fonts/manrope-400.ttf'));
  final bold = pw.Font.ttf(await rootBundle.load('assets/fonts/manrope-700.ttf'));
  final display = pw.Font.ttf(await rootBundle.load('assets/fonts/space-grotesk-700.ttf'));
  const ink = PdfColor.fromInt(0xFF171335), muted = PdfColor.fromInt(0xFF575279), line = PdfColor.fromInt(0xFFDAD7EC);
  final money = NumberFormat.decimalPattern('en_IN');
  pw.TextStyle t(double s, {pw.Font? font, PdfColor color = ink}) => pw.TextStyle(font: font ?? regular, fontSize: s, color: color, lineSpacing: 2);
  final stamp = DateFormat('d MMM yyyy, h:mm a', 'en').format(when ?? DateTime.now());

  final doc = pw.Document(title: 'Damage report', author: 'Connect');
  doc.addPage(pw.MultiPage(
    pageFormat: PdfPageFormat.a4,
    margin: const pw.EdgeInsets.fromLTRB(40, 44, 40, 44),
    footer: (c) => pw.Text('Made with Connect. Found by a model on the phone; a rough estimate, not a quote or an inspection.', style: t(8, color: muted)),
    build: (c) => [
      pw.Text('Damage report', style: t(24, font: display)),
      pw.SizedBox(height: 4),
      pw.Text([stamp, ?car, ?plate].join('  ·  '), style: t(10, color: muted)),
      pw.SizedBox(height: 14),
      pw.Image(pw.MemoryImage(annotatedPng), height: 300, fit: pw.BoxFit.contain),
      pw.SizedBox(height: 14),
      pw.Text('What was found', style: t(13, font: bold)),
      pw.SizedBox(height: 6),
      if (findings.isEmpty)
        pw.Text('No damage was detected in this photo.', style: t(11))
      else
        pw.Table(
          border: pw.TableBorder(horizontalInside: pw.BorderSide(color: line)),
          columnWidths: {0: const pw.FlexColumnWidth(3), 1: const pw.FlexColumnWidth(1), 2: const pw.FlexColumnWidth(2)},
          children: [
            for (final l in estimate.lines)
              pw.TableRow(children: [
                pw.Padding(padding: const pw.EdgeInsets.symmetric(vertical: 5), child: pw.Text(l.type.label, style: t(11))),
                pw.Padding(padding: const pw.EdgeInsets.symmetric(vertical: 5), child: pw.Text('x${l.count}', style: t(11))),
                pw.Padding(padding: const pw.EdgeInsets.symmetric(vertical: 5), child: pw.Text('Rs ${money.format(l.low)} to ${money.format(l.high)}', style: t(11))),
              ]),
          ],
        ),
      pw.SizedBox(height: 12),
      if (!estimate.isEmpty) ...[
        pw.Text('Rough repair cost: Rs ${money.format(estimate.low)} to Rs ${money.format(estimate.high)}', style: t(14, font: bold)),
        pw.SizedBox(height: 4),
        for (final n in estimate.notes) pw.Text(n, style: t(9, color: muted)),
        pw.SizedBox(height: 6),
        pw.Text(
          'Indicative only. Real cost depends on the parts, paint, your city and the garage. Get a written quote before any repair.',
          style: t(9, color: muted),
        ),
      ],
    ],
  ));
  return doc.save();
}
