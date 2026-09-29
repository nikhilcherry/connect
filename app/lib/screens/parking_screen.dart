import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n.dart';
import '../main.dart';
import '../theme.dart';
import '../services/parking.dart';
import '../widgets/common.dart';

/// Home card: the saved spot at a glance, or a nudge to save one.
class ParkingCard extends StatelessWidget {
  const ParkingCard({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ParkingSpot?>(
      valueListenable: ParkingStore.spot,
      builder: (context, spot, _) {
        final details = [
          if (spot?.note?.isNotEmpty == true) spot!.note!,
          if (spot?.meterEndsAt != null) tr('paid until {time}', {'time': DateFormat.jm().format(spot!.meterEndsAt!)}),
        ].join(' · ');
        return SectionCard(
          onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ParkingScreen())),
          child: Row(children: [
            IconBadge(Icons.local_parking_outlined, tone: spot == null ? null : Tone.info),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(spot == null ? tr('Where did I park?') : tr('Parked {ago}', {'ago': timeAgo(spot.savedAt)}), style: DLText.strong),
                const SizedBox(height: 2),
                Text(
                  spot == null ? tr('Save your spot so you can walk straight back.') : (details.isEmpty ? tr('Spot saved') : details),
                  style: DLText.small,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ]),
            ),
            if (spot?.hasLocation == true)
              IconButton.filled(
                tooltip: tr('Walk back'),
                style: IconButton.styleFrom(backgroundColor: DL.violet, foregroundColor: DL.onDark),
                icon: const Icon(Icons.directions_walk),
                onPressed: () => _navigate(context, spot!),
              )
            else
              const Icon(Icons.chevron_right, color: DL.muted),
          ]),
        );
      },
    );
  }
}

Future<void> _navigate(BuildContext context, ParkingSpot spot) async {
  if (!await launchUrl(spot.directionsUrl, mode: LaunchMode.externalApplication) && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('Couldn\'t open maps.'))));
  }
}

class ParkingScreen extends StatelessWidget {
  const ParkingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ParkingSpot?>(
      valueListenable: ParkingStore.spot,
      builder: (context, spot, _) => Scaffold(
        appBar: AppBar(title: Text(tr('Parking'))),
        body: SafeArea(child: spot == null ? const _SaveSpotForm() : _SavedSpot(spot: spot)),
      ),
    );
  }
}

class _SavedSpot extends StatelessWidget {
  const _SavedSpot({required this.spot});
  final ParkingSpot spot;

  @override
  Widget build(BuildContext context) {
    final ends = spot.meterEndsAt;
    return ListView(padding: const EdgeInsets.fromLTRB(20, 8, 20, 32), children: [
      ScreenTitle(tr('Parked {ago}', {'ago': timeAgo(spot.savedAt)}), eyebrow: DateFormat('EEE d MMM, h:mm a').format(spot.savedAt)),
      const SizedBox(height: 24),
      if (spot.photoPath != null && !kIsWeb) ...[
        ClipRRect(
          borderRadius: BorderRadius.circular(DL.rCard),
          child: Image.file(File(spot.photoPath!), height: 220, fit: BoxFit.cover, errorBuilder: (_, _, _) => const SizedBox.shrink()),
        ),
        const SizedBox(height: 12),
      ],
      if (spot.note?.isNotEmpty == true) ...[
        SectionCard(
          child: Row(children: [
            const Icon(Icons.sticky_note_2_outlined, color: DL.muted),
            const SizedBox(width: 12),
            Expanded(child: Text(spot.note!, style: DLText.section)),
          ]),
        ),
        const SizedBox(height: 12),
      ],
      if (ends != null) ...[_MeterRow(ends: ends), const SizedBox(height: 12)],
      const SizedBox(height: 12),
      if (spot.hasLocation) ...[
        FilledButton.icon(
          icon: const Icon(Icons.directions_walk),
          label: Text(tr('Walk back to my car')),
          onPressed: () => _navigate(context, spot),
        ),
        if ((spot.accuracyM ?? 0) > 50)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Text(tr('GPS was weak when you saved this (about {n} m), so check your note too.', {'n': spot.accuracyM!.round()}),
                style: DLText.small, textAlign: TextAlign.center),
          ),
      ] else
        Text(tr('No location was saved: location was off or not allowed.'), style: DLText.small, textAlign: TextAlign.center),
      const SizedBox(height: 12),
      OutlinedButton(onPressed: ParkingStore.clear, child: Text(tr('I\'m back at the car'))),
      const SizedBox(height: 20),
      Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        const Icon(Icons.lock_outline, size: 16, color: DL.muted),
        const SizedBox(width: 6),
        Flexible(child: Text(tr('Your parking spot stays on this phone. Connect never receives it.'), style: DLText.small)),
      ]),
    ]);
  }
}

