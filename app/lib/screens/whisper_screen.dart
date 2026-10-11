import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../data/models.dart';
import '../l10n.dart';
import '../main.dart';
import '../services/acoustic_modem.dart';
import '../services/ble_link.dart';
import '../services/ble_relay.dart';
import '../services/notifications.dart';
import '../services/plate_reader.dart';
import '../services/sound_link.dart';
import '../services/whisper.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/motion.dart';
import 'sound_check_screen.dart';

enum _Sent { nothing, sending, owner, carried, delivered, unknownCar, nobody }

/// Reaching a car's owner where there is no signal. The phone says which car
/// and what is wrong as two seconds of sound; any Connect phone in earshot
/// answers. The owner's phone shows it at once. Anyone else's keeps it and
/// hands it to the server when it is back online, and so does this phone.
///
/// While this screen is open the phone also listens, so it is a sender and a
/// carrier at once.
class WhisperScreen extends StatefulWidget {
  const WhisperScreen({super.key, this.plate});

  /// A plate already read or typed elsewhere (the plate screen, offline).
  final String? plate;

  @override
  State<WhisperScreen> createState() => _WhisperScreenState();
}

class _WhisperScreenState extends State<WhisperScreen> {
  final _link = SoundLink();
  late final _plate = TextEditingController(text: widget.plate);
  late final AppLifecycleListener _life;
  StreamSubscription<HeardFrame>? _frames;
  StreamSubscription<SoundLevel>? _levels;

  AlertKind _kind = AlertKind.blocking;
  bool _wanted = true; // the listening switch
  bool _bleWanted = true; // the Bluetooth switch
  bool _bleFailed = false;
  bool _micDenied = false;
  bool _audibleToo = true;
  bool _reading = false;
  String? _plateError;
  SoundLevel _level = SoundLevel.silent;
  DateTime _levelAt = DateTime.fromMillisecondsSinceEpoch(0);

  _Sent _sent = _Sent.nothing;
  int _try = 0, _tries = 0;
  Completer<WhisperAck?>? _answer;
  int? _answerFor;

  /// A listener answers within about three seconds of a frame ending: half a
  /// second to notice it, a pause so two listeners rarely collide, and a
  /// second for the answer itself.
  static const _patience = Duration(seconds: 4);

  @override
  void initState() {
    super.initState();
    _frames = _link.frames.listen(_onFrame);
    _levels = _link.levels.listen(_onLevel);
    // Android silences the microphone of an app that is not on screen.
    _life = AppLifecycleListener(onPause: _link.stopListening, onResume: _listenIfWanted);
    _listenIfWanted();
    _bleIfWanted();
  }

  @override
  void dispose() {
    unawaited(BleLink.instance.stop());
    _life.dispose();
    _frames?.cancel();
    _levels?.cancel();
    _plate.dispose();
    _link.dispose();
    super.dispose();
  }

  /// Bluetooth is asked for here, not at app launch, and runs only while this
  /// screen is open, like the microphone.
  Future<void> _bleIfWanted() async {
    if (!_bleWanted || BleLink.instance.isOn) return;
    final scope = context.getInheritedWidgetOfExactType<AppScope>();
    if (scope == null) return; // no app state to hand whispers to
    final ok = await BleRelay.start(scope.notifier!);
    if (mounted) setState(() => _bleFailed = !ok);
  }

  Future<void> _listenIfWanted() async {
    if (!_wanted || _link.listening) return;
    try {
      if (!await _link.hasMic()) {
        if (mounted) setState(() => _micDenied = true);
        return;
      }
      await _link.listen();
      if (mounted) setState(() => _micDenied = false);
    } catch (e) {
      debugPrint('listen failed: $e');
      if (mounted) setState(() => _micDenied = true);
    }
  }

  void _onLevel(SoundLevel l) {
    final now = DateTime.now();
    if (!mounted || now.difference(_levelAt).inMilliseconds < 90) return;
    _levelAt = now;
    setState(() => _level = l);
  }

  void _onFrame(HeardFrame f) {
    final ack = WhisperAck.decode(f.payload);
    if (ack != null) {
      if (ack.nonce == _answerFor && !(_answer?.isCompleted ?? true)) _answer!.complete(ack);
      return;
    }
    final w = Whisper.decode(f.payload);
    if (w != null) _onWhisper(w, f.profile);
  }

