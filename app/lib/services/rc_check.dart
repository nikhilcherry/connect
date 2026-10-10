import 'dart:io';

import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

/// Does the text read off an RC photo carry this registration number?
/// OCR drops or swaps a character now and then, so one wrong character is
/// tolerated, but the match still has to sit in the text as a whole.
bool rcTextMatchesPlate(String ocrText, String plate) {
  final want = plate.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
  if (want.length < 6) return false;
  // Look at each line on its own too, so digits from two lines can't join up.
  for (final chunk in [ocrText, ...ocrText.split('\n')]) {
    final text = chunk.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
    if (text.contains(want)) return true;
    for (var i = 0; i + want.length <= text.length; i++) {
      var off = 0;
      for (var j = 0; j < want.length && off < 2; j++) {
        if (text.codeUnitAt(i + j) != want.codeUnitAt(j)) off++;
      }
      if (off < 2) return true;
    }
  }
  return false;
}

/// Reads the photo on the phone (nothing is uploaded) and says whether it
/// shows a registration certificate for [plate].
Future<bool> rcPhotoMatches(File photo, String plate) async {
  final recogniser = TextRecognizer(script: TextRecognitionScript.latin);
  try {
    final result = await recogniser.processImage(InputImage.fromFile(photo));
    return rcTextMatchesPlate(result.text, plate);
  } finally {
    await recogniser.close();
  }
}
