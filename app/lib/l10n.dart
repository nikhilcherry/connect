import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// App languages. The scan page (web/index.html) offers the same four.
enum AppLang {
  en('en', 'English'),
  hi('hi', 'हिन्दी'),
  kn('kn', 'ಕನ್ನಡ'),
  ta('ta', 'தமிழ்');

  const AppLang(this.code, this.native);
  final String code;

  /// The language's name in its own script, as shown in the picker.
  final String native;

  Locale get locale => Locale(code, 'IN');
}

/// Strings are keyed by their English text, so code reads naturally and a
/// missing translation falls back to English rather than to a key. Values
/// use `{name}` placeholders. Translations live in assets/l10n/<code>.json;
/// test/l10n_test.dart checks every tr() call in lib/ has one in each file.
class L10n {
  static final lang = ValueNotifier<AppLang>(AppLang.en);
  static Map<String, String> _table = const {};
  static const _pref = 'app_lang';

  static Future<void> load() async {
    AppLang l = AppLang.en;
    try {
      final saved = (await SharedPreferences.getInstance()).getString(_pref);
      l = AppLang.values.firstWhere((x) => x.code == saved, orElse: () => AppLang.en);
    } catch (_) {}
    await _apply(l);
  }

  static Future<void> set(AppLang l) async {
    await _apply(l);
    try {
      await (await SharedPreferences.getInstance()).setString(_pref, l.code);
    } catch (_) {}
    // Strings are resolved at build time, so rebuild everything in place:
    // routes, scroll positions and form state all survive.
    void mark(Element e) {
      e.markNeedsBuild();
      e.visitChildren(mark);
    }

    WidgetsBinding.instance.rootElement?.visitChildren(mark);
  }

  static Future<void> _apply(AppLang l) async {
    Map<String, String> table = const {};
    if (l != AppLang.en) {
      try {
        final raw = await rootBundle.loadString('assets/l10n/${l.code}.json');
        table = (jsonDecode(raw) as Map<String, dynamic>).cast<String, String>();
      } catch (e) {
        debugPrint('l10n ${l.code} failed to load: $e');
      }
    }
    await initializeDateFormatting(l.code);
    Intl.defaultLocale = l.code;
    _table = table;
    lang.value = l;
  }

  @visibleForTesting
  static void useTable(Map<String, String> t) => _table = t;
}

/// Translates [en] into the current language, filling `{name}` placeholders.
String tr(String en, [Map<String, Object?> args = const {}]) {
  var s = L10n._table[en];
  if (s == null || s.isEmpty) s = en;
  if (args.isEmpty) return s;
  return s.replaceAllMapped(RegExp(r'\{(\w+)\}'), (m) => args.containsKey(m[1]) ? '${args[m[1]]}' : m[0]!);
}