  Future<void> _onWhisper(Whisper w, ModemProfile profile) async {
    final s = AppScope.read(context);
    final car = s.vehicles.where((v) => v.regNumber == w.plate).firstOrNull;
    if (await WhisperStore.add(w, mine: car != null)) {
      HapticFeedback.heavyImpact();
      // With a signal on both phones the same alert may already have arrived through the
      // server, with its own notification; one buzz for one message.
      final already = car != null &&
          s.alerts.any((a) => a.vehicleId == car.id && a.kind == w.kind && DateTime.now().difference(a.createdAt).inMinutes < 2);
      if (car != null && !already) Notifications.showWhisper(w.kind, car, w.nonce);
      unawaited(WhisperStore.flush(s.deliverWhisper));
    }
    // Answer every time, even a repeat: the sender repeats because it missed
    // the last answer. The random pause keeps two listeners from answering on
    // top of each other.
    await Future<void>.delayed(Duration(milliseconds: 150 + Random().nextInt(450)));
    if (!mounted) return;
    try {
      await _link.send(WhisperAck(w.nonce, owner: car != null).encode(), profile);
    } catch (e) {
      debugPrint('answer failed: $e');
    }
  }

  Future<void> _readPlate() async {
    final shot = await ImagePicker().pickImage(source: ImageSource.camera, maxWidth: 1600, imageQuality: 85);
    if (shot == null || !mounted) return;
    setState(() => _reading = true);
    try {
      final plates = (await readPlatesInPhoto(File(shot.path))).plates;
      if (!mounted) return;
      setState(() {
        if (plates.isNotEmpty) _plate.text = plates.first;
        _plateError = plates.isEmpty ? tr('No number plate found in that photo. Try again closer, or type it below.') : null;
      });
    } catch (e) {
      if (mounted) setState(() => _plateError = tr('Couldn\'t read that photo. Type the plate below.'));
    } finally {
      if (mounted) setState(() => _reading = false);
    }
  }

  Future<void> _send() async {
    final plate = _plate.text.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
    if (!Whisper.validPlate(plate)) {
      setState(() => _plateError = tr('Enter the full number plate.'));
      return;
    }
    final s = AppScope.read(context);
    final w = Whisper(plate: plate, kind: _kind, nonce: Random.secure().nextInt(0x10000), lang: L10n.lang.value);
    // This phone carries its own message too: whoever gets a signal first delivers it.
    await WhisperStore.add(w, mine: false, own: true);
    unawaited(WhisperStore.flush(s.deliverWhisper));
    await _listenIfWanted();
    if (!mounted) return;
    final plan = [ModemProfile.ultrasonic, ModemProfile.ultrasonic, if (_audibleToo) ModemProfile.audible];
    setState(() {
      _plateError = null;
      _sent = _Sent.sending;
      _tries = plan.length;
    });
    WhisperAck? ack;
    try {
      for (var i = 0; i < plan.length && ack == null && mounted; i++) {
        setState(() => _try = i + 1);
        _answerFor = w.nonce;
        final answer = _answer = Completer<WhisperAck?>();
        await _link.send(w.encode(), plan[i]);
        ack = await answer.future.timeout(_patience, onTimeout: () => null);
      }
    } catch (e) {
      debugPrint('send failed: $e');
    }
    _answerFor = null;
    if (!mounted) return;
    // With no answer by sound, what this phone itself managed over the internet is the news.
    final mine = WhisperStore.heard.value.where((h) => h.whisper == w).firstOrNull?.state;
    setState(() {
      _sent = ack != null
          ? (ack.owner ? _Sent.owner : _Sent.carried)
          : switch (mine) {
              WhisperState.delivered => _Sent.delivered,
              WhisperState.unknownCar => _Sent.unknownCar,
              _ => _Sent.nobody,
            };
    });
    if (ack != null) HapticFeedback.mediumImpact();
  }

