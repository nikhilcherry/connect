import 'dart:async';
import 'dart:typed_data';


import 'package:audioplayers/audioplayers.dart';
import 'package:record/record.dart';

import 'acoustic_modem.dart';

/// Speaker and microphone glue for [AcousticModem]: play a frame, or listen
/// until one decodes. Echo cancelling, noise suppression and auto gain are
/// off because they are built to remove exactly this kind of signal.
class SoundLink {
  final AcousticModem modem;
  SoundLink(this.modem);

  final _player = AudioPlayer();
  final _rec = AudioRecorder();

  static Uint8List wav(Int16List pcm, int sampleRate) {
    final data = pcm.buffer.asUint8List(pcm.offsetInBytes, pcm.lengthInBytes);
    final b = ByteData(44);
    void tag(int at, String s) {
      for (var i = 0; i < 4; i++) {
        b.setUint8(at + i, s.codeUnitAt(i));
      }
    }

    tag(0, 'RIFF');
    b.setUint32(4, 36 + data.length, Endian.little);
    tag(8, 'WAVE');
    tag(12, 'fmt ');
    b.setUint32(16, 16, Endian.little);
    b.setUint16(20, 1, Endian.little); // PCM
    b.setUint16(22, 1, Endian.little); // mono
    b.setUint32(24, sampleRate, Endian.little);
    b.setUint32(28, sampleRate * 2, Endian.little);
    b.setUint16(32, 2, Endian.little);
    b.setUint16(34, 16, Endian.little);
    tag(36, 'data');
    b.setUint32(40, data.length, Endian.little);
    return Uint8List.fromList([...b.buffer.asUint8List(), ...data]);
  }

  Future<bool> hasMic() => _rec.hasPermission();

  /// Plays [payload] and returns when the sound has finished.
  Future<void> send(List<int> payload) async {
    final pcm = modem.encode(payload);
    await _player.setVolume(1.0);
    await _player.play(BytesSource(wav(pcm, modem.profile.sampleRate), mimeType: 'audio/wav'));
    await Future.delayed(Duration(milliseconds: 1000 * pcm.length ~/ modem.profile.sampleRate + 300));
  }

  /// Result of [listen]: the payload if one decoded, plus how loud the band was.
  Stream<ListenEvent> listen({Duration maxFor = const Duration(seconds: 12)}) async* {
    final p = modem.profile;
    final stream = await _rec.startStream(RecordConfig(
      encoder: AudioEncoder.pcm16bits,
      sampleRate: p.sampleRate,
      numChannels: 1,
      autoGain: false,
      echoCancel: false,
      noiseSuppress: false,
    ));
    // Keep the last ~4 s; a frame is under 2 s, so one always fits whole.
    final window = p.sampleRate * 4;
    var ring = Int16List(0);
    final stop = DateTime.now().add(maxFor);
    var lastTry = 0;
    try {
      await for (final chunk in stream) {
        final got = Int16List.view(Uint8List.fromList(chunk).buffer);
        final merged = Int16List(ring.length + got.length)
          ..setAll(0, ring)
          ..setAll(ring.length, got);
        ring = merged.length > window ? Int16List.sublistView(merged, merged.length - window) : merged;
        var peak = 0;
        for (final s in got) {
          if (s.abs() > peak) peak = s.abs();
        }
        yield ListenEvent(null, peak / 32768);
        if (ring.length - lastTry >= p.sampleRate ~/ 2 && ring.length > p.sampleRate) {
          lastTry = ring.length;
          final r = modem.decode(ring);
          if (r != null) {
            yield ListenEvent(r, peak / 32768);
            return;
          }
        }
        if (DateTime.now().isAfter(stop)) return;
      }
    } finally {
      await _rec.stop();
    }
  }

  Future<void> dispose() async {
    await _player.dispose();
    await _rec.dispose();
  }
}

class ListenEvent {
  final List<int>? payload;
  final double level;
  const ListenEvent(this.payload, this.level);
}
