import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../l10n.dart';
import '../main.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'parking_screen.dart' show nextOccurrence;

/// Home card for the "Back by 6:30" status people see after messaging you.
class AwayCard extends StatelessWidget {
  const AwayCard({super.key});

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final v = s.vehicle!;
    final away = v.isAway;
    return SectionCard(
      onTap: () => showAwaySheet(context),
      child: Row(children: [
        IconBadge(Icons.schedule_outlined, tone: away ? Tone.info : null),
        const SizedBox(width: 14),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (away) ...[
              Row(children: [
                const PulseDot(),
                const SizedBox(width: 8),
                Text(tr('Back by '), style: DLText.strong),
                Text(DateFormat.jm().format(v.backAt!), style: DLText.strong.copyWith(fontFamily: 'SpaceGrotesk', fontWeight: FontWeight.w700)),
              ]),
              const SizedBox(height: 2),
              Text(
                v.awayNote?.isNotEmpty == true ? '“${v.awayNote}” · ${tr('shown to people who message you')}' : tr('Shown to people who message you'),
                style: DLText.small,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ] else ...[
              Text(tr('Stepping away from the car?'), style: DLText.strong),
              const SizedBox(height: 2),
              Text(tr('Tell people who message you when you\'ll be back.'), style: DLText.small),
            ],
          ]),
        ),
        if (away)
          TextButton(
            onPressed: () async {
              try {
                await s.clearAway();
              } catch (e) {
                if (context.mounted) showError(context, e);
              }
            },
            child: Text(tr('I\'m back')),
          )
        else
          const Icon(Icons.chevron_right, color: DL.muted),
      ]),
    );
  }
}

Future<void> showAwaySheet(BuildContext context) => showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => const _AwaySheet(),
    );

class _AwaySheet extends StatefulWidget {
  const _AwaySheet();
  @override
  State<_AwaySheet> createState() => _AwaySheetState();
}

class _AwaySheetState extends State<_AwaySheet> {
  late final _v = AppScope.read(context).vehicle!;
  late DateTime? _backAt = _v.isAway ? _v.backAt : null;
  late final _note = TextEditingController(text: _v.isAway ? _v.awayNote : '');
  bool _saving = false;

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _pickTime() async {
    final initial = _backAt ?? DateTime.now().add(const Duration(hours: 1));
    final picked = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(initial));
    if (picked != null) setState(() => _backAt = nextOccurrence(picked));
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await AppScope.read(context).setAway(_backAt!, _note.text);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        showError(context, e);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final quick = <(String, Duration)>[
      (tr('15 min'), const Duration(minutes: 15)),
      (tr('30 min'), const Duration(minutes: 30)),
      (tr('1 hour'), const Duration(hours: 1)),
      (tr('2 hours'), const Duration(hours: 2)),
    ];
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 0, 20, 24 + MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(tr('When will you be back?'), style: DLText.title),
          const SizedBox(height: 8),
          Text(
            tr('Someone you\'ve blocked in can decide whether to wait. They see it only after entering your plate digits and messaging you, never from just scanning the sticker. It clears itself when the time passes.'),
            style: DLText.body.copyWith(color: DL.muted, height: 1.5),
          ),
          const SizedBox(height: 20),
          Label(tr('Back in')),
          const SizedBox(height: 10),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final (label, d) in quick)
              ActionChip(label: Text(label), onPressed: () => setState(() => _backAt = DateTime.now().add(d))),
            ActionChip(avatar: const Icon(Icons.access_time), label: Text(tr('Pick time')), onPressed: _pickTime),
          ]),
          if (_backAt != null) ...[
            const SizedBox(height: 20),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              decoration: BoxDecoration(color: DL.ground, borderRadius: BorderRadius.circular(DL.rCard)),
              child: Row(children: [
                Text(tr('Back by'), style: DLText.small),
                const Spacer(),
                Text(DateFormat.jm().format(_backAt!), style: DLText.numeral),
              ]),
            ),
          ],
          const SizedBox(height: 20),
          FieldLabel(tr('Short note (optional)')),
          TextField(
            controller: _note,
            maxLength: 60,
            textCapitalization: TextCapitalization.sentences,
            decoration: InputDecoration(
              hintText: tr('e.g. In the pharmacy next door'),
              helperText: tr('Don\'t mention being away for long or where you live'),
            ),
          ),
          const SizedBox(height: 16),
          FilledButton(onPressed: _backAt == null || _saving ? null : _save, child: Text(tr('Save'))),
        ]),
      ),
    );
  }
}