  @override
  Widget build(BuildContext context) {
    final sending = _sent == _Sent.sending;
    return Scaffold(
      appBar: AppBar(
        title: Text(tr('Say it with sound')),
        actions: [
          IconButton(
            tooltip: tr('Test this phone'),
            icon: const Icon(Icons.speaker_phone_outlined),
            onPressed: sending ? null : () => push(context, const SoundCheckScreen()),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(padding: const EdgeInsets.fromLTRB(20, 8, 20, 32), children: revealAll([
          ScreenTitle(tr('No signal? Say it with sound'), eyebrow: tr('No internet needed')),
          const SizedBox(height: 8),
          Text(
            tr('Your phone says which car and what is wrong as two seconds of sound. The owner\'s phone shows it at once if it is in earshot. Any other Connect phone carries it out and delivers it when it is back online.'),
            style: DLText.body.copyWith(color: DL.muted),
          ),
          const SizedBox(height: 20),
          SectionCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              FieldLabel(tr('Number plate')),
              TextField(
                controller: _plate,
                enabled: !sending,
                textCapitalization: TextCapitalization.characters,
                maxLength: 13,
                onChanged: (_) => setState(() {
                  _plateError = null;
                  _sent = _Sent.nothing;
                }),
                decoration: InputDecoration(
                  hintText: tr('e.g. KA01AB1234'),
                  errorText: _plateError,
                  errorMaxLines: 3,
                  suffixIcon: IconButton(
                    tooltip: tr('Read the plate with the camera'),
                    onPressed: sending || _reading ? null : _readPlate,
                    icon: _reading
                        ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.photo_camera_outlined),
                  ),
                ),
              ),
              FieldLabel(tr('What is wrong')),
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (final k in AlertKind.values)
                  ChoiceChip(
                    label: Text(tr(k.label)),
                    selected: _kind == k,
                    onSelected: sending ? null : (_) => setState(() => _kind = k),
                  ),
              ]),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: sending ? null : _send,
                icon: const Icon(Icons.graphic_eq),
                label: Text(sending ? tr('Sending, try {n} of {total}…', {'n': _try, 'total': _tries}) : tr('Send by sound')),
              ),
              Swap(
                child: switch (_sent) {
                  _Sent.owner => _Outcome(Icons.check_circle_outline, Tone.success, tr('The owner\'s phone heard it.'), key: const ValueKey('owner')),
                  _Sent.carried => _Outcome(Icons.directions_walk, Tone.success, tr('A phone nearby heard it and will deliver it.'), key: const ValueKey('carried')),
                  _Sent.delivered => _Outcome(Icons.cloud_done_outlined, Tone.success,
                      tr('Nobody nearby answered by sound, but this phone has a signal and has delivered it.'), key: const ValueKey('delivered')),
                  _Sent.unknownCar => _Outcome(Icons.info_outline, Tone.neutral,
                      tr('That car isn\'t on Connect yet. Nothing was sent and nobody was told.'), key: const ValueKey('unknown')),
                  _Sent.nobody => _Outcome(Icons.schedule, Tone.warning,
                      tr('Nobody nearby answered. This phone will deliver it as soon as it has a signal.'), key: const ValueKey('nobody')),
                  _ => const SizedBox(key: ValueKey('none'), width: double.infinity),
                },
              ),
            ]),
          ),
          const SizedBox(height: 12),
          SectionCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                PulseDot(color: _link.listening ? DL.success : DL.muted, pulse: _link.listening),
                const SizedBox(width: 10),
                Expanded(child: Text(_link.listening ? tr('Listening for phones nearby') : tr('Not listening'), style: DLText.strong)),
                Switch(
                  value: _wanted,
                  onChanged: sending
                      ? null
                      : (on) async {
                          setState(() => _wanted = on);
                          on ? await _listenIfWanted() : await _link.stopListening();
                          if (mounted) setState(() {});
                        },
                ),
              ]),
              if (_micDenied) ...[
                const SizedBox(height: 8),
                Text(tr('Allow the microphone so this phone can hear others.'), style: DLText.small.copyWith(color: DL.error)),
              ] else ...[
                const SizedBox(height: 10),
                _Meter(tr('Silent band'), _link.listening ? _level.ultrasonic : 0),
                const SizedBox(height: 8),
                _Meter(tr('Audible band'), _link.listening ? _level.audible : 0),
              ],
              const SizedBox(height: 4),
              Row(children: [
                Expanded(child: Text(tr('Fall back to audible tones when silence gets no answer'), style: DLText.small)),
                Switch(value: _audibleToo, onChanged: sending ? null : (on) => setState(() => _audibleToo = on)),
              ]),
            ]),
          ),
          const SizedBox(height: 12),
          SectionCard(
            child: ValueListenableBuilder<bool>(
              valueListenable: BleLink.instance.running,
              builder: (context, on, _) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Row(children: [
                  PulseDot(color: on ? DL.success : DL.muted, pulse: on),
                  const SizedBox(width: 10),
                  Expanded(child: Text(on ? tr('Bluetooth relay on') : tr('Bluetooth relay off'), style: DLText.strong)),
                  Switch(
                    value: _bleWanted,
                    onChanged: sending
                        ? null
                        : (v) async {
                            setState(() {
                              _bleWanted = v;
                              _bleFailed = false;
                            });
                            v ? await _bleIfWanted() : await BleLink.instance.stop();
                            if (mounted) setState(() {});
                          },
                  ),
                ]),
                const SizedBox(height: 8),
                if (_bleFailed)
                  Text(tr('Allow Bluetooth and turn it on so this phone can pass messages along.'), style: DLText.small.copyWith(color: DL.error))
                else
                  ValueListenableBuilder<int>(
                    valueListenable: BleLink.instance.heard,
                    builder: (context, n, _) => Text(
                      on ? tr('Heard {n} from phones nearby. It reaches further than sound, and carried messages are repeated until someone delivers them.', {'n': n}) : tr('Off. Turn on to hand messages to phones nearby without internet.'),
                      style: DLText.small,
                    ),
                  ),
              ]),
            ),
          ),
          const SizedBox(height: 32),
          Label(tr('Heard and carried')),
          const SizedBox(height: 12),
          ValueListenableBuilder<List<HeardWhisper>>(
            valueListenable: WhisperStore.heard,
            builder: (context, heard, _) => heard.isEmpty
                ? SectionCard(
                    child: Text(tr('Nothing yet. Messages this phone hears or sends by sound show up here.'), style: DLText.body.copyWith(color: DL.muted)),
                  )
                : Column(children: [
                    for (final h in heard.take(8)) ...[_HeardRow(h), const SizedBox(height: 8)],
                  ]),
          ),
          const SizedBox(height: 16),
          FootNote(tr('Only the plate and the reason travel through the air. Sound reaches a few metres, and this phone listens only while this screen is open.')),
        ])),
      ),
    );
  }
}

