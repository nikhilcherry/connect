import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../l10n.dart';
import '../services/acoustic_modem.dart';
import '../services/sound_link.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/motion.dart';

enum _Result { untested, testing, heard, silent }

/// Whether this phone's speaker and microphone can carry the sound link:
/// it plays a frame on each band and listens for its own voice. A phone that
/// hears itself can be heard by a phone beside it; one that cannot reach
/// ultrasound still has the audible tones.
class SoundCheckScreen extends StatefulWidget {
  const SoundCheckScreen({super.key});

  @override
  State<SoundCheckScreen> createState() => _SoundCheckScreenState();
}

class _SoundCheckScreenState extends State<SoundCheckScreen> {
  final _link = SoundLink(hearSelf: true);
  final _results = {for (final p in SoundLink.profiles) p.name: _Result.untested};
  bool _busy = false;
  String? _error;

  static const _probe = [0x43, 0x4F, 0x4E, 0x4E]; // "CONN"

  @override
  void dispose() {
    _link.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    setState(() {
      _busy = true;
      _error = null;
      _results.updateAll((_, _) => _Result.untested);
    });
    try {
      if (!await _link.hasMic()) {
        setState(() => _error = tr('Allow the microphone so this phone can hear others.'));
        return;
      }
      await _link.listen();
      for (final p in SoundLink.profiles) {
        if (!mounted) return;
        setState(() => _results[p.name] = _Result.testing);
        final heard = _link.frames.firstWhere((f) => f.profile == p && listEquals(f.payload, _probe));
        await _link.send(_probe, p);
        final ok = await heard.then((_) => true).timeout(const Duration(seconds: 3), onTimeout: () => false);
        if (!mounted) return;
        setState(() => _results[p.name] = ok ? _Result.heard : _Result.silent);
      }
    } catch (e) {
      debugPrint('sound check failed: $e');
      if (mounted) setState(() => _error = tr('The test could not run on this phone.'));
    } finally {
      await _link.stopListening();
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    Widget row(ModemProfile p, IconData icon, String title, String subtitle) {
      final r = _results[p.name]!;
      return InfoRow(
        icon: icon,
        tone: r == _Result.heard ? Tone.success : (r == _Result.silent ? Tone.error : null),
        title: title,
        subtitle: subtitle,
        trailing: switch (r) {
          _Result.untested => StatusBadge(tr('Not tested'), tone: Tone.neutral),
          _Result.testing => const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
          _Result.heard => StatusBadge(tr('Works'), tone: Tone.success),
          _Result.silent => StatusBadge(tr('Not heard'), tone: Tone.error),
        },
      );
    }

    return Scaffold(
      appBar: AppBar(title: Text(tr('Test this phone'))),
      body: SafeArea(
        child: ListView(padding: const EdgeInsets.fromLTRB(20, 8, 20, 32), children: revealAll([
          ScreenTitle(tr('Can this phone talk by sound?'), eyebrow: tr('On-device')),
          const SizedBox(height: 8),
          Text(
            tr('The phone plays a short message on each band and listens for its own voice. The volume is turned up for the two seconds it takes and put back.'),
            style: DLText.body.copyWith(color: DL.muted),
          ),
          const SizedBox(height: 20),
          row(ModemProfile.ultrasonic, Icons.hearing_disabled_outlined, tr('Silent band'), tr('18 to 19.7 kHz, above most adults\' hearing')),
          const SizedBox(height: 8),
          row(ModemProfile.audible, Icons.graphic_eq, tr('Audible band'), tr('1.5 to 3.2 kHz, short chirps anyone can hear')),
          if (_error != null) ...[const SizedBox(height: 12), Text(_error!, style: DLText.body.copyWith(color: DL.error))],
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: _busy ? null : _run,
            icon: const Icon(Icons.play_arrow_outlined),
            label: Text(_busy ? tr('Testing…') : tr('Run the test')),
          ),
          const SizedBox(height: 16),
          FootNote(tr('Unplug headphones first: the sound has to come out of the phone\'s own speaker.'), icon: Icons.info_outline),
        ])),
      ),
    );
  }
}
