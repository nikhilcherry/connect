import 'dart:math' as math;
import 'dart:typed_data';

/// Data-over-sound: 16-tone MFSK (4 bits a symbol), pure Dart so it can be
/// tested without a speaker. Two profiles share one codec:
///  - ultrasonic: inaudible to most adults, needs a phone speaker and mic
///    that reach that high (not all do);
///  - audible: ~1.5-4 kHz, the fallback every phone can play and hear.
///
/// Frame = preamble (6 symbols) + length + payload + CRC-16, nibble by nibble.
/// Payloads are short (a plate and a reason), so a frame is about 2 s.
///
/// 48 kHz is what phones play and record natively, so nothing is resampled
/// on the way out or in. Measured on an iQOO 15 with tool/sound_lab.dart.
class ModemProfile {
  final String name;
  final double baseHz;
  final double stepHz;
  final int sampleRate;
  final double symbolSeconds;
  const ModemProfile({
    required this.name,
    required this.baseHz,
    required this.stepHz,
    this.sampleRate = 48000,
    this.symbolSeconds = 0.06,
  });

  /// 18.0-19.7 kHz. On the iQOO 15 the speaker-to-mic path is flat from 17 to
  /// 19.25 kHz and falls away above 19.5 kHz; below 18 kHz younger ears hear it.
  static const ultrasonic = ModemProfile(name: 'ultrasonic', baseHz: 18000, stepHz: _step);
  static const audible = ModemProfile(name: 'audible', baseHz: 1500, stepHz: _step);

  /// Four cycles apart over the 36 ms a symbol is listened to, so each tone
  /// is exactly silent in every other tone's detector.
  static const _step = 1000 / 9;

  int get symbolSamples => (sampleRate * symbolSeconds).round();
  double toneHz(int i) => baseHz + stepHz * i;
}

/// A decoded frame and where it ended in the samples that were searched, so
/// a listener can drop what it has already read.
class ModemFrame {
  const ModemFrame(this.payload, this.end);
  final List<int> payload;
  final int end;
}

class AcousticModem {
  final ModemProfile profile;
  const AcousticModem(this.profile);

  static const _preamble = [0, 15, 0, 15, 7, 8];
  static const maxPayload = 16;

  /// CRC-16/CCITT-FALSE. Sixteen bits because a wrong frame here would send a
  /// stranger's phone to someone's car; eight let a false one through in tests
  /// with real recordings.
  static int crc16(List<int> data) {
    var c = 0xFFFF;
    for (final b in data) {
      c ^= b << 8;
      for (var i = 0; i < 8; i++) {
        c = (c & 0x8000) != 0 ? ((c << 1) ^ 0x1021) & 0xFFFF : (c << 1) & 0xFFFF;
      }
    }
    return c;
  }

  List<int> _symbols(List<int> payload) {
    final body = [payload.length, ...payload];
    final crc = crc16(body);
    final bytes = [...body, crc >> 8, crc & 0xFF];
    final out = [..._preamble];
    for (final b in bytes) {
      out
        ..add(b >> 4)
        ..add(b & 0x0F);
    }
    return out;
  }

  /// How long a frame carrying [payloadLength] bytes sounds for.
  Duration frameTime(int payloadLength) =>
      Duration(microseconds: ((_preamble.length + 2 * (payloadLength + 3) + 1) * profile.symbolSeconds * 1e6).round());

  /// PCM16 mono samples carrying [payload] (1 to [maxPayload] bytes).
  Int16List encode(List<int> payload, {double amplitude = 0.8}) {
    if (payload.isEmpty || payload.length > maxPayload) throw ArgumentError('payload must be 1 to $maxPayload bytes');
    final syms = _symbols(payload);
    final n = profile.symbolSamples;
    final out = Int16List(syms.length * n + n);
    final ramp = (n * 0.1).round();
    for (var s = 0; s < syms.length; s++) {
      final w = 2 * math.pi * profile.toneHz(syms[s]) / profile.sampleRate;
      for (var i = 0; i < n; i++) {
        // A raised-cosine fade at each end of a symbol: a hard switch between
        // tones clicks, and the click is audible even when the tones are not.
        final e = math.min(math.min(i, n - 1 - i), ramp) / ramp;
        final edge = 0.5 - 0.5 * math.cos(math.pi * e);
        out[s * n + i + n ~/ 2] = (math.sin(w * i) * edge * amplitude * 32767).round();
      }
    }
    return out;
  }

  /// Goertzel power of [hz] over [n] samples starting at [start].
  double _power(Int16List x, int start, int n, double hz) {
    final k = 2 * math.cos(2 * math.pi * hz / profile.sampleRate);
    var s1 = 0.0, s2 = 0.0;
    for (var i = 0; i < n; i++) {
      final s = x[start + i] / 32768.0 + k * s1 - s2;
      s2 = s1;
      s1 = s;
    }
    return s1 * s1 + s2 * s2 - k * s1 * s2;
  }

  /// Strongest tone in a symbol window, or -1 when nothing stands out.
  int _symbolAt(Int16List x, int start, {double minRatio = 4}) {
    final n = profile.symbolSamples;
    // The middle 60% of the window avoids the neighbours' fades.
    final a = start + (n * 0.2).round();
    final w = (n * 0.6).round();
    if (a + w > x.length) return -1;
    var best = -1;
    var bestP = 0.0, sum = 0.0;
    for (var t = 0; t < 16; t++) {
      final p = _power(x, a, w, profile.toneHz(t));
      sum += p;
      if (p > bestP) {
        bestP = p;
        best = t;
      }
    }
    final rest = (sum - bestP) / 15;
    if (bestP < 1e-6 || bestP < rest * minRatio) return -1;
    return best;
  }

  /// The payload of the first valid frame found in [samples], or null.
  List<int>? decode(Int16List samples) => find(samples)?.payload;

  /// First valid frame found in [samples], or null. Scans in 1/8-symbol steps.
  ModemFrame? find(Int16List samples) {
    final n = profile.symbolSamples;
    final step = math.max(1, n ~/ 8);
    final last = samples.length - n * (_preamble.length + 8);
    for (var s = 0; s <= last; s += step) {
      if (_symbolAt(samples, s) != _preamble[0]) continue;
      var ok = true;
      for (var i = 1; i < _preamble.length && ok; i++) {
        ok = _symbolAt(samples, s + i * n) == _preamble[i];
      }
      if (!ok) continue;
      final frame = _readFrame(samples, s + _preamble.length * n);
      if (frame != null) return frame;
    }
    return null;
  }

  ModemFrame? _readFrame(Int16List x, int at) {
    final n = profile.symbolSamples;
    int? byteAt(int i) {
      final hi = _symbolAt(x, at + (2 * i) * n, minRatio: 2);
      final lo = _symbolAt(x, at + (2 * i + 1) * n, minRatio: 2);
      if (hi < 0 || lo < 0) return null;
      return (hi << 4) | lo;
    }

    final len = byteAt(0);
    if (len == null || len == 0 || len > maxPayload) return null;
    final body = <int>[len];
    for (var i = 1; i <= len; i++) {
      final b = byteAt(i);
      if (b == null) return null;
      body.add(b);
    }
    final hi = byteAt(len + 1), lo = byteAt(len + 2);
    if (hi == null || lo == null || ((hi << 8) | lo) != crc16(body)) return null;
    return ModemFrame(body.sublist(1), at + 2 * (len + 3) * n);
  }
}
