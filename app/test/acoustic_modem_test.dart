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
  for (final profile in const [ModemProfile.ultrasonic, ModemProfile.audible]) {
    group(profile.name, () {
      final modem = AcousticModem(profile);
      final n = profile.symbolSamples;

      test('round-trips a payload at an odd offset', () {
        final payload = [0xC0, 0xFF, 0xEE, 0x12, 0x34, 0x56, 0x78, 0x9A];
        final pcm = _padded(modem.encode(payload), 7013, 5000, 0, 1);
        expect(modem.decode(pcm), payload);
      });

      test('carries the longest payload and the shortest', () {
        final long = List.generate(AcousticModem.maxPayload, (i) => i * 17 & 0xFF);
        expect(modem.decode(_padded(modem.encode(long), 900, 900, 0, 4)), long);
        expect(modem.decode(_padded(modem.encode([0]), 900, 900, 0, 5)), [0]);
        expect(() => modem.encode([]), throwsArgumentError);
        expect(() => modem.encode(List.filled(AcousticModem.maxPayload + 1, 1)), throwsArgumentError);
      });

      test('survives noise at about a third of the signal', () {
        final payload = [1, 2, 3, 4, 5];
        final pcm = _padded(modem.encode(payload, amplitude: 0.6), 3001, 4000, 0.2, 2);
        expect(modem.decode(pcm), payload);
      });

      test('still reads a frame a thousand times quieter than full scale', () {
        // Across a room the tones arrive tens of decibels down; only their ratio to the noise matters.
        final payload = [7, 7, 7];
        final pcm = _padded(modem.encode(payload, amplitude: 0.001), 2000, 2000, 0.0001, 6);
        expect(modem.decode(pcm), payload);
      });

      test('returns null for silence and for pure noise', () {
        expect(modem.decode(Int16List(profile.sampleRate * 3)), isNull);
        expect(modem.decode(_padded(Int16List(0), profile.sampleRate * 3, 0, 0.3, 3)), isNull);
      });

      test('a frame with a hole in it is dropped, not misread', () {
        final pcm = modem.encode([9, 9, 9, 9]);
        // Wipe the payload's second byte: tones vanish, frame is dropped.
        for (var i = n * 9; i < n * 11; i++) {
          pcm[i + n ~/ 2] = 0;
        }
        expect(modem.decode(pcm), isNull);
      });

      test('one wrong tone fails the checksum', () {
        // Symbols 8 and 9 are the first payload byte. Splice in the same symbols of a frame
        // that differs only there: every tone is clean, only the checksum can tell.
        final good = modem.encode([0x11, 0x22, 0x33]);
        final other = modem.encode([0x1F, 0x22, 0x33]);
        final spliced = Int16List.fromList(good);
        for (var i = n * 8 + n ~/ 2; i < n * 10 + n ~/ 2; i++) {
          spliced[i] = other[i];
        }
        expect(modem.decode(good), [0x11, 0x22, 0x33]);
        expect(modem.decode(spliced), isNull);
      });

      test('says where a frame ended, so the next one in the same recording is found', () {
        final a = modem.encode([1, 2, 3]), b = modem.encode([4, 5, 6, 7]);
        final both = Int16List(a.length + 4000 + b.length)
          ..setAll(0, a)
          ..setAll(a.length + 4000, b);
        final first = modem.find(both)!;
        expect(first.payload, [1, 2, 3]);
        expect(first.end, inInclusiveRange(a.length - n, a.length));
        final second = modem.find(Int16List.sublistView(both, first.end))!;
        expect(second.payload, [4, 5, 6, 7]);
        expect(modem.find(Int16List.sublistView(both, first.end + second.end)), isNull);
      });

      test('a frame lasts as long as it says', () {
        final pcm = modem.encode(List.filled(12, 0x5A));
        expect(modem.frameTime(12).inMilliseconds, closeTo(pcm.length * 1000 / profile.sampleRate, 1));
        expect(modem.frameTime(12).inMilliseconds, lessThan(2400));
      });
    });
  }

  test('the two profiles do not hear each other', () {
    final u = const AcousticModem(ModemProfile.ultrasonic), a = const AcousticModem(ModemProfile.audible);
    expect(a.decode(u.encode([1, 2, 3])), isNull);
    expect(u.decode(a.encode([1, 2, 3])), isNull);
  });

  test('the checksum is CRC-16/CCITT-FALSE', () {
    expect(AcousticModem.crc16('123456789'.codeUnits), 0x29B1);
  });
}
