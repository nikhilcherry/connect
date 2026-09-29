import 'dart:convert';
import 'dart:io';

import 'package:connect/l10n.dart';
import 'package:flutter_test/flutter_test.dart';

/// Every string passed to tr() (or marked /*t*/ for enums) in lib/.
Set<String> _keysInCode() {
  final pattern = RegExp(r"(?:\btr\(\s*|/\*t\*/)'((?:[^'\\]|\\.)*)'");
  final keys = <String>{};
  for (final f in Directory('lib').listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart'))) {
    for (final m in pattern.allMatches(f.readAsStringSync())) {
      keys.add(m[1]!.replaceAll(r"\'", "'").replaceAll(r'\\', r'\'));
    }
  }
  return keys;
}

Set<String> _placeholders(String s) => RegExp(r'\{\w+\}').allMatches(s).map((m) => m[0]!).toSet();

void main() {
  final keys = _keysInCode();

  test('strings are translatable literals, not interpolated', () {
    expect(keys, isNotEmpty);
    expect(keys.where((k) => k.contains(r'$')), isEmpty, reason: r'use {placeholders} inside tr(), not $interpolation');
  });

  for (final lang in AppLang.values.where((l) => l != AppLang.en)) {
    group(lang.name, () {
      final table = (jsonDecode(File('assets/l10n/${lang.code}.json').readAsStringSync()) as Map).cast<String, String>();

      test('every string in the app has a translation', () {
        expect(keys.difference(table.keys.toSet()), isEmpty);
      });

      test('no stale translations', () {
        expect(table.keys.toSet().difference(keys), isEmpty);
      });

      test('placeholders survive translation', () {
        for (final MapEntry(:key, :value) in table.entries) {
          expect(_placeholders(value), _placeholders(key), reason: '"$key" -> "$value"');
          expect(value.trim(), isNotEmpty, reason: key);
        }
      });
    });
  }

  test('tr fills placeholders and falls back to English', () {
    L10n.useTable({'{n} min ago': '{n} मिनट पहले'});
    expect(tr('{n} min ago', {'n': 5}), '5 मिनट पहले');
    expect(tr('Not translated {x}', {'x': 1}), 'Not translated 1');
    L10n.useTable({});
  });
}
