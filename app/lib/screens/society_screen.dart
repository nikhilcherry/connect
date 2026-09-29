import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';

import '../data/models.dart';
import '../l10n.dart';
import '../main.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/motion.dart';

/// Housing societies and office car parks the user belongs to.
class SocietiesScreen extends StatelessWidget {
  const SocietiesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(tr('Society'))),
      body: SafeArea(
        child: ListView(padding: const EdgeInsets.fromLTRB(20, 8, 20, 32), children: revealAll([
          ScreenTitle(tr('Your society'), eyebrow: tr('Apartment or office parking')),
          const SizedBox(height: 8),
          Text(
            tr('Your society admin can send notices to every car ("Move cars for cleaning, Sunday 8 am") and see how many cars are tagged. They never see your number plate or phone number.'),
            style: DLText.body.copyWith(color: DL.muted),
          ),
          const SizedBox(height: 24),
          if (s.societies.isNotEmpty)
            Column(children: [
              for (final soc in s.societies) ...[
                InfoRow(
                  icon: Icons.apartment_outlined,
                  tone: Tone.info,
                  title: soc.name,
                  subtitle: soc.isAdmin ? tr('You\'re the admin') : tr('Member'),
                  onTap: () => push(context, SocietyScreen(societyId: soc.id)),
                ),
                const SizedBox(height: 12),
              ],
              const SizedBox(height: 20),
            ]),
          FilledButton.icon(
            icon: const Icon(Icons.vpn_key_outlined),
            label: Text(tr('Join with a code')),
            onPressed: () => _sheet(context, join: true),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            icon: const Icon(Icons.add_business_outlined),
            label: Text(tr('Set up a society')),
            onPressed: () => _sheet(context, join: false),
          ),
          const SizedBox(height: 16),
          Text(tr('Setting one up is free. You become its admin and get a code to put on the notice board.'), style: DLText.small),
        ])),
      ),
    );
  }

  static Future<void> _sheet(BuildContext context, {required bool join}) => showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (_) => _SocietyForm(join: join),
      );
}

class _SocietyForm extends StatefulWidget {
  const _SocietyForm({required this.join});
  final bool join;

  @override
  State<_SocietyForm> createState() => _SocietyFormState();
}

class _SocietyFormState extends State<_SocietyForm> {
  final _form = GlobalKey<FormState>();
  final _main = TextEditingController();
  final _flat = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _main.dispose();
    _flat.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final s = AppScope.read(context);
    final flat = _flat.text.trim().isEmpty ? null : _flat.text.trim();
    try {
      if (widget.join) {
        final ok = await s.joinSociety(_main.text, flat);
        if (!ok) {
          setState(() {
            _busy = false;
            _error = tr('That code didn\'t work. Check it with your society admin.');
          });
          return;
        }
      } else {
        await s.createSociety(_main.text, flat);
      }
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.toString().contains('too_many_attempts')
            ? tr('Too many wrong codes. Try again in an hour.')
            : e.toString().contains('too_many_societies')
                ? tr('You can run up to 3 societies.')
                : tr('Something went wrong. Check your internet and try again.');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 0, 20, 24 + MediaQuery.viewInsetsOf(context).bottom),
      child: Form(
        key: _form,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(widget.join ? tr('Join your society') : tr('Set up a society'), style: DLText.title),
          const SizedBox(height: 20),
          FieldLabel(widget.join ? tr('Society code') : tr('Society name')),
          TextFormField(
            controller: _main,
            autofocus: true,
            textCapitalization: widget.join ? TextCapitalization.characters : TextCapitalization.words,
            inputFormatters: widget.join
                ? [
                    FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9]')),
                    LengthLimitingTextInputFormatter(6),
                    TextInputFormatter.withFunction((_, v) => v.copyWith(text: v.text.toUpperCase())),
                  ]
                : [LengthLimitingTextInputFormatter(60)],
            style: widget.join ? DLText.numeral.copyWith(fontSize: 24, letterSpacing: 6) : null,
            decoration: InputDecoration(hintText: widget.join ? 'ABC234' : tr('e.g. Prestige Lakeside, Tower B')),
            validator: (v) => widget.join
                ? ((v ?? '').length == 6 ? null : tr('The code has 6 characters'))
                : ((v ?? '').trim().length >= 2 ? null : tr('Enter the society\'s name')),
          ),
          const SizedBox(height: 16),
          FieldLabel(tr('Flat or parking slot (optional)')),
          TextFormField(
            controller: _flat,
            textCapitalization: TextCapitalization.characters,
            inputFormatters: [LengthLimitingTextInputFormatter(20)],
            decoration: InputDecoration(hintText: tr('e.g. B-204 or P2-17'), helperText: tr('Only the admin sees this')),
          ),
          Swap(
            child: _error == null
                ? const SizedBox(key: ValueKey('ok'), width: double.infinity)
                : Padding(
                    key: ValueKey(_error),
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(_error!, style: DLText.small.copyWith(color: DL.error)),
                  ),
          ),
          const SizedBox(height: 20),
          FilledButton(onPressed: _busy ? null : _submit, child: Text(widget.join ? tr('Join') : tr('Create'))),
        ]),
      ),
    );
  }
}

