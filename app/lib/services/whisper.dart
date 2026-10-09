import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/models.dart';
import '../l10n.dart';

/// What one phone tells another by sound when neither has a signal: which
/// car, and what is wrong with it. Twelve bytes for a ten-character plate, so
/// it fits one two-second frame of the sound link (acoustic_modem.dart).
///
///   byte 0     0x11: an alert, format version 1
///   byte 1     language (high nibble), reason (low nibble)
///   byte 2-3   a random number, to tell repeats of one message from a new one
///   byte 4-    the plate, six bits a character
///
/// The plate is what anyone standing at the car can read, so nothing private
/// travels through the air.
class Whisper {
  const Whisper({required this.plate, required this.kind, required this.nonce, this.lang = AppLang.en});

  /// Letters and digits only, 6 to 11 of them.
  final String plate;
  final AlertKind kind;
  final int nonce;

  /// The sender's language, so the owner's quick replies can go out in it.
  final AppLang lang;

  static const _head = 0x11;
  static const _kinds = [AlertKind.blocking, AlertKind.lightsOn, AlertKind.towing, AlertKind.windowOpen, AlertKind.accident, AlertKind.other];
  static const _langs = [AppLang.en, AppLang.hi, AppLang.kn, AppLang.ta];
  static final _plate = RegExp(r'^[A-Z0-9]{6,11}$');

  static bool validPlate(String s) => _plate.hasMatch(s);

  List<int> encode() {
    assert(validPlate(plate));
    return [_head, (_langs.indexOf(lang) << 4) | _kinds.indexOf(kind), (nonce >> 8) & 0xFF, nonce & 0xFF, ...packPlate(plate)];
  }

  /// Null for anything that is not a well-formed alert: another kind of
  /// frame, a later version, or noise that happened to pass the checksum.
  static Whisper? decode(List<int> b) {
    if (b.length < 9 || b[0] != _head) return null;
    final kind = b[1] & 0x0F, lang = b[1] >> 4;
    if (kind >= _kinds.length || lang >= _langs.length) return null;
    final plate = unpackPlate(b.sublist(4));
    if (plate == null || !validPlate(plate)) return null;
    return Whisper(plate: plate, kind: _kinds[kind], nonce: (b[2] << 8) | b[3], lang: _langs[lang]);
  }

  /// The same for every phone that heard this message on the same day, so the
  /// server lets it in once however many of them deliver it.
  String ref(DateTime heardAt) {
    final d = heardAt.toUtc();
    String two(int n) => n.toString().padLeft(2, '0');
    return 'snd-${d.year}${two(d.month)}${two(d.day)}-${_kinds.indexOf(kind)}-${nonce.toRadixString(16).padLeft(4, '0')}';
  }

  /// The reason as the server spells it.
  String get kindWire => const ['blocking', 'lights_on', 'towing', 'window_open', 'accident', 'other'][_kinds.indexOf(kind)];

  @override
  bool operator ==(Object other) => other is Whisper && other.plate == plate && other.kind == kind && other.nonce == nonce && other.lang == lang;

  @override
  int get hashCode => Object.hash(plate, kind, nonce, lang);
}

/// The answer a listening phone sends back, so the sender knows somebody
/// heard: four bytes, a frame of about a second.
class WhisperAck {
  const WhisperAck(this.nonce, {required this.owner});
  final int nonce;

  /// True when the phone that heard it belongs to the car's owner or family;
  /// false when it is a passer-by who will carry the message out.
  final bool owner;

  static const _head = 0x21;

  List<int> encode() => [_head, (nonce >> 8) & 0xFF, nonce & 0xFF, owner ? 1 : 2];

  static WhisperAck? decode(List<int> b) {
    if (b.length != 4 || b[0] != _head || (b[3] != 1 && b[3] != 2)) return null;
    return WhisperAck((b[1] << 8) | b[2], owner: b[3] == 1);
  }
}

/// Six bits a character: 0 pads the end, 1-10 are the digits, 11-36 the letters.
@visibleForTesting
List<int> packPlate(String plate) {
  final out = <int>[];
  var acc = 0, bits = 0;
  for (final c in plate.codeUnits) {
    acc = (acc << 6) | (c <= 0x39 ? c - 0x30 + 1 : c - 0x41 + 11);
    bits += 6;
    while (bits >= 8) {
      bits -= 8;
      out.add((acc >> bits) & 0xFF);
    }
    acc &= (1 << bits) - 1;
  }
  if (bits > 0) out.add((acc << (8 - bits)) & 0xFF);
  return out;
}

