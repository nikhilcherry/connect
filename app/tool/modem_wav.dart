// The sound link's modem on WAV files, for checking it against real
// recordings without a phone in the loop (see tool/sound_lab.dart).
//
//   dart run tool/modem_wav.dart encode ultrasonic 434f4e4e45435431 out.wav
//   dart run tool/modem_wav.dart decode ultrasonic rec.wav
import 'dart:io';
import 'dart:typed_data';

import 'package:connect/services/acoustic_modem.dart';

const _profiles = {'ultrasonic': ModemProfile.ultrasonic, 'audible': ModemProfile.audible};

Uint8List _wav(Int16List pcm, int rate) {
  final b = ByteData(44 + pcm.length * 2);
  void tag(int at, String s) {
    for (var i = 0; i < 4; i++) {
      b.setUint8(at + i, s.codeUnitAt(i));
    }
  }

  tag(0, 'RIFF');
  b.setUint32(4, 36 + pcm.length * 2, Endian.little);
  tag(8, 'WAVE');
  tag(12, 'fmt ');
  b.setUint32(16, 16, Endian.little);
  b.setUint16(20, 1, Endian.little);
  b.setUint16(22, 1, Endian.little);
  b.setUint32(24, rate, Endian.little);
  b.setUint32(28, rate * 2, Endian.little);
  b.setUint16(32, 2, Endian.little);
  b.setUint16(34, 16, Endian.little);
  tag(36, 'data');
  b.setUint32(40, pcm.length * 2, Endian.little);
  for (var i = 0; i < pcm.length; i++) {
    b.setInt16(44 + i * 2, pcm[i], Endian.little);
  }
  return b.buffer.asUint8List();
}

/// Mono PCM16 samples and the sample rate of a WAV file (first channel only).
({Int16List pcm, int rate}) _read(String path) {
  final d = ByteData.sublistView(File(path).readAsBytesSync());
  var at = 12, rate = 0, channels = 1;
  while (at + 8 <= d.lengthInBytes) {
    final id = String.fromCharCodes([for (var i = 0; i < 4; i++) d.getUint8(at + i)]);
    final size = d.getUint32(at + 4, Endian.little);
    if (id == 'fmt ') {
      channels = d.getUint16(at + 10, Endian.little);
      rate = d.getUint32(at + 12, Endian.little);
    } else if (id == 'data') {
      final n = (size.clamp(0, d.lengthInBytes - at - 8)) ~/ (2 * channels);
      final pcm = Int16List(n);
      for (var i = 0; i < n; i++) {
        pcm[i] = d.getInt16(at + 8 + i * 2 * channels, Endian.little);
      }
      return (pcm: pcm, rate: rate);
    }
    at += 8 + size + (size & 1);
  }
  throw const FormatException('no data chunk');
}

String _hex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

void main(List<String> args) {
  if (args.length < 3 || !_profiles.containsKey(args[1])) {
    stderr.writeln('usage: modem_wav.dart encode|decode ultrasonic|audible <hex payload> <out.wav> | <in.wav>');
    exit(64);
  }
  final modem = AcousticModem(_profiles[args[1]]!);
  if (args[0] == 'encode') {
    final hex = args[2];
    final payload = [for (var i = 0; i < hex.length; i += 2) int.parse(hex.substring(i, i + 2), radix: 16)];
    File(args[3]).writeAsBytesSync(_wav(modem.encode(payload), modem.profile.sampleRate));
  } else {
    final w = _read(args[2]);
    if (w.rate != modem.profile.sampleRate) {
      stderr.writeln('recorded at ${w.rate} Hz, the profile wants ${modem.profile.sampleRate} Hz');
      exit(65);
    }
    // Every frame in the recording, with the time each one ended.
    var at = 0, found = 0;
    while (true) {
      final f = modem.find(Int16List.sublistView(w.pcm, at));
      if (f == null) break;
      at += f.end;
      found++;
      stdout.writeln('decoded ${_hex(f.payload)} ending at ${(at / w.rate).toStringAsFixed(2)} s');
    }
    if (found == 0) stdout.writeln('nothing decoded');
    exit(found == 0 ? 1 : 0);
  }
}
