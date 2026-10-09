import 'dart:math' as math;
import 'dart:typed_data';

/// Data-over-sound: 16-tone MFSK (4 bits a symbol), pure Dart so it can be
/// tested without a speaker. Two profiles share one codec:
///  - ultrasonic: ~17.6-20 kHz, inaudible to most adults, needs a phone
///    speaker and mic that reach that high (not all do);
///  - audible: ~1.5-4 kHz, the demo-safe fallback.
///
/// Frame = preamble (6 symbols) + length + payload + CRC-8, nibble by nibble.
/// Payloads are short (a challenge or a tag code), so a frame is ~2 s.
class ModemProfile {
  final double baseHz;
  final double stepHz;
  final int sampleRate;
  final double symbolSeconds;
  const ModemProfile({
    required this.baseHz,
    required this.stepHz,
    this.sampleRate = 44100,
    this.symbolSeconds = 0.06,
  });

  static const ultrasonic = ModemProfile(baseHz: 17600, stepHz: 160);
  static const audible = ModemProfile(baseHz: 1500, stepHz: 160);

  int get symbolSamples => (sampleRate * symbolSeconds).round();
  double toneHz(int i) => baseHz + stepHz * i;
}

class AcousticModem {
  final ModemProfile profile;
  const AcousticModem(this.profile);

  static const _preamble = [0, 15, 0, 15, 7, 8];
  static const maxPayload = 16;

  static int crc8(List<int> data) {
    var c = 0;
    for (final b in data) {
      c ^= b;
      for (var i = 0; i < 8; i++) {
        c = (c & 0x80) != 0 ? ((c << 1) ^ 0x07) & 0xFF : (c << 1) & 0xFF;
      }
    }
    return c;
  }

  List<int> _symbols(List<int> payload) {
    final body = [payload.length, ...payload];
    final bytes = [...body, crc8(body)];
    final out = [..._preamble];
    for (final b in bytes) {
      out
        ..add(b >> 4)
        ..add(b & 0x0F);
    }
    return out;
  }

  /// PCM16 mono samples carrying [payload] (at most [maxPayload] bytes).
  Int16List encode(List<int> payload, {double amplitude = 0.8}) {
    assert(payload.length <= maxPayload);
    final syms = _symbols(payload);
    final n = profile.symbolSamples;
    final out = Int16List(syms.length * n + n);
    final ramp = (n * 0.08).round();
    for (var s = 0; s < syms.length; s++) {
      final w = 2 * math.pi * profile.toneHz(syms[s]) / profile.sampleRate;
      for (var i = 0; i < n; i++) {
        // Short fade in/out of each symbol so the tone changes don't click.
        final edge = math.min(math.min(i, n - 1 - i), ramp) / ramp;
        out[s * n + i + n ~/ 2] =
            (math.sin(w * i) * edge * amplitude * 32767).round();
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

  /// First valid frame found in [samples], or null. Scans in 1/8-symbol steps.
  List<int>? decode(Int16List samples) {
    final n = profile.symbolSamples;
    final step = math.max(1, n ~/ 8);
    final last = samples.length - n * (_preamble.length + 4);
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

  List<int>? _readFrame(Int16List x, int at) {
    final n = profile.symbolSamples;
    int? byteAt(int i) {
      final hi = _symbolAt(x, at + (2 * i) * n, minRatio: 2);
      final lo = _symbolAt(x, at + (2 * i + 1) * n, minRatio: 2);
      if (hi < 0 || lo < 0) return null;
      return (hi << 4) | lo;
    }

    final len = byteAt(0);
    if (len == null || len > maxPayload) return null;
    final body = <int>[len];
    for (var i = 1; i <= len; i++) {
      final b = byteAt(i);
      if (b == null) return null;
      body.add(b);
    }
    final c = byteAt(len + 1);
    if (c == null || c != crc8(body)) return null;
    return body.sublist(1);
  }
}
