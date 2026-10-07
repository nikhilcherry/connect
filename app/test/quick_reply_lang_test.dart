import 'package:connect/data/models.dart';
import 'package:connect/l10n.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(() {
    L10n.useTableFor(AppLang.kn, {'Coming in 2 minutes': '2 ನಿಮಿಷದಲ್ಲಿ ಬರುತ್ತೇನೆ'});
  });

  test('a quick reply is written in the stranger\'s language, not the owner\'s', () {
    L10n.useTable(const {'Coming in 2 minutes': '2 मिनट में आ रहा हूँ'}); // owner reads Hindi
    expect(trIn('Coming in 2 minutes', AppLang.kn), '2 ನಿಮಿಷದಲ್ಲಿ ಬರುತ್ತೇನೆ');
    expect(tr('Coming in 2 minutes'), '2 मिनट में आ रहा हूँ');
  });

  test('English and missing entries fall back to the English text', () {
    expect(trIn('Coming in 2 minutes', AppLang.en), 'Coming in 2 minutes');
    expect(trIn('Moving it now, sorry!', AppLang.kn), 'Moving it now, sorry!');
  });

  test('the alert carries the stranger\'s language, defaulting to English', () {
    Map<String, dynamic> row(String? lang) => {
          'id': 'a', 'vehicle_id': 'v', 'kind': 'other', 'status': 'open', 'blocked': false,
          'created_at': '2026-10-07T10:00:00Z', 'updated_at': '2026-10-07T10:00:00Z', 'scanner_lang': lang,
        };
    expect(CarAlert.fromJson(row('ta')).scannerLang, AppLang.ta);
    expect(CarAlert.fromJson(row(null)).scannerLang, AppLang.en);
    expect(CarAlert.fromJson(row('zz')).scannerLang, AppLang.en);
  });

  test('an alert knows when the owner first saw it', () {
    Map<String, dynamic> row(String? seen) => {
          'id': 'a', 'vehicle_id': 'v', 'kind': 'other', 'status': 'open', 'blocked': false,
          'created_at': '2026-10-07T10:00:00Z', 'updated_at': '2026-10-07T10:00:00Z', 'seen_at': seen,
        };
    expect(CarAlert.fromJson(row(null)).seenAt, isNull);
    expect(CarAlert.fromJson(row('2026-10-07T10:01:00Z')).seenAt, isNotNull);
  });
}