class SocietyScreen extends StatefulWidget {
  const SocietyScreen({super.key, required this.societyId});
  final String societyId;

  @override
  State<SocietyScreen> createState() => _SocietyScreenState();
}

class _SocietyScreenState extends State<SocietyScreen> {
  SocietyStats? _stats;
  String? _code;
  List<RosterEntry>? _roster;
  final _notice = TextEditingController();
  bool _posting = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _notice.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final s = AppScope.read(context);
    final soc = s.societies.where((x) => x.id == widget.societyId).firstOrNull;
    if (soc == null) return;
    try {
      final stats = await s.societyStats(soc.id);
      final code = soc.isAdmin ? await s.societyJoinCode(soc.id) : null;
      final roster = soc.isAdmin ? await s.societyRoster(soc.id) : null;
      if (!mounted) return;
      setState(() {
        _stats = stats;
        _code = code;
        _roster = roster;
      });
    } catch (e) {
      debugPrint('society load failed: $e');
    }
  }

  Future<void> _post() async {
    final body = _notice.text.trim();
    if (body.isEmpty) return;
    setState(() => _posting = true);
    try {
      await AppScope.read(context).postNotice(widget.societyId, body);
      _notice.clear();
      if (mounted) {
        FocusScope.of(context).unfocus();
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('Notice sent to every member'))));
      }
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _posting = false);
    }
  }

  Future<bool> _confirm(String title, String body, String action) async =>
      await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text(title),
          content: Text(body),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: Text(tr('Cancel'))),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(action)),
          ],
        ),
      ) ==
      true;

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final soc = s.societies.where((x) => x.id == widget.societyId).firstOrNull;
    if (soc == null) {
      return Scaffold(appBar: AppBar(), body: Center(child: Text(tr('You\'re no longer in this society.'), style: DLText.body)));
    }
    final notices = s.notices.where((n) => n.societyId == soc.id).toList();
    final stats = _stats;
    return Scaffold(
      appBar: AppBar(title: Text(tr('Society'))),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: () async {
            await s.refresh();
            await _load();
          },
          child: ListView(padding: const EdgeInsets.fromLTRB(20, 8, 20, 32), children: [
            Reveal(child: ScreenTitle(soc.name, eyebrow: soc.isAdmin ? tr('You\'re the admin') : tr('Member'))),
            const SizedBox(height: 20),
            Reveal(
              index: 1,
              child: IntrinsicHeight(
                child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Expanded(child: StatCard(value: stats == null ? '—' : '${stats.members}', label: tr('Members'))),
                  const SizedBox(width: 12),
                  Expanded(
                    child: StatCard(
                      value: stats == null ? '—' : '${stats.tagged}',
                      label: tr('Cars with an active tag'),
                      live: (stats?.tagged ?? 0) > 0,
                    ),
                  ),
                ]),
              ),
            ),
            if (soc.isAdmin && _code != null) ...[
              const SizedBox(height: 12),
              Reveal(index: 2, child: _JoinCodeCard(code: _code!, name: soc.name)),
            ],
            if (soc.isAdmin) ...[
              const SizedBox(height: 28),
              Reveal(
                index: 3,
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Label(tr('Send a notice')),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _notice,
                    maxLength: 280,
                    maxLines: 3,
                    minLines: 2,
                    textCapitalization: TextCapitalization.sentences,
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(hintText: tr('e.g. Basement cleaning on Sunday, 8–11 am. Please move cars to the visitor lot.')),
                  ),
                  FilledButton.icon(
                    icon: const Icon(Icons.campaign_outlined),
                    label: Text(tr('Send to all members')),
                    onPressed: _posting || _notice.text.trim().isEmpty ? null : _post,
                  ),
                ]),
              ),
            ],
            const SizedBox(height: 28),
            Reveal(index: 4, child: Label(tr('Notices'))),
            const SizedBox(height: 12),
            Swap(
              child: notices.isEmpty
                  ? Text(
                      soc.isAdmin ? tr('Nothing sent yet.') : tr('No notices yet. They\'ll appear here and as a notification.'),
                      key: const ValueKey('none'),
                      style: DLText.body.copyWith(color: DL.muted),
                    )
                  : Column(key: ValueKey(notices.length), children: [
                      for (final (i, n) in notices.indexed) ...[
                        Reveal(index: 4 + i, child: _NoticeCard(notice: n, canDelete: soc.isAdmin)),
                        const SizedBox(height: 10),
                      ],
                    ]),
            ),
            if (soc.isAdmin && _roster != null) ...[
              const SizedBox(height: 28),
              Label(tr('Members')),
              const SizedBox(height: 12),
              Card(
                clipBehavior: Clip.antiAlias,
                child: Column(children: [
                  for (final (i, r) in _roster!.indexed) ...[
                    if (i > 0) const Divider(),
                    ListTile(
                      leading: IconBadge(Icons.directions_car_outlined, size: 40, tone: r.tagged ? Tone.success : null),
                      title: Text(r.flat ?? tr('No flat given')),
                      subtitle: Text(r.car ?? tr('No car added')),
                      trailing: r.member == s.userId
                          ? StatusBadge(tr('You'), tone: Tone.neutral)
                          : IconButton(
                              tooltip: tr('Remove'),
                              icon: const Icon(Icons.person_remove_outlined),
                              onPressed: () async {
                                if (!await _confirm(
                                    tr('Remove this member?'), tr('They stop getting notices. They can rejoin with the code.'), tr('Remove'))) {
                                  return;
                                }
                                try {
                                  await s.removeResident(soc.id, r.member);
                                  await _load();
                                } catch (e) {
                                  if (context.mounted) showError(context, e);
                                }
                              },
                            ),
                    ),
                  ],
                ]),
              ),
            ],
            const SizedBox(height: 28),
            if (soc.isAdmin)
              TextButton.icon(
                style: TextButton.styleFrom(foregroundColor: DL.error, iconColor: DL.error),
                icon: const Icon(Icons.delete_outline),
                label: Text(tr('Delete this society')),
                onPressed: () async {
                  if (!await _confirm(tr('Delete this society?'), tr('All members and notices are removed. This can\'t be undone.'), tr('Delete'))) return;
                  await s.deleteSociety(soc.id);
                  if (context.mounted) Navigator.of(context).pop();
                },
              )
            else
              TextButton.icon(
                style: TextButton.styleFrom(foregroundColor: DL.error, iconColor: DL.error),
                icon: const Icon(Icons.logout),
                label: Text(tr('Leave this society')),
                onPressed: () async {
                  if (!await _confirm(tr('Leave this society?'), tr('You\'ll stop getting its notices.'), tr('Leave'))) return;
                  await s.leaveSociety(soc.id);
                  if (context.mounted) Navigator.of(context).pop();
                },
              ),
          ]),
        ),
      ),
    );
  }
}

