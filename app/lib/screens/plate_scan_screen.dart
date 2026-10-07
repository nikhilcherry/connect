import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config.dart';
import '../l10n.dart';
import '../main.dart';
import '../services/plate_reader.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/motion.dart';

enum _Phase { idle, reading, ready, searching, notFound }

/// "The plate is the QR": photograph any number plate, read it on the phone,
/// and if that car is on Connect open the same masked chat a sticker scan
/// would. No sticker needed, and the answer is only "a Connect car exists".
class PlateScanScreen extends StatefulWidget {
  const PlateScanScreen({super.key});

  @override
  State<PlateScanScreen> createState() => _PlateScanScreenState();
}

class _PlateScanScreenState extends State<PlateScanScreen> {
  final _plate = TextEditingController();
  _Phase _phase = _Phase.idle;
  List<String> _candidates = const [];
  String? _error;

  @override
  void dispose() {
    _plate.dispose();
    super.dispose();
  }

  Future<void> _capture() async {
    final shot = await ImagePicker().pickImage(source: ImageSource.camera, maxWidth: 1600, imageQuality: 85);
    if (shot == null || !mounted) return;
    setState(() {
      _phase = _Phase.reading;
      _error = null;
    });
    try {
      final plates = await readPlates(File(shot.path));
      if (!mounted) return;
      setState(() {
        _candidates = plates;
        if (plates.isNotEmpty) _plate.text = plates.first;
        _phase = _Phase.ready;
        if (plates.isEmpty) _error = tr('No number plate found in that photo. Try again closer, or type it below.');
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _phase = _Phase.ready;
          _error = tr('Couldn\'t read that photo. Type the plate below.');
        });
      }
    }
  }

  Future<void> _find() async {
    final plate = _plate.text.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
    if (plate.length < 6) {
      setState(() => _error = tr('Enter the full number plate.'));
      return;
    }
    setState(() {
      _phase = _Phase.searching;
      _error = null;
    });
    try {
      final code = await AppScope.read(context).findTagByPlate(plate);
      if (!mounted) return;
      if (code == null) {
        setState(() => _phase = _Phase.notFound);
        return;
      }
      setState(() => _phase = _Phase.ready);
      await launchUrl(Uri.parse(Config.tagUrl(code)), mode: LaunchMode.externalApplication);
    } catch (e) {
      if (mounted) {
        setState(() => _phase = _Phase.ready);
        showError(context, e);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final busy = _phase == _Phase.reading || _phase == _Phase.searching;
    return Scaffold(
      appBar: AppBar(title: Text(tr('Reach a car by its plate'))),
      body: SafeArea(
        child: ListView(padding: const EdgeInsets.fromLTRB(20, 8, 20, 32), children: revealAll([
          ScreenTitle(tr('Plate is the QR'), eyebrow: tr('On-device')),
          const SizedBox(height: 8),
          Text(
            tr('Blocked in by a car with no sticker? Photograph its number plate. If the owner is on Connect, you can message them without either side sharing a number.'),
            style: DLText.body.copyWith(color: DL.muted),
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: busy ? null : _capture,
            icon: const Icon(Icons.photo_camera_outlined),
            label: Text(_phase == _Phase.reading ? tr('Reading…') : tr('Photograph the plate')),
          ),
          const SizedBox(height: 24),
          FieldLabel(tr('Number plate')),
          TextField(
            controller: _plate,
            textCapitalization: TextCapitalization.characters,
            maxLength: 13,
            onChanged: (_) => setState(() => _error = null),
            decoration: InputDecoration(hintText: tr('e.g. KA01AB1234'), errorText: _error),
          ),
          if (_candidates.length > 1) ...[
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final c in _candidates.take(4))
                ActionChip(label: Text(c), onPressed: () => setState(() => _plate.text = c)),
            ]),
            const SizedBox(height: 16),
          ],
          FilledButton(
            onPressed: busy ? null : _find,
            child: Text(_phase == _Phase.searching ? tr('Looking…') : tr('Find this car on Connect')),
          ),
          if (_phase == _Phase.notFound) ...[
            const SizedBox(height: 16),
            SectionCard(
              child: Text(
                tr('That car isn\'t on Connect yet. Nothing was sent and nobody was told.'),
                style: DLText.body,
              ),
            ),
          ],
          const SizedBox(height: 24),
          FootNote(tr('The photo is read on this phone and never uploaded. Only the plate text is checked, and Connect only ever answers whether that car is on Connect.')),
        ])),
      ),
    );
  }
}
