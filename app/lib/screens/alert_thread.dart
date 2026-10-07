import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../data/models.dart';
import '../l10n.dart';
import '../main.dart';
import '../services/bridge.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/motion.dart';

class AlertThreadScreen extends StatefulWidget {
  const AlertThreadScreen({super.key, required this.alertId});
  final String alertId;

  @override
  State<AlertThreadScreen> createState() => _AlertThreadScreenState();
}

class _AlertThreadScreenState extends State<AlertThreadScreen> {
  // Shown in the owner's language, but sent in the one the stranger chose on
  // the scan page: the app already carries every language's strings, so the
  // reply is in their language without any machine translation.
  static const _quickKeys = [
    /*t*/'Coming in 2 minutes',
    /*t*/'Moving it now, sorry!',
    /*t*/'Thanks for letting me know',
    /*t*/'I\'m not nearby, sorry',
  ];

  final _input = TextEditingController();
  final _scroll = ScrollController();
  List<AlertMessage> _messages = [];

  /// Messages present at first load don't animate; later arrivals do.
  int? _seenUpTo;
  RealtimeChannel? _channel;
  bool _sending = false;
  final _dictation = Dictation();
  bool _listening = false;

  @override
  void initState() {
    super.initState();
    final s = AppScope.read(context);
    _load();
    _channel = s.watchMessages(widget.alertId, _load);
    s.markSeen(widget.alertId);
  }