class _JoinCodeCard extends StatelessWidget {
  const _JoinCodeCard({required this.code, required this.name});
  final String code;
  final String name;

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Label(tr('Join code')),
            const SizedBox(height: 8),
            SelectableText(code, style: DLText.numeral.copyWith(letterSpacing: 6)),
            const SizedBox(height: 6),
            Text(tr('Put it on the notice board or the residents\' group.'), style: DLText.small),
          ]),
        ),
        IconButton.filled(
          tooltip: tr('Share'),
          style: IconButton.styleFrom(backgroundColor: DL.violet, foregroundColor: DL.onDark),
          icon: const Icon(Icons.share_outlined),
          onPressed: () => SharePlus.instance.share(ShareParams(
            text: tr('Join {name} on Connect to get parking notices. Open the app, go to Garage > Society and enter code {code}.',
                {'name': name, 'code': code}),
          )),
        ),
      ]),
    );
  }
}

class _NoticeCard extends StatelessWidget {
  const _NoticeCard({required this.notice, required this.canDelete});
  final SocietyNotice notice;
  final bool canDelete;

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const IconBadge(Icons.campaign_outlined, size: 40),
        const SizedBox(width: 14),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(notice.body, style: DLText.body.copyWith(height: 1.45)),
            const SizedBox(height: 6),
            Text(DateFormat('d MMM, h:mm a').format(notice.createdAt), style: DLText.small),
          ]),
        ),
        if (canDelete)
          IconButton(
            tooltip: tr('Delete'),
            icon: const Icon(Icons.close, size: 18),
            onPressed: () => AppScope.read(context).deleteNotice(notice.id),
          ),
      ]),
    );
  }
}
