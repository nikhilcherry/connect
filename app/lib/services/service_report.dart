import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../data/models.dart';
import 'garage_log.dart';

/// Service history as a PDF, built on the phone, for when the car is sold.
/// Always in English with Latin digits: it's read by buyers and dealers, and
/// the bundled fonts cover Latin only.
class ServiceReport {
  static const _ink = PdfColor.fromInt(0xFF171335);
  static const _muted = PdfColor.fromInt(0xFF575279);
  static const _line = PdfColor.fromInt(0xFFDAD7EC);
  static const _violet = PdfColor.fromInt(0xFF5A45C9);
  static const _tint = PdfColor.fromInt(0xFFEEEDF8);

  /// Service and repair visits, oldest first: what the report lists.
  static List<LogEntry> visits(Iterable<LogEntry> entries) =>
      entries.where((e) => e.kind == LogKind.service || e.kind == LogKind.repair).toList()..sort((a, b) => a.date.compareTo(b.date));

  static Future<Uint8List> build(Vehicle v, List<LogEntry> entries, {DateTime? now}) async {
    // The app only loads date symbols for its current language.
    await initializeDateFormatting('en');
    final regular = pw.Font.ttf(await rootBundle.load('assets/fonts/manrope-400.ttf'));
    final bold = pw.Font.ttf(await rootBundle.load('assets/fonts/manrope-700.ttf'));
    final display = pw.Font.ttf(await rootBundle.load('assets/fonts/space-grotesk-700.ttf'));
    final rows = visits(entries);
    final money = NumberFormat.decimalPattern('en_IN');
    final date = DateFormat('d MMM yyyy', 'en');
    final total = rows.fold<double>(0, (s, e) => s + e.amount);
    final latestOdo = entries.map((e) => e.odometer).whereType<int>().fold<int?>(null, (m, o) => m == null || o > m ? o : m);

    pw.TextStyle t(double size, {pw.Font? font, PdfColor color = _ink}) =>
        pw.TextStyle(font: font ?? regular, fontSize: size, color: color, lineSpacing: 2);

    pw.Widget figure(String label, String value) => pw.Expanded(
          child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
            pw.Text(label.toUpperCase(), style: t(8, color: _muted).copyWith(letterSpacing: 1.2)),
            pw.SizedBox(height: 4),
            pw.Text(value, style: t(15, font: display)),
          ]),
        );

    String work(LogEntry e) {
      final what = [if (e.kind == LogKind.repair) 'Repair', if (e.note?.isNotEmpty == true) e.note!].join(': ');
      return [if (what.isNotEmpty) what, if (e.workshop?.isNotEmpty == true) 'at ${e.workshop}'].join(' ');
    }

    final doc = pw.Document(title: 'Service history: ${v.make} ${v.model}', author: 'Connect');
    doc.addPage(pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.fromLTRB(40, 44, 40, 44),
      footer: (c) => pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
        pw.Text('Made with Connect from the owner\'s own records', style: t(8, color: _muted)),
        pw.Text('${c.pageNumber} / ${c.pagesCount}', style: t(8, color: _muted)),
      ]),
      build: (c) => [
        pw.Text('SERVICE HISTORY', style: t(9, font: bold, color: _muted).copyWith(letterSpacing: 1.5)),
        pw.SizedBox(height: 6),
        pw.Text('${v.make} ${v.model}', style: t(26, font: display)),
        pw.SizedBox(height: 4),
        pw.Text([v.prettyReg, if (v.colour != null) v.colour!].join('  ·  '), style: t(11, color: _muted)),
        pw.SizedBox(height: 18),
        pw.Container(
          padding: const pw.EdgeInsets.all(14),
          decoration: pw.BoxDecoration(color: _tint, borderRadius: pw.BorderRadius.circular(8)),
          child: pw.Row(children: [
            figure('Visits', '${rows.length}'),
            figure('Total spent', 'Rs ${money.format(total.round())}'),
            figure('Latest odometer', latestOdo == null ? '-' : '${money.format(latestOdo)} km'),
          ]),
        ),
        pw.SizedBox(height: 22),
        if (rows.isEmpty)
          pw.Text('No service visits recorded yet.', style: t(11, color: _muted))
        else
          pw.TableHelper.fromTextArray(
            border: const pw.TableBorder(horizontalInside: pw.BorderSide(color: _line, width: 0.6)),
            headerStyle: t(9, font: bold, color: _muted),
            headerDecoration: const pw.BoxDecoration(border: pw.Border(bottom: pw.BorderSide(color: _ink, width: 0.8))),
            cellStyle: t(10),
            cellPadding: const pw.EdgeInsets.symmetric(vertical: 7, horizontal: 4),
            columnWidths: {
              0: const pw.FixedColumnWidth(70),
              1: const pw.FixedColumnWidth(70),
              2: const pw.FlexColumnWidth(),
              3: const pw.FixedColumnWidth(64),
            },
            cellAlignments: {3: pw.Alignment.centerRight},
            headers: ['DATE', 'ODOMETER', 'WORK DONE', 'COST'],
            data: [
              for (final e in rows)
                [
                  date.format(e.date),
                  e.odometer == null ? '-' : '${money.format(e.odometer)} km',
                  work(e),
                  'Rs ${money.format(e.amount.round())}',
                ],
            ],
          ),
        pw.SizedBox(height: 18),
        pw.Text('Generated ${date.format(now ?? DateTime.now())}. Entries are as recorded by the owner; ask to see the workshop invoices.',
            style: t(8.5, color: _muted)),
        pw.SizedBox(height: 4),
        pw.UrlLink(
          destination: 'https://connect.example.com',
          child: pw.Text('connect.example.com', style: t(8.5, font: bold, color: _violet)),
        ),
      ],
    ));
    return doc.save();
  }
}
