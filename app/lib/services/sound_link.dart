import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:record/record.dart';

import 'acoustic_modem.dart';

/// A frame the microphone heard, and the profile that carried it.
class HeardFrame {
  const HeardFrame(this.payload, this.profile);
  final List<int> payload;
  final ModemProfile profile;
}

/// How loud the microphone is right now, 0..1: overall, and inside each
/// profile's band, so the screen can show which kind of sound is arriving.
class SoundLevel {
  const SoundLevel(this.peak, this.ultrasonic, this.audible);
  final double peak, ultrasonic, audible;
  static const silent = SoundLevel(0, 0, 0);
}

/// Speaker and microphone glue for [AcousticModem]. One open microphone
/// decodes both profiles as sound arrives; the speaker answers on either.
///
/// Three things here were found on a real phone, not in tests:
///  - the recorder is told not to pause on an audio-focus change, or it stops
///    the moment this phone's own player starts;
///  - the player asks for no audio focus, for the same reason and so a short
///    chirp does not stop someone's music;
///  - the microphone is opened unprocessed, because voice processing is built
///    to remove steady tones like these.
class SoundLink {
  SoundLink({this.hearSelf = false});

  /// Report this phone's own frames too. Only the self-test wants that.
  final bool hearSelf;

  static const profiles = [ModemProfile.ultrasonic, ModemProfile.audible];
  static const sampleRate = 48000;

  /// The longest frame is about 2.5 s; five seconds always holds one whole.
  static const _window = sampleRate * 5;

  final _player = AudioPlayer();
  final _rec = AudioRecorder();
  final _frames = StreamController<HeardFrame>.broadcast();
  final _levels = StreamController<SoundLevel>.broadcast();

  /// Every valid frame heard, except echoes of what this phone just sent.
  Stream<HeardFrame> get frames => _frames.stream;
  Stream<SoundLevel> get levels => _levels.stream;

  bool get listening => _sub != null;

  StreamSubscription<Uint8List>? _sub;
  final _buf = Int16List(_window * 2);
  int _len = 0; // samples held in _buf
  int _total = 0; // samples heard since listening began
  int _lastTry = 0;
  bool _decoding = false;
  int? _carry; // odd byte left over from the last chunk
  final _read = {for (final p in profiles) p.name: 0}; // per profile, how far frames were read (absolute)
  final _sent = <(List<int>, DateTime)>[];

  Future<bool> hasMic() => _rec.hasPermission();

  /// Opens the microphone. Safe to call twice.
  Future<void> listen() async {
    if (_sub != null) return;
    _len = 0;
    _total = 0;
    _lastTry = 0;
    _carry = null;
    _read.updateAll((_, _) => 0);
    Stream<Uint8List> stream;
    try {
      stream = await _rec.startStream(_config(AndroidAudioSource.unprocessed));
    } catch (e) {
      // Not every phone offers the unprocessed source.
      debugPrint('unprocessed mic refused ($e); using the default source');
      stream = await _rec.startStream(_config(AndroidAudioSource.defaultSource));
    }
    _sub = stream.listen(_onChunk, onError: (Object e) => debugPrint('mic stream: $e'));
  }

