import 'package:connect/services/bridge.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_mlkit_translation/google_mlkit_translation.dart';

void main() {
  test('detected codes map to translatable languages', () {
    expect(languageFromCode('hi'), TranslateLanguage.hindi);
    expect(languageFromCode('kn'), TranslateLanguage.kannada);
    expect(languageFromCode('ta-Latn'), TranslateLanguage.tamil);
    expect(languageFromCode('en'), TranslateLanguage.english);
  });

  test('undetermined or unknown codes are not translatable', () {
    expect(languageFromCode('und'), isNull);
    expect(languageFromCode('xx'), isNull);
  });
}