@visibleForTesting
String? unpackPlate(List<int> bytes) {
  final s = StringBuffer();
  var acc = 0, bits = 0, ended = false;
  for (final b in bytes) {
    acc = (acc << 8) | b;
    bits += 8;
    while (bits >= 6) {
      bits -= 6;
      final v = (acc >> bits) & 0x3F;
      acc &= (1 << bits) - 1;
      if (v == 0) {
        ended = true;
      } else if (ended || v > 36) {
        return null;
      } else {
        s.writeCharCode(v <= 10 ? 0x30 + v - 1 : 0x41 + v - 11);
      }
    }
  }
  return s.toString();
}

/// Where a message this phone holds has got to.
enum WhisperState { carrying, delivered, unknownCar }

/// What handing a message to the server came to.
enum Delivery { delivered, unknownCar, later }

/// A message this phone heard by sound, or sent itself, and is taking to the
/// server for the car's owner.
class HeardWhisper {
  HeardWhisper(this.whisper, this.at, {required this.mine, this.own = false, this.state = WhisperState.carrying});
  final Whisper whisper;
  final DateTime at;

  /// It is about one of this phone's own cars.
  final bool mine;

  /// This phone sent it (and keeps it to deliver once it has a signal again).
  final bool own;
  WhisperState state;

  Map<String, dynamic> toJson() => {
        'b': base64Encode(whisper.encode()),
        'at': at.toUtc().toIso8601String(),
        'mine': mine,
        'own': own,
        'state': state.name,
      };

  static HeardWhisper? fromJson(Map<String, dynamic> j) {
    final w = Whisper.decode(base64Decode(j['b'] as String));
    if (w == null) return null;
    return HeardWhisper(
      w,
      DateTime.parse(j['at'] as String).toLocal(),
      mine: j['mine'] as bool? ?? false,
      own: j['own'] as bool? ?? false,
      state: WhisperState.values.firstWhere((s) => s.name == j['state'], orElse: () => WhisperState.carrying),
    );
  }
}

/// The messages this phone is carrying, kept on the phone until they are
/// delivered. Newest first.
class WhisperStore {
  static final heard = ValueNotifier<List<HeardWhisper>>(const []);
  static const _key = 'whispers_heard';
  static const _keep = 30;
  static bool _flushing = false;

  static Future<void> load() async {
    try {
      final raw = (await SharedPreferences.getInstance()).getString(_key);
      if (raw == null) return;
      final week = DateTime.now().subtract(const Duration(days: 7));
      heard.value = [
        for (final j in jsonDecode(raw) as List) ?HeardWhisper.fromJson(j as Map<String, dynamic>),
      ].where((h) => h.at.isAfter(week)).toList();
    } catch (e) {
      debugPrint('whispers unreadable: $e');
    }
  }

  static Future<void> _save() async {
    try {
      await (await SharedPreferences.getInstance()).setString(_key, jsonEncode([for (final h in heard.value) h.toJson()]));
    } catch (e) {
      debugPrint('whispers not saved: $e');
    }
  }

  /// Keeps [w]. False when this phone already holds it: a sender repeats
  /// itself until somebody answers, and that must not count twice.
  static Future<bool> add(Whisper w, {required bool mine, bool own = false, DateTime? now}) async {
    final at = now ?? DateTime.now();
    final again = heard.value.any((h) => h.whisper == w && at.difference(h.at).inHours.abs() < 12);
    if (again) return false;
    heard.value = [HeardWhisper(w, at, mine: mine, own: own), ...heard.value].take(_keep).toList();
    await _save();
    return true;
  }

  /// Hands every message still being carried to [deliver], oldest first, and
  /// stops at the first one that has to wait (no signal yet).
  static Future<void> flush(Future<Delivery> Function(HeardWhisper) deliver) async {
    if (_flushing) return;
    _flushing = true;
    try {
      for (final h in heard.value.reversed.where((h) => h.state == WhisperState.carrying).toList()) {
        final r = await deliver(h);
        if (r == Delivery.later) break;
        h.state = r == Delivery.delivered ? WhisperState.delivered : WhisperState.unknownCar;
        heard.value = List.of(heard.value);
        await _save();
      }
    } finally {
      _flushing = false;
    }
  }

  @visibleForTesting
  static void reset() => heard.value = const [];
}
