import 'dart:io';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n.dart';
import '../services/roadguard.dart';
import '../services/violation_report.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// What the road scan caught during the drive that just ended. Photos and positions stay on this
/// phone and are deleted after a week, unless you authorise a violation to be reported.
class DriveReportScreen extends StatefulWidget {
  const DriveReportScreen({super.key, required this.events, this.reporter});

  final List<RoadEvent> events;

  /// Overridable so tests can point reports at a local server.
  final ViolationReporter? reporter;

  @override
  State<DriveReportScreen> createState() => _DriveReportScreenState();
}

class _DriveReportScreenState extends State<DriveReportScreen> {
  late final ViolationReporter _reporter = widget.reporter ?? ViolationReporter();
  Set<String> _reported = {};
  String? _sending;

  @override
  void initState() {
    super.initState();
    _reporter.reportedIds().then((s) {
      if (mounted) setState(() => _reported = s);
    });
  }

  /// Hands the evidence to any app, for example a city police reporting app: the photos and a message with
  /// the violation, time, plate and a map link. Nothing is sent by this app itself.
  Future<void> _share(RoadEvent e, String title) async {
    final files = <XFile>[
      for (final path in [e.framePath, e.platePath, e.vehiclePath])
        if (path != null && File(path).existsSync()) XFile(path, mimeType: 'image/jpeg'),
    ];
    final plate = e.plateText.isEmpty ? tr('not read') : e.plateText;
    final where = e.hasLocation ? 'https://maps.google.com/?q=${e.lat},${e.lon}' : tr('not recorded');
    await SharePlus.instance.share(ShareParams(
      files: files,
      text: tr('{v} on {t}. Plate: {p}. Location: {l}', {
        'v': title,
        't': e.timeKnown ? DateFormat('d MMM y, h:mm a').format(e.time) : tr('not recorded'),
        'p': plate,
        'l': where,
      }),
    ));
  }

  Future<void> _authorise(RoadEvent e) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('Report this violation?')),
        content: Text(tr('This sends the photo with the number plate, the plate number, the time and where it happened to the reporting service. Check the photo first.')),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: Text(tr('Cancel'))),
          FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: Text(tr('Authorise and report'))),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _sending = e.id);
    final r = await _reporter.report(e);
    if (!mounted) return;
    setState(() {
      _sending = null;
      if (r.ok) _reported = {..._reported, e.id};
    });
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(r.ok ? tr('Report sent') : tr('Couldn\'t send the report. Check your internet and try again.')),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final events = widget.events;
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
          for (final e in events.reversed) ...[
            _EventCard(
              e,
              block: ViolationReporter.check(e, configured: _reporter.configured, alreadyReported: _reported.contains(e.id)),
              sending: _sending == e.id,
              onAuthorise: _sending == null ? () => _authorise(e) : null,
              onShare: (title) => _share(e, title),
            ),
            const SizedBox(height: 12),
          ],
          FootNote(tr('Photos and locations stay on this phone and are deleted after 7 days. A suggestion, not proof: check each photo.')),
        ]),
      ),
    );
  }
}

class _EventCard extends StatelessWidget {
  const _EventCard(this.e, {required this.block, required this.sending, required this.onAuthorise, required this.onShare});

  final RoadEvent e;
  final ReportBlock block;
  final bool sending;
  final VoidCallback? onAuthorise;
  final void Function(String title) onShare;

  String get _title => switch (e.type) {
        'triple_riding' => tr('Triple riding'),
        'no_helmet' => tr('Rider without helmet'),
        'pothole' => tr('Pothole'),
        _ => 'Capture test', // lab only: from the adb test hook
      };

  /// The reporting line under a violation: a button when it can be sent, otherwise the reason it can't.
  Widget? _reporting() {
    switch (block) {
      case ReportBlock.notConfigured:
      case ReportBlock.notAViolation:
        return null;
      case ReportBlock.none:
        return Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.icon(
            icon: sending
                ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2, color: DL.onDark))
                : const Icon(Icons.outbox_outlined, size: 18),
            label: Text(sending ? tr('Sending...') : tr('Authorise and report')),
            onPressed: onAuthorise,
          ),
        );
      case ReportBlock.alreadyReported:
        return Row(children: [
          const Icon(Icons.check_circle_outline, size: 18, color: DL.success),
          const SizedBox(width: 6),
          Text(tr('Reported'), style: DLText.small.copyWith(color: DL.success)),
        ]);
      case ReportBlock.noLocation:
        return Text(tr('No location was recorded, so it can\'t be reported'), style: DLText.small);
      case ReportBlock.noTime:
        return Text(tr('The clip has no recorded time, so it can\'t be reported'), style: DLText.small);
    }
  }

  @override
  Widget build(BuildContext context) {
    final plate = !e.isViolation
        ? null
        : e.plateText.isEmpty
            ? tr('Plate not read')
            : e.plateValid
                ? tr('Plate: {p}', {'p': e.plateText})
                : tr('Plate: {p} (check it)', {'p': e.plateText});
    final reporting = _reporting();
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
              Text(
                !e.timeKnown ? '' : (e.imported ? DateFormat('d MMM, h:mm a').format(e.time) : DateFormat.jm().format(e.time)),
                style: DLText.small,
              ),
            ]),
            if (e.imported) ...[
              const SizedBox(height: 4),
              Text(
                e.timeKnown ? tr('From clip: {c}', {'c': e.clip}) : '${tr('From clip: {c}', {'c': e.clip})} · ${tr('Time not recorded in the clip')}',
                style: DLText.small,
              ),
            ],
            if (plate != null) ...[const SizedBox(height: 6), Text(plate, style: DLText.body.copyWith(color: DL.muted))],
            if (e.hasLocation || e.isViolation) ...[
              const SizedBox(height: 10),
              Wrap(spacing: 8, runSpacing: 8, children: [
                if (e.hasLocation)
                  OutlinedButton.icon(
                    icon: const Icon(Icons.place_outlined, size: 18),
                    label: Text(tr('Open map')),
                    onPressed: () => launchUrl(Uri.parse('geo:${e.lat},${e.lon}?q=${e.lat},${e.lon}(${Uri.encodeComponent(_title)})')),
                  ),
                if (e.isViolation)
                  OutlinedButton.icon(
                    icon: const Icon(Icons.ios_share, size: 18),
                    label: Text(tr('Share evidence')),
                    onPressed: () => onShare(_title),
                  ),
              ]),
            ],
            if (reporting != null) ...[const SizedBox(height: 12), reporting],
          ]),
        ),
      ]),
    );
  }
}