  @override
  void dispose() {
    if (_channel != null) AppScope.read(context).unwatch(_channel!);
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final m = await AppScope.read(context).messages(widget.alertId);
      if (!mounted) return;
      final first = _seenUpTo == null;
      setState(() {
        _seenUpTo ??= m.isEmpty ? 0 : m.last.id;
        _messages = m;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_scroll.hasClients) return;
        if (first || reduceMotion(context)) {
          _scroll.jumpTo(_scroll.position.maxScrollExtent);
        } else {
          _scroll.animateTo(_scroll.position.maxScrollExtent, duration: DL.medium, curve: DL.ease);
        }
      });
    } catch (_) {}
  }

  Future<void> _dictate() async {
    if (_listening) {
      await _dictation.stop();
      if (mounted) setState(() => _listening = false);
      return;
    }
    final ok = await _dictation.start(L10n.lang.value, (text, done) {
      if (!mounted) return;
      setState(() {
        _input.text = text;
        _input.selection = TextSelection.collapsed(offset: text.length);
        if (done) _listening = false;
      });
    });
    if (!mounted) return;
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('Voice typing isn\'t available on this phone.'))));
    } else {
      setState(() => _listening = true);
    }
  }

  Future<void> _send(String text, {bool onMyWay = false}) async {
    final body = text.trim();
    if (body.isEmpty || _sending) return;
    setState(() => _sending = true);
    final s = AppScope.read(context);
    try {
      await s.sendMessage(widget.alertId, body);
      if (onMyWay) await s.setStatus(widget.alertId, AlertStatus.onMyWay);
      _input.clear();
      await _load();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final alert = s.alerts.where((a) => a.id == widget.alertId).firstOrNull;
    if (alert == null) {
      return const Scaffold(body: Center(child: SizedBox.square(dimension: 28, child: CircularProgressIndicator(strokeWidth: 2.5))));
    }
    final resolved = alert.status == AlertStatus.resolved;
    final (tone, label) = switch (alert.status) {
      AlertStatus.open => (alert.kind.urgent ? Tone.error : Tone.info, alert.kind.urgent ? tr('Urgent') : tr('New')),
      AlertStatus.onMyWay => (Tone.neutral, tr('On my way')),
      AlertStatus.resolved => (Tone.success, tr('Sorted')),
    };
    final v = s.vehicle;

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Row(children: [
          Icon(alert.kind.icon, color: alert.kind.urgent ? DL.error : DL.muted, size: 22),
          const SizedBox(width: 10),
          Flexible(child: Text(tr(alert.kind.label), overflow: TextOverflow.ellipsis)),
        ]),
        actions: [
          Padding(padding: const EdgeInsets.only(right: 4), child: Center(child: StatusBadge(label, tone: tone))),
          PopupMenuButton<String>(
            tooltip: tr('More'),
            icon: const Icon(Icons.more_vert),
            onSelected: (v) async {
              if (v == 'block') {
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (c) => AlertDialog(
                    title: Text(tr('Block this person?')),
                    content: Text(tr('You won\'t get alerts from them again. They won\'t be told.')),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(c, false), child: Text(tr('Cancel'))),
                      FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(tr('Block'))),
                    ],
                  ),
                );
                if (ok == true && context.mounted) {
                  await s.blockSender(alert.id);
                  if (context.mounted) Navigator.of(context).pop();
                }
              }
            },
            itemBuilder: (_) => [
              PopupMenuItem(value: 'block', child: Row(children: [
                const Icon(Icons.block_outlined, size: 20, color: DL.error),
                const SizedBox(width: 12),
                Text(tr('Block and report spam')),
              ])),
            ],
          ),
        ],
      ),
      body: Column(children: [
        Expanded(
          child: ListView(controller: _scroll, padding: const EdgeInsets.fromLTRB(20, 8, 20, 16), children: [
            Center(child: Label('${tr('Someone at your car')} · ${DateFormat('d MMM, h:mm a').format(alert.createdAt)}')),
            const SizedBox(height: 16),
            if (alert.photoPath != null) Reveal(child: _AlertPhoto(path: alert.photoPath!)),
            if (alert.kind == AlertKind.accident)
              Container(
                margin: const EdgeInsets.only(bottom: 16),
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(color: Tone.error.bg, borderRadius: BorderRadius.circular(DL.rCard)),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Icon(Icons.warning_amber_outlined, color: DL.error, size: 22),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      [
                        tr('Reported accident or damage. If anyone may be hurt, the reporter was shown a button to call 112.'),
                        if (v != null && v.medicalShare && v.hasMedical) tr('They can also see the medical info you shared.'),
                      ].join(' '),
                      style: DLText.body.copyWith(color: DL.error, height: 1.5),
                    ),
                  ),
                ]),
              ),
            _Bubble(text: alert.note?.isNotEmpty == true ? alert.note! : tr(alert.kind.label), mine: false),
            for (final m in _messages) _Bubble(key: ValueKey(m.id), text: m.body, mine: m.fromOwner, animate: m.id > (_seenUpTo ?? 1 << 62)),
          ]),
        ),
        DecoratedBox(
          decoration: const BoxDecoration(color: DL.card, boxShadow: DL.floatShadow),
          child: SafeArea(
            top: false,
            child: Swap(
              alignment: Alignment.bottomCenter,
              child: resolved
                ? Padding(
                    key: const ValueKey('resolved'),
                    padding: const EdgeInsets.fromLTRB(20, 12, 12, 12),
                    child: Row(children: [
                      const Icon(Icons.check_circle_outline, color: DL.success),
                      const SizedBox(width: 10),
                      Expanded(child: Text(tr('Marked as sorted'), style: DLText.strong)),
                      TextButton(onPressed: () => s.setStatus(alert.id, AlertStatus.open), child: Text(tr('Reopen'))),
                    ]),
                  )
                : Column(key: const ValueKey('open'), mainAxisSize: MainAxisSize.min, children: [
                    const SizedBox(height: 12),
                    SizedBox(
                      height: 44,
                      child: ListView.separated(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        scrollDirection: Axis.horizontal,
                        itemCount: _quickKeys.length,
                        separatorBuilder: (_, _) => const SizedBox(width: 8),
                        itemBuilder: (_, i) => ActionChip(
                          label: Text(tr(_quickKeys[i])),
                          onPressed: () => _send(trIn(_quickKeys[i], alert.scannerLang), onMyWay: i < 2),
                        ),
                      ),
                    ),
                    if (alert.scannerLang != L10n.lang.value)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            tr('Quick replies are sent in {language}, their language', {'language': alert.scannerLang.native}),
                            style: DLText.small.copyWith(color: DL.muted),
                          ),
                        ),
                      ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 10, 20, 10),
                      child: Row(children: [
                        Expanded(
                          child: TextField(
                            controller: _input,
                            maxLength: 280,
                            textCapitalization: TextCapitalization.sentences,
                            decoration: InputDecoration(hintText: tr('Reply…'), counterText: ''),
                            onSubmitted: _send,
                          ),
                        ),
                        const SizedBox(width: 8),
                        IconButton.outlined(
                          tooltip: _listening ? tr('Stop') : tr('Speak your reply'),
                          style: IconButton.styleFrom(minimumSize: const Size(50, 50)),
                          onPressed: _sending ? null : _dictate,
                          icon: Icon(_listening ? Icons.stop_circle_outlined : Icons.mic_none),
                        ),
                        const SizedBox(width: 8),
                        IconButton.filled(
                          tooltip: tr('Send'),
                          style: IconButton.styleFrom(
                            backgroundColor: DL.violet,
                            foregroundColor: DL.onDark,
                            minimumSize: const Size(50, 50),
                            shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(DL.rButton))),
                          ),
                          onPressed: _sending ? null : () => _send(_input.text),
                          icon: const Icon(Icons.send_outlined),
                        ),
                      ]),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                      child: Row(children: [
                        if (alert.status == AlertStatus.open) ...[
                          Expanded(
                            child: OutlinedButton(
                              style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 12)),
                              onPressed: () => s.setStatus(alert.id, AlertStatus.onMyWay),
                              child: Text(tr('On my way')),
                            ),
                          ),
                          const SizedBox(width: 12),
                        ],
                        Expanded(
                          child: FilledButton(
                            style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 12)),
                            onPressed: () => s.setStatus(alert.id, AlertStatus.resolved),
                            child: Text(tr('Mark as sorted')),
                          ),
                        ),
                      ]),
                    ),
                  ]),
            ),
          ),
        ),
      ]),
    );
  }
}

