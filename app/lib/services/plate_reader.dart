import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

import 'plate_detector.dart';
import 'plate_recognizer.dart';

/// Pulls Indian number plates out of OCR text. Pure so it can be tested
/// without a camera: the recogniser hands over messy lines, this keeps the
/// ones shaped like a plate and repairs the usual letter/digit mix-ups.
///
///   KA01AB1234   state(2) district(2) series(1-3) number(4)
///   22BH1234AA   Bharat series: year(2) BH number(4) series(2)
List<String> extractPlates(String text) {
  final found = <String>[];
  void add(String p) {
    if (!found.contains(p)) found.add(p);
  }

  // Plates are often split across lines or spaced oddly, so try each line and
  // also the whole text with everything but letters and digits removed.
  final chunks = [...text.split('\n'), text.replaceAll('\n', ' ')];
  for (final chunk in chunks) {
    final s = chunk.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
    var i = 0;
    while (i < s.length) {
      var hit = 0;
      // Longest plate shape first; once one matches, skip past it so its own
      // fragments are not reported as further plates.
      for (final len in const [10, 9, 8]) {
        if (i + len > s.length) continue;
        final p = _repair(s.substring(i, i + len));
        if (p != null) {
          add(p);
          hit = len;
          break;
        }
      }
      i += hit == 0 ? 1 : hit;
    }
  }
  return found;
}

const _toDigit = {'O': '0', 'Q': '0', 'D': '0', 'I': '1', 'L': '1', 'Z': '2', 'S': '5', 'B': '8', 'G': '6'};
const _toLetter = {'0': 'O', '1': 'I', '2': 'Z', '5': 'S', '8': 'B', '6': 'G'};

final _std = RegExp(r'^[A-Z]{2}\d{2}[A-Z]{1,3}\d{4}$');
final _bh = RegExp(r'^\d{2}BH\d{4}[A-Z]{2}$');
final _old = RegExp(r'^[A-Z]{2}\d[A-Z]{1,3}\d{4}$');

/// Fixes letters read as digits (and the reverse) by position, then accepts
/// the string only if it is plate-shaped. Null when it can't be one.
///
/// Two layouts: KA01AB1234 (state, 2-digit district, 1-3 series letters, 4 digits) and the
/// older Delhi-style DL3CAB1234 (state, 1-digit district, then letters, 4 digits).
String? _repair(String raw) {
  String digit(String c) => _toDigit[c] ?? c;
  String letter(String c) => _toLetter[c] ?? c;
  final c = raw.split('');

  // Bharat series: ddBHddddLL
  if (raw.length == 10) {
    final b = [digit(c[0]), digit(c[1]), c[2], c[3], digit(c[4]), digit(c[5]), digit(c[6]), digit(c[7]), letter(c[8]), letter(c[9])].join();
    if (_bh.hasMatch(b)) return b;
  }

  ({String text, int changed})? tryLayout(int districtDigits) {
    final seriesLen = raw.length - 6 - districtDigits;
    if (seriesLen < 1 || seriesLen > 3) return null;
    final out = [
      letter(c[0]),
      letter(c[1]),
      for (var i = 0; i < districtDigits; i++) digit(c[2 + i]),
      for (var i = 2 + districtDigits; i < 2 + districtDigits + seriesLen; i++) letter(c[i]),
      for (var i = 2 + districtDigits + seriesLen; i < raw.length; i++) digit(c[i]),
    ].join();
    final ok = (districtDigits == 2 ? _std : _old).hasMatch(out) && _validState(out.substring(0, 2));
    if (!ok) return null;
    var changed = 0;
    for (var i = 0; i < raw.length; i++) {
      if (raw[i] != out[i]) changed++;
    }
    // Real OCR slips change a character or two; more than that is just text that happens
    // to fit the pattern ("ORLD12345"). The older layout is looser, so it gets none: only exact matches.
    return changed <= (districtDigits == 2 ? 2 : 0) ? (text: out, changed: changed) : null;
  }

  // Both layouts can fit a string ("DL8SBT6438" is DL 8S BT 6438, or DL 85 BT 6438 after
  // turning S into 5): take the one that needs fewer repairs; on a tie, the common one.
  final a = tryLayout(2), b = tryLayout(1);
  if (a == null) return b?.text;
  if (b == null) return a.text;
  return b.changed < a.changed ? b.text : a.text;
}

