import 'dart:math' as math;
import 'dart:typed_data';

import 'package:connect/services/acoustic_modem.dart';
import 'package:flutter_test/flutter_test.dart';

Int16List _padded(Int16List frame, int before, int after, double noise, int seed) {
  final r = math.Random(seed);
  final out = Int16List(before + frame.length + after);
  for (var i = 0; i < out.length; i++) {
    out[i] = ((r.nextDouble() * 2 - 1) * noise * 32767).round();
  }
  for (var i = 0; i < frame.length; i++) {
    out[before + i] = (out[before + i] + frame[i]).clamp(-32768, 32767);
  }
  return out;
}

void main() {
  for (final entry in {
    'ultrasonic': ModemProfile.ultrasonic,
    'audible': ModemProfile.audible,
  }.entries) {
    group(entry.key, () {
      final modem = AcousticModem(entry.value);

      test('round-trips a payload at an odd offset', () {
        final payload = [0xC0, 0xFF, 0xEE, 0x12, 0x34, 0x56, 0x78, 0x9A];
        final pcm = _padded(modem.encode(payload), 7013, 5000, 0, 1);
        expect(modem.decode(pcm), payload);
      });

      test('survives noise at about a third of the signal', () {
        final payload = [1, 2, 3, 4, 5];
        final pcm = _padded(modem.encode(payload, amplitude: 0.6), 3001, 4000, 0.2, 2);
        expect(modem.decode(pcm), payload);
      });

      test('returns null for silence and for pure noise', () {
        expect(modem.decode(Int16List(44100 * 3)), isNull);
        expect(modem.decode(_padded(Int16List(0), 44100 * 3, 0, 0.3, 3)), isNull);
      });

      test('a corrupted frame fails the checksum instead of misreading', () {
        final pcm = modem.encode([9, 9, 9, 9]);
        final n = entry.value.symbolSamples;
        // Wipe the payload's second byte: tones vanish, frame is dropped.
        for (var i = n * 9; i < n * 11; i++) {
          pcm[i + n ~/ 2] = 0;
        }
        expect(modem.decode(pcm), isNull);
      });
    });
  }
}