/// The stranger's photo, fetched through a short-lived signed link. Tap to
/// open it full screen.
class _AlertPhoto extends StatefulWidget {
  const _AlertPhoto({required this.path});
  final String path;

  @override
  State<_AlertPhoto> createState() => _AlertPhotoState();
}

class _AlertPhotoState extends State<_AlertPhoto> {
  late final Future<String> _url = AppScope.read(context).alertPhotoUrl(widget.path);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: FutureBuilder<String>(
        future: _url,
        builder: (context, snap) {
          if (snap.hasError) {
            return FootNote(tr('The photo couldn\'t be loaded. Photos are deleted after 7 days.'), icon: Icons.hide_image_outlined);
          }
          if (!snap.hasData) return const Skeleton(height: 200, radius: DL.rCard);
          final url = snap.data!;
          return Pressable(
            child: GestureDetector(
              onTap: () => Navigator.of(context).push(PageRouteBuilder(
                opaque: false,
                barrierColor: DL.ink,
                transitionDuration: DL.medium,
                reverseTransitionDuration: DL.medium,
                pageBuilder: (_, a, _) => FadeTransition(
                  opacity: a,
                  child: Scaffold(
                    backgroundColor: DL.ink,
                    appBar: AppBar(backgroundColor: DL.ink, iconTheme: const IconThemeData(color: DL.onDark)),
                    body: InteractiveViewer(
                      maxScale: 5,
                      child: Center(child: Hero(tag: url, child: Image.network(url))),
                    ),
                  ),
                ),
              )),
              child: Hero(
                tag: url,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(DL.rCard),
                  child: Image.network(
                    url,
                    height: 200,
                    width: double.infinity,
                    fit: BoxFit.cover,
                    frameBuilder: (_, child, frame, sync) => sync
                        ? child
                        : AnimatedOpacity(opacity: frame == null ? 0 : 1, duration: DL.medium, curve: DL.ease, child: child),
                    errorBuilder: (_, _, _) =>
                        FootNote(tr('The photo couldn\'t be loaded. Photos are deleted after 7 days.'), icon: Icons.hide_image_outlined),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({super.key, required this.text, required this.mine, this.animate = false});
  final String text;
  final bool mine;

  /// A message that arrived while the thread was open slides in from its side.
  final bool animate;

  @override
  Widget build(BuildContext context) {
    final bubble = _bubble(context);
    if (!animate || reduceMotion(context)) return bubble;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: DL.medium,
      curve: DL.ease,
      child: bubble,
      builder: (_, t, child) => Opacity(
        opacity: t,
        child: Transform.translate(offset: Offset((mine ? 12 : -12) * (1 - t), 6 * (1 - t)), child: child),
      ),
    );
  }

  Widget _bubble(BuildContext context) {
    // Your replies sit on ink rather than violet: violet is reserved for things you can tap.
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.78),
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: mine ? DL.ink : DL.card,
          border: mine ? null : Border.all(color: DL.line),
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(DL.rCard),
            topRight: const Radius.circular(DL.rCard),
            bottomLeft: Radius.circular(mine ? DL.rCard : 4),
            bottomRight: Radius.circular(mine ? 4 : DL.rCard),
          ),
        ),
        child: mine
            ? Text(text, style: DLText.body.copyWith(height: 1.45, color: DL.onDark))
            : _Translatable(text: text),
      ),
    );
  }
}

/// A stranger's message with an on-device "Translate" action: detects the
/// language and translates into the app's language without leaving the phone.
class _Translatable extends StatefulWidget {
  const _Translatable({required this.text});
  final String text;

  @override
  State<_Translatable> createState() => _TranslatableState();
}

class _TranslatableState extends State<_Translatable> {
  String? _translated;
  bool _busy = false;
  bool _failed = false;

  Future<void> _translate() async {
    setState(() {
      _busy = true;
      _failed = false;
    });
    try {
      final r = await translateTo(widget.text, L10n.lang.value);
      if (!mounted) return;
      setState(() {
        _busy = false;
        _translated = r == null || r.same ? null : r.text;
        _failed = r == null;
        if (r != null && r.same) _failed = false;
      });
      if (r != null && r.same && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('Already in your language.'))));
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _busy = false;
          _failed = true;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      Text(widget.text, style: DLText.body.copyWith(height: 1.45, color: DL.ink)),
      if (_translated != null) ...[
        const SizedBox(height: 6),
        Text(_translated!, style: DLText.body.copyWith(height: 1.45, color: DL.violet, fontWeight: FontWeight.w600)),
      ],
      const SizedBox(height: 4),
      InkWell(
        onTap: _busy ? null : _translate,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Text(
            _busy ? tr('Translating…') : _failed ? tr('Couldn\'t translate. Tap to retry.') : _translated != null ? tr('Translated on this phone') : tr('Translate'),
            style: DLText.small.copyWith(color: DL.muted, decoration: _translated == null ? TextDecoration.underline : null),
          ),
        ),
      ),
    ]);
  }
}