const _states = {
  'AN', 'AP', 'AR', 'AS', 'BR', 'CG', 'CH', 'DD', 'DL', 'DN', 'GA', 'GJ', 'HP', 'HR', 'JH', 'JK', 'KA', 'KL',
  'LA', 'LD', 'MH', 'ML', 'MN', 'MP', 'MZ', 'NL', 'OD', 'OR', 'PB', 'PY', 'RJ', 'SK', 'TN', 'TR', 'TS', 'UK',
  'UP', 'WB',
};
bool _validState(String code) => _states.contains(code);

/// A plate in a format issued in India (standard or Bharat series, real state code).
bool isValidPlate(String t) => ((_std.hasMatch(t) || _old.hasMatch(t)) && _validState(t.substring(0, 2))) || _bh.hasMatch(t);

/// On-device OCR (Google ML Kit). The photo never leaves the phone; only the
/// recognised plate text is sent, and only if the user confirms it.
Future<List<String>> readPlates(File photo) async {
  final recogniser = TextRecognizer(script: TextRecognitionScript.latin);
  try {
    final result = await recogniser.processImage(InputImage.fromFile(photo));
    return extractPlates(result.text);
  } finally {
    await recogniser.close();
  }
}


/// What the pipeline found in a photo, best candidate first.
class PlateReading {
  const PlateReading(this.plates, this.boxes, {required this.usedDetector, this.fromOurReader = const {}});
  final List<String> plates;
  final List<PlateBox> boxes;

  /// False when the detector found nothing and the whole photo was read instead.
  final bool usedDetector;

  /// Which candidates came from our own reader (the rest are ML Kit's).
  final Set<String> fromOurReader;
}

/// Reads the plate(s) in a photo from three sources and merges them: our detector finds each
/// plate and then our own reader and ML Kit read the crop; ML Kit also reads the whole photo.
///
/// Order of the candidates: those that the crop reading and the whole-photo reading AGREE on
/// first (agreement is a strong signal), then the whole-photo reading, then the crop reads.
/// Measured on 44 real Indian phone photos (46 plates, labelled by hand, never trained on):
/// the old whole-photo ML Kit read found 22 plates with the right one first on 21 photos; this
/// finds 28 with the right one first on 25. Crop reads alone found 26 and were first on only 19:
/// good phone photos have big, clear plates where the whole-photo read is strong, and our
/// reader earns its place on small plates and busy scenes. (ml/README.md)
Future<PlateReading> readPlatesInPhoto(File photo) async {
  List<PlateBox> boxes = const [];
  final crops = <String>[];
  final ours = <String>{};
  try {
    final px = await Pixels.fromFile(photo);
    boxes = await (await PlateDetector.load()).detect(px);
    final dir = await getTemporaryDirectory();
    PlateRecognizer? reader;
    try {
      reader = await PlateRecognizer.load();
    } catch (_) {
      reader = null; // no model for this CPU: ML Kit alone
    }
    final recogniser = TextRecognizer(script: TextRecognitionScript.latin);
    try {
      for (var i = 0; i < boxes.length && i < 4; i++) {
        final mine = reader?.readBox(px, boxes[i]).text ?? '';
        final crop = File('${dir.path}/plate_crop_$i.png');
        await crop.writeAsBytes(await px.cropPng(boxes[i]));
        final theirs = extractPlates((await recogniser.processImage(InputImage.fromFile(crop))).text);
        // our reader's answer first when it is a valid plate, then ML Kit's read of the crop
        for (final p in [if (isValidPlate(mine)) mine, ...theirs]) {
          if (!crops.contains(p)) crops.add(p);
          if (p == mine) ours.add(p);
        }
      }
    } finally {
      await recogniser.close();
    }
  } catch (e) {
    boxes = const [];
  }
  final whole = await readPlates(photo);
  final both = crops.where(whole.contains).toList();
  final merged = [
    ...both,
    ...whole.where((p) => !both.contains(p)),
    ...crops.where((p) => !both.contains(p) && !whole.contains(p)),
  ];
  return PlateReading(merged, boxes, usedDetector: crops.isNotEmpty, fromOurReader: ours);
}
