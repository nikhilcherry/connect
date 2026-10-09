import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../services/acoustic_modem.dart';
import '../services/sound_link.dart';

/// Whether this phone's speaker and mic can carry the sound link, and the
/// two-phone test: one sends, the other listens.
class SoundCheckScreen extends StatefulWidget {
  const SoundCheckScreen({super.key});

  @override
  State<SoundCheckScreen> createState() => _SoundCheckScreenState();
}

class _SoundCheckScreenState extends State<SoundCheckScreen> {
  bool _ultra = true;
  bool _busy = false;
  String _log = 'Pick a profile, then Send on one phone and Listen on the other, '
      'or Loopback to test this phone alone.';
  double _level = 0;

  SoundLink get _link => SoundLink(AcousticModem(_ultra ? ModemProfile.ultrasonic : ModemProfile.audible));

  void _say(String s) {
    if (mounted) setState(() => _log = s);
  }

  Future<void> _run(Future<void> Function(SoundLink) job) async {
    if (_busy) return;
    setState(() => _busy = true);
    final link = _link;
    try {
      if (!await link.hasMic()) {
        _say('Microphone permission denied.');
        return;
      }
      await job(link);
    } catch (e) {
      _say('Error: $e');
    } finally {
      await link.dispose();
      if (mounted) setState(() => _busy = false);
    }
  }

  static const _word = 'CONNECT1';

  Future<void> _send() => _run((l) async {
        _say('Sending "$_word" as ${_ultra ? 'ultrasound' : 'audible tones'}…');
        await l.send(utf8.encode(_word));
        _say('Sent.');
      });

  Future<void> _listen({bool alsoSend = false}) => _run((l) async {
        _say(alsoSend ? 'Loopback: playing and listening on this phone…' : 'Listening…');
        final sub = l.listen().listen((e) {
          if (!mounted) return;
          setState(() => _level = e.level);
          if (e.payload != null) _say('Heard: "${utf8.decode(e.payload!, allowMalformed: true)}"');
        });
        if (alsoSend) {
          await Future.delayed(const Duration(milliseconds: 800));
          await l.send(utf8.encode(_word));
        }
        await sub.asFuture<void>();
        if (_log.startsWith('Loopback') || _log == 'Listening…') {
          _say('Nothing decoded. If the level bar moved, the mic hears something but not the signal.');
        }
      });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Sound check')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        SegmentedButton<bool>(
          segments: const [
            ButtonSegment(value: true, label: Text('Ultrasonic')),
            ButtonSegment(value: false, label: Text('Audible')),
          ],
          selected: {_ultra},
          onSelectionChanged: _busy ? null : (s) => setState(() => _ultra = s.first),
        ),
        const SizedBox(height: 16),
        Wrap(spacing: 8, runSpacing: 8, children: [
          FilledButton(onPressed: _busy ? null : _send, child: const Text('Send')),
          FilledButton(onPressed: _busy ? null : () => _listen(), child: const Text('Listen')),
          OutlinedButton(onPressed: _busy ? null : () => _listen(alsoSend: true), child: const Text('Loopback')),
        ]),
        const SizedBox(height: 16),
        LinearProgressIndicator(value: _level.clamp(0, 1)),
        const SizedBox(height: 16),
        Text(_log),
      ]),
    );
  }
}