class _MeterRow extends StatelessWidget {
  const _MeterRow({required this.ends});
  final DateTime ends;

  @override
  Widget build(BuildContext context) {
    final left = ends.difference(DateTime.now());
    final over = left.isNegative;
    // Running out of paid parking is this screen's one urgency, so it may use amber.
    final soon = !over && left.inMinutes <= 15;
    return SectionCard(
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Label(over ? tr('Parking ran out') : tr('Paid until {time}', {'time': DateFormat.jm().format(ends)})),
            const SizedBox(height: 8),
            Text(over ? DateFormat.jm().format(ends) : formatDuration(left),
                style: DLText.numeral.copyWith(color: over ? DL.error : DL.ink)),
          ]),
        ),
        if (over)
          StatusBadge(tr('Expired'), tone: Tone.error)
        else if (soon)
          StatusBadge(tr('Ending soon'), tone: Tone.warning)
        else
          StatusBadge(tr('Time left'), tone: Tone.neutral),
      ]),
    );
  }
}

String formatDuration(Duration d) => d.inHours > 0 ? tr('{h} h {m} min', {'h': d.inHours, 'm': d.inMinutes % 60}) : tr('{m} min', {'m': d.inMinutes});

/// Today at [t], or tomorrow if that time has already passed.
DateTime nextOccurrence(TimeOfDay t, {DateTime? now}) {
  final n = now ?? DateTime.now();
  final at = DateTime(n.year, n.month, n.day, t.hour, t.minute);
  return at.isBefore(n) ? at.add(const Duration(days: 1)) : at;
}

class _SaveSpotForm extends StatefulWidget {
  const _SaveSpotForm();
  @override
  State<_SaveSpotForm> createState() => _SaveSpotFormState();
}

class _SaveSpotFormState extends State<_SaveSpotForm> {
  final _note = TextEditingController();
  String? _photo;
  DateTime? _meterEnds;
  bool _shareBackBy = true;
  bool _saving = false;
  bool _saved = false;

  @override
  void dispose() {
    // A photo taken for a spot that was never saved would otherwise be orphaned.
    if (!_saved && _photo != null && !kIsWeb) File(_photo!).delete().then((_) {}, onError: (_) {});
    _note.dispose();
    super.dispose();
  }

