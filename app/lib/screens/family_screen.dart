import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../l10n.dart';
import '../main.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// Who else gets alerts for this car. The owner invites and removes; a member
/// can see the list and leave.
class FamilyScreen extends StatelessWidget {
  const FamilyScreen({super.key});

  static const maxMembers = 5;

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final v = s.vehicle;
    if (v == null) return const Scaffold();
    final full = s.family.length >= maxMembers;

    return Scaffold(
      appBar: AppBar(title: Text(tr('Family'))),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: s.refresh,
          child: ListView(padding: const EdgeInsets.fromLTRB(20, 8, 20, 32), children: [
            ScreenTitle(tr('Who gets alerts'), eyebrow: tr('{n} of {max}', {'n': s.family.length + 1, 'max': maxMembers + 1})),
            const SizedBox(height: 8),
            Text(
              s.isOwner
                  ? tr('Everyone here gets alerts for {car} ({reg}) and can reply, so whoever is closest can help.', {'car': v.title, 'reg': v.prettyReg})
                  : tr('This car was shared with you. You get its alerts and can reply to people who message about it.'),
              style: DLText.body.copyWith(color: DL.muted),
            ),
            const SizedBox(height: 24),
            Card(
              clipBehavior: Clip.antiAlias,
              child: Column(children: [
                ListTile(
                  leading: const _Avatar(icon: Icons.person_outline),
                  title: Text(s.isOwner ? tr('You') : tr('Owner')),
                  subtitle: Text(tr('Added the car')),
                  trailing: StatusBadge(tr('Owner'), tone: Tone.info),
                ),
                for (final m in s.family) ...[
                  const Divider(),
                  ListTile(
                    leading: _Avatar(letter: m.name.characters.first.toUpperCase()),
                    title: Text(m.userId == s.userId ? tr('{name} (you)', {'name': m.name}) : m.name),
                    subtitle: Text(tr('Joined {ago}', {'ago': timeAgo(m.joinedAt)})),
                    trailing: s.isOwner
                        ? IconButton(
                            tooltip: tr('Remove'),
                            icon: const Icon(Icons.person_remove_outlined, color: DL.muted),
                            onPressed: () => _confirm(
                              context,
                              title: tr('Remove {name}?', {'name': m.name}),
                              body: tr('They\'ll stop getting alerts for this car.'),
                              action: tr('Remove'),
                              run: () => s.removeMember(m.userId),
                            ),
                          )
                        : null,
                  ),
                ],
              ]),
            ),
            const SizedBox(height: 24),
            if (s.isOwner) ...[
              FilledButton.icon(
                icon: const Icon(Icons.group_add_outlined),
                label: Text(tr('Invite family')),
                onPressed: full ? null : () => _invite(context),
              ),
              const SizedBox(height: 10),
              Text(
                full
                    ? tr('A car can be shared with up to {n} people. Remove someone to invite another.', {'n': maxMembers})
                    : tr('They install Connect, tap "Join a family car" and enter the code. Each code works once, for 24 hours.'),
                style: DLText.small,
                textAlign: TextAlign.center,
              ),
            ] else
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(foregroundColor: DL.error, iconColor: DL.error),
                icon: const Icon(Icons.logout),
                label: Text(tr('Leave this car')),
                onPressed: () => _confirm(
                  context,
                  title: tr('Leave {car}?', {'car': v.title}),
                  body: tr('You\'ll stop getting its alerts. The owner can invite you again.'),
                  action: tr('Leave'),
                  run: () async {
                    final nav = Navigator.of(context);
                    await s.leaveFamily();
                    nav.popUntil((r) => r.isFirst);
                  },
                ),
              ),
          ]),
        ),
      ),
    );
  }

  Future<void> _invite(BuildContext context) async {
    final s = AppScope.read(context);
    final String code;
    try {
      code = await s.createInvite();
    } catch (e) {
      if (context.mounted) showError(context, e);
      return;
    }
    if (!context.mounted) return;
    final v = s.vehicle!;
    await showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(tr('Invite code')),
        actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 18),
            decoration: BoxDecoration(color: DL.ground, borderRadius: BorderRadius.circular(DL.rCard)),
            child: SelectableText('${code.substring(0, 3)} ${code.substring(3)}',
                textAlign: TextAlign.center, style: DLText.display.copyWith(letterSpacing: 6)),
          ),
          const SizedBox(height: 14),
          Text(tr('Works once, for 24 hours. Only share it with people you trust with this car\'s alerts.'), textAlign: TextAlign.center),
        ]),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: code));
              Navigator.pop(c);
            },
            child: Text(tr('Copy')),
          ),
          FilledButton.icon(
            icon: const Icon(Icons.share_outlined),
            label: Text(tr('Share')),
            onPressed: () {
              Navigator.pop(c);
              SharePlus.instance.share(ShareParams(
                text: tr('Join our {car} on Connect so you get its alerts too. Install the app, tap "Join a family car" and enter code {code} (valid 24 hours).',
                    {'car': '${v.make} ${v.model}', 'code': code}),
              ));
            },
          ),
        ],
      ),
    );
  }

  Future<void> _confirm(BuildContext context,
      {required String title, required String body, required String action, required Future<void> Function() run}) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: Text(tr('Cancel'))),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(action)),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await run();
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }
}

