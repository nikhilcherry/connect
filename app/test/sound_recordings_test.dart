import 'dart:io';
import 'dart:typed_data';

import 'package:connect/data/models.dart';
import 'package:connect/l10n.dart';
import 'package:connect/services/acoustic_modem.dart';
import 'package:connect/services/whisper.dart';
import 'package:flutter_test/flutter_test.dart';

/// Real sound, not synthesised: an iQOO 15 played these frames on its own
/// speaker and a laptop's microphone on the same desk recorded them
/// (tool/sound_lab.dart, 9 Oct 2026). They keep the modem honest about
/// speakers, rooms and microphones, which the other tests cannot.
Int16List _recording(String name) {
  final d = ByteData.sublistView(File('test/fixtures/$name').readAsBytesSync());
  expect(d.getUint32(24, Endian.little), 48000);
  return Int16List.fromList([for (var i = 44; i + 1 < d.lengthInBytes; i += 2) d.getInt16(i, Endian.little)]);
}

void main() {
  const ultrasonic = AcousticModem(ModemProfile.ultrasonic), audible = AcousticModem(ModemProfile.audible);
  const sent = Whisper(plate: 'KA01AB1234', kind: AlertKind.lightsOn, nonce: 0xBEEF, lang: AppLang.kn);

  test('an alert sent as ultrasound by a phone is read from another device\'s microphone', () {
    final pcm = _recording('iqoo15_to_laptop_whisper_ultrasonic.wav');
    expect(Whisper.decode(ultrasonic.decode(pcm)!), sent);
    expect(audible.decode(pcm), isNull);
  });

  test('and still read when played a hundred times weaker', () {
    final pcm = _recording('iqoo15_to_laptop_whisper_ultrasonic_40db_down.wav');
    expect(Whisper.decode(ultrasonic.decode(pcm)!), sent);
  });

  test('the answer comes back on audible tones', () {
    final ack = WhisperAck.decode(audible.decode(_recording('iqoo15_to_laptop_ack_audible_20db_down.wav'))!)!;
    expect(ack.nonce, sent.nonce);
    expect(ack.owner, isTrue);
  });
}