  Future<void> _pickMeter(Duration? d) async {
    if (d != null) {
      setState(() => _meterEnds = DateTime.now().add(d));
      return;
    }
    final picked = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(DateTime.now().add(const Duration(hours: 1))));
    if (picked != null) setState(() => _meterEnds = nextOccurrence(picked));
  }

  Future<void> _takePhoto() async {
    try {
      final path = await ParkingStore.takePhoto();
      if (path == null) return;
      if (_photo != null) File(_photo!).delete().then((_) {}, onError: (_) {});
      setState(() => _photo = path);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final s = AppScope.read(context);
    final messenger = ScaffoldMessenger.of(context);
    final pos = await ParkingStore.locate();
    _saved = true;
    await ParkingStore.save(ParkingSpot(
      savedAt: DateTime.now(),
      lat: pos?.latitude,
      lng: pos?.longitude,
      accuracyM: pos?.accuracy,
      note: _note.text.trim().isEmpty ? null : _note.text.trim(),
      photoPath: _photo,
      meterEndsAt: _meterEnds,
    ));
    if (_meterEnds != null && _shareBackBy) {
      try {
        await s.setAway(_meterEnds!, null);
      } catch (e) {
        debugPrint('setAway failed: $e');
        messenger.showSnackBar(SnackBar(content: Text(tr('Spot saved, but "back by" couldn\'t be updated. Check your internet.'))));
        return;
      }
    }
    if (pos == null) {
      messenger.showSnackBar(
        SnackBar(content: Text(tr('Saved without location. Turn on location to get walking directions next time.'))),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final chips = <(String, Duration?)>[
      (tr('30 min'), const Duration(minutes: 30)),
      (tr('1 hour'), const Duration(hours: 1)),
      (tr('2 hours'), const Duration(hours: 2)),
      (tr('Pick time'), null),
    ];
    return ListView(padding: const EdgeInsets.fromLTRB(20, 8, 20, 32), children: [
      ScreenTitle(tr('Save where you parked')),
      const SizedBox(height: 8),
      Text(tr('We\'ll save your location right now. Add a note for malls and basements, where GPS is weak.'),
          style: DLText.body.copyWith(color: DL.muted)),
      const SizedBox(height: 24),
      FieldLabel(tr('Note (optional)')),
      TextField(
        controller: _note,
        maxLength: 80,
        textCapitalization: TextCapitalization.sentences,
        decoration: InputDecoration(hintText: tr('e.g. B2, pillar 14, near lift C')),
      ),
      if (!kIsWeb) ...[
        if (_photo != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: ClipRRect(borderRadius: BorderRadius.circular(DL.rCard), child: Image.file(File(_photo!), height: 160, fit: BoxFit.cover)),
          ),
        OutlinedButton.icon(
          icon: const Icon(Icons.photo_camera_outlined),
          label: Text(_photo == null ? tr('Add a photo of the spot') : tr('Retake photo')),
          onPressed: _saving ? null : _takePhoto,
        ),
      ],
      const SizedBox(height: 24),
      Label(tr('Paid parking? Remind me before it runs out')),
      const SizedBox(height: 10),
      Wrap(spacing: 8, runSpacing: 8, children: [
        for (final (label, d) in chips) ActionChip(label: Text(label), onPressed: () => _pickMeter(d)),
      ]),
      if (_meterEnds != null) ...[
        const SizedBox(height: 16),
        Card(
          clipBehavior: Clip.antiAlias,
          child: Column(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 4, 12),
              child: Row(children: [
                Text(tr('Until'), style: DLText.small),
                const SizedBox(width: 10),
                Expanded(child: Text(DateFormat.jm().format(_meterEnds!), style: DLText.numeral.copyWith(fontSize: 24))),
                IconButton(tooltip: tr('Remove'), icon: const Icon(Icons.close), onPressed: () => setState(() => _meterEnds = null)),
              ]),
            ),
            const Divider(),
            CheckboxListTile(
              value: _shareBackBy,
              onChanged: (v) => setState(() => _shareBackBy = v ?? false),
              title: Text(tr('Tell people who message me I\'ll be back by then')),
              subtitle: Text(tr('Only shown after they enter your plate digits')),
            ),
          ]),
        ),
      ],
      const SizedBox(height: 32),
      FilledButton.icon(
        icon: _saving
            ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2, color: DL.muted))
            : const Icon(Icons.pin_drop_outlined),
        label: Text(_saving ? tr('Finding your location…') : tr('Save parking spot')),
        onPressed: _saving ? null : _save,
      ),
    ]);
  }
}