class _Outcome extends StatelessWidget {
  const _Outcome(this.icon, this.tone, this.text, {super.key});
  final IconData icon;
  final Tone tone;
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 14),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, size: 20, color: tone.mark),
          const SizedBox(width: 10),
          Expanded(child: Text(text, style: DLText.strong.copyWith(color: tone.fg))),
        ]),
      );
}

/// One band's loudness: a label and a bar that follows the microphone.
class _Meter extends StatelessWidget {
  const _Meter(this.label, this.value);
  final String label;
  final double value;

  @override
  Widget build(BuildContext context) => Row(children: [
        SizedBox(width: 108, child: Text(label, style: DLText.small, maxLines: 1, overflow: TextOverflow.ellipsis)),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: SizedBox(
              height: 6,
              child: Stack(fit: StackFit.expand, children: [
                const ColoredBox(color: DL.ground),
                AnimatedFractionallySizedBox(
                  duration: DL.fast,
                  alignment: Alignment.centerLeft,
                  widthFactor: value.clamp(0.0, 1.0),
                  child: const ColoredBox(color: DL.violet),
                ),
              ]),
            ),
          ),
        ),
      ]);
}

class _HeardRow extends StatelessWidget {
  const _HeardRow(this.h);
  final HeardWhisper h;

  @override
  Widget build(BuildContext context) {
    final (label, tone) = switch (h.state) {
      WhisperState.delivered => (tr('Delivered'), Tone.success),
      WhisperState.unknownCar => (tr('Not on Connect'), Tone.neutral),
      WhisperState.carrying => (tr('Carrying'), Tone.warning),
    };
    final who = h.own ? tr('Sent by you') : (h.mine ? tr('About your car') : tr('Heard nearby'));
    return SectionCard(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(children: [
        IconBadge(h.whisper.kind.icon, tone: h.mine || h.whisper.kind.urgent ? Tone.error : Tone.info, size: 40),
        const SizedBox(width: 14),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(tr(h.whisper.kind.label), style: DLText.strong),
            const SizedBox(height: 2),
            Text('${h.whisper.plate} · $who · ${timeAgo(h.at)}', style: DLText.small, maxLines: 2, overflow: TextOverflow.ellipsis),
          ]),
        ),
        const SizedBox(width: 8),
        StatusBadge(label, tone: tone),
      ]),
    );
  }
}
