import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'witness.dart';

/// A record of one incident for the owner, the other driver or an insurer:
/// when, how hard, the frames the phone kept, and the plates it read around
/// that moment. Always English with Latin digits (the bundled fonts cover
/// Latin only). The plates are stated as readings to check, never as proof.
Future<Uint8List> buildWitnessReport(Incident incident, {String? car, String? plate}) async {
  await initializeDateFormatting('en');
  final regular = pw.Font.ttf(await rootBundle.load('assets/fonts/manrope-400.ttf'));
  final bold = pw.Font.ttf(await rootBundle.load('assets/fonts/manrope-700.ttf'));
  final display = pw.Font.ttf(await rootBundle.load('assets/fonts/space-grotesk-700.ttf'));
  const ink = PdfColor.fromInt(0xFF171335), muted = PdfColor.fromInt(0xFF575279), line = PdfColor.fromInt(0xFFDAD7EC);
  pw.TextStyle t(double s, {pw.Font? font, PdfColor color = ink}) => pw.TextStyle(font: font ?? regular, fontSize: s, color: color, lineSpacing: 2);
  final stamp = DateFormat('d MMM yyyy, h:mm:ss a', 'en').format(incident.at);

  final photos = <pw.MemoryImage>[];
  for (final path in incident.photos.take(2)) {
    final f = File(path);
    if (await f.exists()) photos.add(pw.MemoryImage(await f.readAsBytes()));
  }

  /// "9 s before" / "2 s after" the bump.
  String offset(DateTime at) {
    final s = (at.difference(incident.at).inMilliseconds / 1000).round();
    return s == 0 ? 'at the moment' : (s < 0 ? '${-s} s before' : '$s s after');
  }

  pw.Widget cell(String text, {pw.Font? font}) =>
      pw.Padding(padding: const pw.EdgeInsets.symmetric(vertical: 5), child: pw.Text(text, style: t(11, font: font)));

  final doc = pw.Document(title: 'Incident record', author: 'Connect');
  doc.addPage(pw.MultiPage(
    pageFormat: PdfPageFormat.a4,
    margin: const pw.EdgeInsets.fromLTRB(40, 44, 40, 44),
    footer: (c) => pw.Text(
      'Made with Connect. Plates were read by a model on the phone and can be wrong: check them against the photos.',
      style: t(8, color: muted),
    ),
    build: (c) => [
      pw.Text('Incident record', style: t(24, font: display)),
      pw.SizedBox(height: 4),
      pw.Text([stamp, ?car, ?plate].join('  ·  '), style: t(10, color: muted)),
      pw.SizedBox(height: 12),
      pw.Text(
        incident.manual
            ? 'Marked by hand on a phone watching from the car.'
            : 'A phone watching from the car felt a bump of about ${incident.peakG.toStringAsFixed(1)} g.',
        style: t(12),
      ),
      pw.SizedBox(height: 14),
      if (photos.isNotEmpty)
        pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
          for (var i = 0; i < photos.length; i++) ...[
            if (i > 0) pw.SizedBox(width: 12),
            pw.Expanded(
              child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
                pw.Image(photos[i], height: 260, fit: pw.BoxFit.contain),
                pw.SizedBox(height: 4),
                pw.Text(i == 0 ? 'At the bump' : 'A few seconds after', style: t(9, color: muted)),
              ]),
            ),
          ],
        ]),
      pw.SizedBox(height: 16),
      pw.Text('Number plates in view', style: t(13, font: bold)),
      pw.SizedBox(height: 6),
      if (incident.plates.isEmpty)
        pw.Text('No plate was read in the ${Incident.before.inSeconds} seconds before the bump or the ${Incident.after.inSeconds} after.', style: t(11))
      else
        pw.Table(
          border: pw.TableBorder(horizontalInside: pw.BorderSide(color: line)),
          columnWidths: {0: const pw.FlexColumnWidth(3), 1: const pw.FlexColumnWidth(2), 2: const pw.FlexColumnWidth(4)},
          children: [
            for (final p in incident.plates)
              pw.TableRow(children: [
                cell(p.plate, font: bold),
                cell('${p.count} frame${p.count == 1 ? '' : 's'}'),
                cell(p.firstSeen == p.lastSeen ? offset(p.firstSeen) : 'from ${offset(p.firstSeen)} to ${offset(p.lastSeen)}'),
              ]),
          ],
        ),
      pw.SizedBox(height: 12),
      pw.Text(
        'The phone keeps the plates it reads for a minute and a half and writes down those around a bump. Everything stayed on the phone until its owner shared this record.',
        style: t(9, color: muted),
      ),
    ],
  ));
  return doc.save();
}
