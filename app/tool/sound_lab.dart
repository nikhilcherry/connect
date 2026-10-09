// Hardware lab for the sound link. Never shipped: it is its own entrypoint,
// built under another application id so it installs beside the real app and
// leaves that app's account alone.
//
//   CONNECT_ID_SUFFIX=.lab flutter build apk --profile --target-platform android-arm64 -t tool/sound_lab.dart
//   adb install -g -r build/app/outputs/flutter-apk/app-profile.apk
//   adb push jobs.json some.wav /sdcard/Android/data/app.connectcar.connect.lab/files/
//   adb shell am start -S -n app.connectcar.connect.lab/app.connectcar.connect.MainActivity
//
// Each job in jobs.json records the microphone while (optionally) playing a
// WAV on the speaker, and saves the recording as rec_<id>.wav for
// tool/modem_wav.dart to decode:
//   [{"id": "u1", "play": "u1.wav", "seconds": 4, "rate": 48000, "source": "unprocessed"}]
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:connect/services/sound_link.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MaterialApp(home: _Lab()));
}

class _Lab extends StatefulWidget {
  const _Lab();

  @override
  State<_Lab> createState() => _LabState();
}

class _LabState extends State<_Lab> {
  final _lines = <String>[];

  void _say(String s) {
    // ignore: avoid_print
    print('LAB $s');
    if (mounted) setState(() => _lines.add(s));
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _run().catchError((Object e) => _say('FAILED $e')));
  }

  Future<void> _run() async {
    final dir = (await getExternalStorageDirectory())!;
    _say('dir ${dir.path}');
    final rec = AudioRecorder();
    if (!await rec.hasPermission()) {
      _say('FAILED no microphone permission');
      return;
    }
    final jobsFile = File('${dir.path}/jobs.json');
    if (!jobsFile.existsSync()) {
      _say('FAILED no jobs.json');
      return;
    }
    final jobs = (jsonDecode(await jobsFile.readAsString()) as List).cast<Map<String, dynamic>>();
    for (final j in jobs) {
      final id = j['id'] as String;
      final rate = j['rate'] as int? ?? 48000;
      final source = AndroidAudioSource.values.firstWhere((s) => s.name == (j['source'] ?? 'unprocessed'));
      final bytes = BytesBuilder(copy: false);
      final stream = await rec.startStream(RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: rate,
        numChannels: 1,
        autoGain: false,
        echoCancel: false,
        noiseSuppress: false,
        // Without this the recorder pauses the moment the player asks for audio focus.
        audioInterruption: (j['interruption'] as String?) == 'pause' ? AudioInterruptionMode.pause : AudioInterruptionMode.none,
        androidConfig: AndroidRecordConfig(audioSource: source),
      ));
      final sub = stream.listen(bytes.add);
      _say('start $id');
      await Future<void>.delayed(Duration(milliseconds: j['delayMs'] as int? ?? 500));
      final player = AudioPlayer();
      final play = j['play'] as String?;
      if (play != null) {
        if (j['focus'] != 'gain') {
          await player.setAudioContext(AudioContext(android: const AudioContextAndroid(audioFocus: AndroidAudioFocus.none)));
        }
        await player.setVolume((j['volume'] as num?)?.toDouble() ?? 1.0);
        await player.play(DeviceFileSource('${dir.path}/$play'));
      }
      await Future<void>.delayed(Duration(milliseconds: ((j['seconds'] as num) * 1000).round()));
      await rec.stop();
      await sub.cancel();
      await player.dispose();
      final raw = bytes.takeBytes();
      final pcm = Int16List.view(Uint8List.fromList(raw).buffer, 0, raw.length ~/ 2);
      await File('${dir.path}/rec_$id.wav').writeAsBytes(SoundLink.wav(pcm, rate));
      _say('done $id ${pcm.length} samples');
    }
    await rec.dispose();
    _say('ALL DONE');
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Sound lab')),
        body: ListView(padding: const EdgeInsets.all(16), children: [for (final l in _lines) Text(l)]),
      );
}