/// From the welcome screen: join a car someone in the family already added.
class JoinFamilyScreen extends StatefulWidget {
  const JoinFamilyScreen({super.key});
  @override
  State<JoinFamilyScreen> createState() => _JoinFamilyScreenState();
}

class _JoinFamilyScreenState extends State<JoinFamilyScreen> {
  final _form = GlobalKey<FormState>();
  final _code = TextEditingController();
  final _name = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _code.dispose();
    _name.dispose();
    super.dispose();
  }

  Future<void> _join() async {
    if (!_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final nav = Navigator.of(context);
    try {
      final ok = await AppScope.read(context).joinFamily(_code.text.replaceAll(' ', ''), _name.text.trim());
      if (ok) {
        nav.popUntil((r) => r.isFirst);
        return;
      }
      _error = tr('That code didn\'t work. Codes work once and expire after 24 hours, so ask for a new one.');
    } on PostgrestException catch (e) {
      _error = switch (e.message) {
        'too_many_attempts' => tr('Too many wrong codes. Try again in an hour.'),
        'family_full' => tr('This car is already shared with {n} people.', {'n': FamilyScreen.maxMembers}),
        _ => tr('Something went wrong. Check your internet and try again.'),
      };
    } catch (_) {
      _error = tr('Something went wrong. Check your internet and try again.');
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(tr('Join a family car'))),
      body: SafeArea(
        child: Form(
          key: _form,
          child: ListView(padding: const EdgeInsets.fromLTRB(20, 8, 20, 32), children: [
            ScreenTitle(tr('Join a family car')),
            const SizedBox(height: 8),
            Text(tr('Get alerts for a car someone in your family already added. Ask them for a code from Garage → Family.'),
                style: DLText.body.copyWith(color: DL.muted)),
            const SizedBox(height: 24),
            FieldLabel(tr('Invite code')),
            TextFormField(
              controller: _code,
              autofocus: true,
              textCapitalization: TextCapitalization.characters,
              inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9 ]')), LengthLimitingTextInputFormatter(7)],
              style: DLText.numeral.copyWith(fontSize: 26, letterSpacing: 4),
              decoration: const InputDecoration(hintText: 'ABC 234'),
              validator: (v) => (v ?? '').replaceAll(' ', '').length == 6 ? null : tr('The code has 6 characters'),
            ),
            const SizedBox(height: 16),
            FieldLabel(tr('Your name')),
            TextFormField(
              controller: _name,
              maxLength: 30,
              textCapitalization: TextCapitalization.words,
              decoration: InputDecoration(hintText: tr('e.g. Amma, Rahul'), helperText: tr('Shown in the car\'s family list')),
              validator: (v) => (v ?? '').trim().isEmpty ? tr('Add a name') : null,
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(color: Tone.error.bg, borderRadius: BorderRadius.circular(DL.rButton)),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Icon(Icons.error_outline, color: DL.error, size: 20),
                  const SizedBox(width: 10),
                  Expanded(child: Text(_error!, style: DLText.small.copyWith(color: DL.error))),
                ]),
              ),
            ],
            const SizedBox(height: 24),
            FilledButton(onPressed: _busy ? null : _join, child: Text(_busy ? tr('Joining…') : tr('Join'))),
          ]),
        ),
      ),
    );
  }
}

class _Avatar extends StatelessWidget {
  const _Avatar({this.letter, this.icon});
  final String? letter;
  final IconData? icon;

  @override
  Widget build(BuildContext context) => CircleAvatar(
        backgroundColor: DL.ground,
        foregroundColor: DL.ink,
        child: icon != null ? Icon(icon, color: DL.muted, size: 22) : Text(letter!, style: DLText.strong),
      );
}