  RecordConfig _config(AndroidAudioSource source) => RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: sampleRate,
        numChannels: 1,
        autoGain: false,
        echoCancel: false,
        noiseSuppress: false,
        audioInterruption: AudioInterruptionMode.none,
        androidConfig: AndroidRecordConfig(audioSource: source),
      );

  Future<void> stopListening() async {
    final sub = _sub;
    _sub = null;
    await sub?.cancel();
    try {
      await _rec.stop();
    } catch (e) {
      debugPrint('mic stop: $e');
    }
    if (!_levels.isClosed) _levels.add(SoundLevel.silent);
  }

  void _onChunk(Uint8List chunk) {
    // PCM16 little-endian; a chunk may end half-way through a sample.
    var bytes = chunk;
    if (_carry != null) {
      bytes = Uint8List(chunk.length + 1)
        ..[0] = _carry!
        ..setRange(1, chunk.length + 1, chunk);
      _carry = null;
    }
    if (bytes.length.isOdd) _carry = bytes[bytes.length - 1];
    final n = bytes.length ~/ 2;
    if (n == 0) return;
    if (_len + n > _buf.length) {
      // Keep the newest window at the front and carry on appending after it.
      final keep = math.min(_len, _window);
      _buf.setRange(0, keep, _buf, _len - keep);
      _len = keep;
    }
    final view = ByteData.sublistView(bytes);
    var peak = 0;
    for (var i = 0; i < n; i++) {
      final s = view.getInt16(i * 2, Endian.little);
      _buf[_len + i] = s;
      if (s.abs() > peak) peak = s.abs();
    }
    _len += n;
    _total += n;
    _levels.add(SoundLevel(peak / 32768, _band(ModemProfile.ultrasonic, n), _band(ModemProfile.audible, n)));
    if (!_decoding && _total - _lastTry >= sampleRate ~/ 3 && _len >= sampleRate) _decode();
  }

  /// Loudness of a profile's band over the newest samples, 0..1 on a dB scale
  /// (-80 dB and below is 0, -20 dB and above is 1).
  double _band(ModemProfile p, int newest) {
    final n = math.min(math.min(newest, 1024), _len);
    if (n < 256) return 0;
    final start = _len - n;
    var sum = 0.0;
    for (final t in const [1, 6, 10, 14]) {
      final k = 2 * math.cos(2 * math.pi * p.toneHz(t) / sampleRate);
      var s1 = 0.0, s2 = 0.0;
      for (var i = 0; i < n; i++) {
        final s = _buf[start + i] / 32768.0 + k * s1 - s2;
        s2 = s1;
        s1 = s;
      }
      sum += (s1 * s1 + s2 * s2 - k * s1 * s2) / (n * n / 4);
    }
    final db = 10 * math.log(sum / 4 + 1e-12) / math.ln10;
    return ((db + 80) / 60).clamp(0.0, 1.0);
  }

  Future<void> _decode() async {
    _decoding = true;
    _lastTry = _total;
    try {
      final held = math.min(_len, _window);
      final snapshot = Int16List.fromList(Int16List.sublistView(_buf, _len - held, _len));
      final origin = _total - held; // absolute index of snapshot[0]
      // Off the UI thread: a pass costs tens of milliseconds, three times a second.
      final found = await compute(_findAll, (snapshot, [for (final p in profiles) math.max(0, _read[p.name]! - origin)]));
      for (var i = 0; i < profiles.length; i++) {
        for (final f in found[i]) {
          _read[profiles[i].name] = origin + f.end;
          if ((hearSelf || !_isEcho(f.payload)) && !_frames.isClosed) _frames.add(HeardFrame(f.payload, profiles[i]));
        }
      }
    } catch (e) {
      debugPrint('decode pass failed: $e');
    } finally {
      _decoding = false;
    }
  }

  /// Every frame of each profile in [args].$1, starting from that profile's offset.
  static List<List<ModemFrame>> _findAll((Int16List, List<int>) args) {
    final (samples, starts) = args;
    return [
      for (var i = 0; i < profiles.length; i++) _framesFrom(AcousticModem(profiles[i]), samples, starts[i]),
    ];
  }

  static List<ModemFrame> _framesFrom(AcousticModem modem, Int16List samples, int start) {
    final out = <ModemFrame>[];
    var at = start;
    while (at < samples.length) {
      final f = modem.find(Int16List.sublistView(samples, at));
      if (f == null) break;
      out.add(ModemFrame(f.payload, at + f.end));
      at += f.end;
    }
    return out;
  }

  /// This phone hears itself: what it sent in the last few seconds is not news.
  bool _isEcho(List<int> payload) {
    final now = DateTime.now();
    _sent.removeWhere((s) => now.difference(s.$2).inSeconds > 8);
    return _sent.any((s) => listEquals(s.$1, payload));
  }

  /// Plays [payload] on [profile] and returns when the sound has finished.
  Future<void> send(List<int> payload, ModemProfile profile) async {
    final modem = AcousticModem(profile);
    final pcm = modem.encode(payload);
    _sent.add((List.of(payload), DateTime.now()));
    // Ultrasound is sent at full volume; nobody hears it. The audible tones are loud enough lower.
    final borrowed = await MediaVolume.borrow(profile == ModemProfile.ultrasonic ? 1.0 : 0.7);
    try {
      await _player.setAudioContext(AudioContext(android: const AudioContextAndroid(audioFocus: AndroidAudioFocus.none)));
      await _player.setVolume(1.0);
      await _player.play(BytesSource(wav(pcm, profile.sampleRate), mimeType: 'audio/wav'));
      await Future<void>.delayed(Duration(milliseconds: 1000 * pcm.length ~/ profile.sampleRate + 250));
    } finally {
      await MediaVolume.restore(borrowed);
    }
  }

  static Uint8List wav(Int16List pcm, int sampleRate) {
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
    b.setUint16(20, 1, Endian.little); // PCM
    b.setUint16(22, 1, Endian.little); // mono
    b.setUint32(24, sampleRate, Endian.little);
    b.setUint32(28, sampleRate * 2, Endian.little);
    b.setUint16(32, 2, Endian.little);
    b.setUint16(34, 16, Endian.little);
    tag(36, 'data');
    b.setUint32(40, pcm.length * 2, Endian.little);
    for (var i = 0; i < pcm.length; i++) {
      b.setInt16(44 + i * 2, pcm[i], Endian.little);
    }
    return b.buffer.asUint8List();
  }

  Future<void> dispose() async {
    await stopListening();
    await _frames.close();
    await _levels.close();
    await _player.dispose();
    await _rec.dispose();
  }
}

/// The phone's media volume, which decides how far a sent frame carries. A
/// send borrows it at full and hands it back; with headphones or a speaker
/// attached it is left alone. Only Android answers; elsewhere this does nothing.
class MediaVolume {
  static const _channel = MethodChannel('connect/audio');

  /// Raises the media volume to [fraction] of full for a send; returns what
  /// to pass to [restore], or null when nothing was changed.
  static Future<int?> borrow([double fraction = 1.0]) async {
    try {
      return await _channel.invokeMethod<int>('borrowVolume', fraction);
    } on MissingPluginException {
      return null;
    } catch (e) {
      debugPrint('volume: $e');
      return null;
    }
  }

  static Future<void> restore(int? previous) async {
    if (previous == null) return;
    try {
      await _channel.invokeMethod<void>('restoreVolume', previous);
    } catch (e) {
      debugPrint('volume: $e');
    }
  }
}
