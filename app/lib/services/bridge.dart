import 'package:google_mlkit_language_id/google_mlkit_language_id.dart';
import 'package:google_mlkit_translation/google_mlkit_translation.dart';
import 'package:speech_to_text/speech_to_text.dart';

import '../l10n.dart';

/// The language bridge: each side reads the other in their own language, and
/// all of it runs on the phone. Language detection and translation are ML Kit
/// models (the language pack, about 30 MB, downloads once per language);
/// dictation uses the phone's own speech recogniser.

TranslateLanguage _target(AppLang l) => switch (l) {
      AppLang.en => TranslateLanguage.english,
      AppLang.hi => TranslateLanguage.hindi,
      AppLang.kn => TranslateLanguage.kannada,
      AppLang.ta => TranslateLanguage.tamil,
    };

/// Maps an ML Kit/BCP-47 code ("hi", "kn", "ta-Latn") to a language we can
/// translate, or null for anything else (including "und", undetermined).
TranslateLanguage? languageFromCode(String code) {
  final base = code.split('-').first.toLowerCase();
  return BCP47Code.fromRawValue(base);
}

/// What [translateTo] found: the text in [to], or the reason it didn't.
class Translated {
  const Translated(this.text, {required this.from, this.same = false});
  final String text;
  final String from;

  /// The message was already in the reader's language.
  final bool same;
}

Future<Translated?> translateTo(String text, AppLang to) async {
  final id = LanguageIdentifier(confidenceThreshold: 0.4);
  try {
    final code = await id.identifyLanguage(text);
    final from = languageFromCode(code);
    if (from == null) return null;
    if (from == _target(to)) return Translated(text, from: code, same: true);
    final manager = OnDeviceTranslatorModelManager();
    for (final l in [from, _target(to)]) {
      if (!await manager.isModelDownloaded(l.bcpCode)) await manager.downloadModel(l.bcpCode);
    }
    final translator = OnDeviceTranslator(sourceLanguage: from, targetLanguage: _target(to));
    try {
      return Translated(await translator.translateText(text), from: code);
    } finally {
      await translator.close();
    }
  } finally {
    await id.close();
  }
}

/// Dictation in the app's language, so the owner can reply by voice. Returns
/// the recogniser or null when the phone has none.
class Dictation {
  final _stt = SpeechToText();
  bool _ready = false;

  Future<bool> start(AppLang lang, void Function(String text, bool done) onText) async {
    _ready = _ready || await _stt.initialize();
    if (!_ready) return false;
    await _stt.listen(
      listenOptions: SpeechListenOptions(partialResults: true, localeId: '${lang.code}_IN'),
      onResult: (r) => onText(r.recognizedWords, r.finalResult),
    );
    return true;
  }

  Future<void> stop() => _stt.stop();
  bool get listening => _stt.isListening;
}
