import 'dart:io';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n.dart';
import '../services/roadguard.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// What the road scan caught during the drive that just ended. Photos and positions stay on this
/// phone and are deleted after a week.
class DriveReportScreen extends StatelessWidget {
  const DriveReportScreen({super.key, required this.events});

  final List<RoadEvent> events;

  @override
  Widget build(BuildContext context) {
    final potholes = events.where((e) => e.type == 'pothole').length;
    final triple = events.where((e) => e.type == 'triple_riding').length;
    final noHelmet = events.where((e) => e.type == 'no_helmet').length;
    return Scaffold(
      backgroundColor: DL.ground,
      appBar: AppBar(backgroundColor: DL.ground, elevation: 0, foregroundColor: DL.ink),
      body: SafeArea(
        child: ListView(padding: const EdgeInsets.fromLTRB(20, 4, 20, 32), children: [
          ScreenTitle(
            tr('Drive report'),
            eyebrow: tr('Road scan'),
            subtitle: tr('{p} potholes, {t} triple riding, {h} without helmets', {'p': '$potholes', 't': '$triple', 'h': '$noHelmet'}),
          ),
          const SizedBox(height: 20),
          for (final e in events.reversed) ...[_EventCard(e), const SizedBox(height: 12)],
          FootNote(tr('Photos and locations stay on this phone and are deleted after 7 days. A suggestion, not proof: check each photo.')),
        ]),
      ),
    );
  }
}

class _EventCard extends StatelessWidget {
  const _EventCard(this.e);

  final RoadEvent e;

  String get _title => switch (e.type) {
        'triple_riding' => tr('Triple riding'),
        'no_helmet' => tr('Rider without helmet'),
        _ => tr('Pothole'),
      };

  @override
  Widget build(BuildContext context) {
    final plate = !e.isViolation
        ? null
        : e.plateText.isEmpty
            ? tr('Plate not read')
            : e.plateValid
                ? tr('Plate: {p}', {'p': e.plateText})
                : tr('Plate: {p} (check it)', {'p': e.plateText});
    return SectionCard(
      padding: EdgeInsets.zero,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        ClipRRect(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(DL.rCard)),
          child: AspectRatio(
            aspectRatio: 16 / 9,
            child: Image.file(
              File(e.framePath),
              fit: BoxFit.cover,
              cacheWidth: 900,
              errorBuilder: (_, _, _) => const ColoredBox(color: DL.skeleton, child: Center(child: Icon(Icons.image_not_supported_outlined, color: DL.muted))),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(child: Text(_title, style: DLText.section)),
              Text(DateFormat.jm().format(e.time), style: DLText.small),
            ]),
            if (plate != null) ...[const SizedBox(height: 6), Text(plate, style: DLText.body.copyWith(color: DL.muted))],
            if (e.lat != null && e.lon != null) ...[
              const SizedBox(height: 10),
              OutlinedButton.icon(
                icon: const Icon(Icons.place_outlined, size: 18),
                label: Text(tr('Open map')),
                onPressed: () => launchUrl(Uri.parse('geo:${e.lat},${e.lon}?q=${e.lat},${e.lon}(${Uri.encodeComponent(_title)})')),
              ),
            ],
          ]),
        ),
      ]),
    );
  }
}
