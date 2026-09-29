import 'package:flutter/material.dart';

import '../l10n.dart';
import '../main.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/motion.dart';

const bloodGroups = ['A+', 'A-', 'B+', 'B-', 'AB+', 'AB-', 'O+', 'O-'];

/// Opt-in emergency info. A stranger sees it only after reporting an
/// accident at the car (plate check passed), so a helper or paramedic can
/// act on it; never from just scanning the sticker.
class MedicalInfoScreen extends StatefulWidget {
  const MedicalInfoScreen({super.key});

  @override
  State<MedicalInfoScreen> createState() => _MedicalInfoScreenState();
}

class _MedicalInfoScreenState extends State<MedicalInfoScreen> {
  late final _v = AppScope.read(context).vehicle!;
  late String? _blood = _v.bloodGroup;
  late final _note = TextEditingController(text: _v.medicalNote ?? '');
  late bool _share = _v.medicalShare;
  bool _saving = false;

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final ready = _blood != null || _note.text.trim().isNotEmpty;
    try {
      await AppScope.read(context).saveMedical(bloodGroup: _blood, note: _note.text, share: _share && ready);
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('Medical info saved'))));
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        showError(context, e);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final ready = _blood != null || _note.text.trim().isNotEmpty;
    return Scaffold(
      appBar: AppBar(title: Text(tr('Medical info'))),
      body: SafeArea(
        child: ListView(padding: const EdgeInsets.fromLTRB(20, 8, 20, 32), children: revealAll([
          ScreenTitle(tr('For accidents only'), eyebrow: tr('Optional')),
          const SizedBox(height: 8),
          Text(
            tr('If someone reports an accident at your car, they see this so they can tell paramedics. Nobody sees it from just scanning your tag.'),
            style: DLText.body.copyWith(color: DL.muted),
          ),
          const SizedBox(height: 24),
          FieldLabel(tr('Blood group')),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final g in bloodGroups)
              ChoiceChip(
                label: Text(g, style: const TextStyle(fontFamily: 'SpaceGrotesk', fontWeight: FontWeight.w700)),
                selected: _blood == g,
                onSelected: (on) => setState(() => _blood = on ? g : null),
              ),
          ]),
          const SizedBox(height: 24),
          FieldLabel(tr('Allergies or conditions (optional)')),
          TextField(
            controller: _note,
            maxLength: 120,
            maxLines: 2,
            minLines: 1,
            textCapitalization: TextCapitalization.sentences,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              hintText: tr('e.g. Allergic to penicillin, diabetic'),
              helperText: tr('Keep it short. Don\'t add your name, address or ID numbers.'),
            ),
          ),
          const SizedBox(height: 16),
          Card(
            clipBehavior: Clip.antiAlias,
            child: SwitchListTile(
              value: _share && ready,
              onChanged: ready ? (v) => setState(() => _share = v) : null,
              title: Text(tr('Show on accident reports')),
              subtitle: Text(ready ? tr('You can turn this off any time') : tr('Add a blood group or a note first')),
            ),
          ),
          const SizedBox(height: 16),
          SectionCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Label(tr('What a helper sees')),
              const SizedBox(height: 12),
              Swap(
                alignment: Alignment.topLeft,
                child: _share && ready
                    ? MedicalCard(key: const ValueKey('on'), blood: _blood, note: _note.text.trim())
                    : Text(tr('Nothing. Sharing is off.'), key: const ValueKey('off'), style: DLText.body.copyWith(color: DL.muted)),
              ),
            ]),
          ),
          const SizedBox(height: 32),
          FilledButton(onPressed: _saving ? null : _save, child: Text(tr('Save'))),
          const SizedBox(height: 16),
          FootNote(tr('Stored with your car on Connect\'s servers so the scan page can show it. Family members who share this car can see and edit it.')),
        ])),
      ),
    );
  }
}

/// The medical block as the scan page shows it: error text on its tint.
class MedicalCard extends StatelessWidget {
  const MedicalCard({super.key, required this.blood, required this.note});
  final String? blood;
  final String? note;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: Tone.error.bg, borderRadius: BorderRadius.circular(DL.rButton)),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Icon(Icons.medical_information_outlined, color: DL.error),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (blood != null)
              Text.rich(TextSpan(children: [
                TextSpan(text: '${tr('Blood group')} ', style: DLText.body.copyWith(color: DL.error)),
                TextSpan(text: blood, style: DLText.strong.copyWith(color: DL.error, fontFamily: 'SpaceGrotesk', fontWeight: FontWeight.w700)),
              ])),
            if (note?.isNotEmpty == true) Text(note!, style: DLText.body.copyWith(color: DL.error, height: 1.45)),
          ]),
        ),
      ]),
    );
  }
}
