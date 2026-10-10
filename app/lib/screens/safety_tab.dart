import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/models.dart';
import '../config.dart';
import '../l10n.dart';
import '../main.dart';
import '../services/crash_detector.dart';
import '../services/trip_share.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/motion.dart';
import 'medical_screen.dart';
import 'witness_screen.dart';

class SafetyTab extends StatelessWidget {
  const SafetyTab({super.key});

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final v = s.vehicle!;
    return SafeArea(
      child: ListView(padding: const EdgeInsets.fromLTRB(20, 20, 20, 32), children: revealAll([
        ScreenTitle(tr('Safety'), eyebrow: tr('On the road')),
        const SizedBox(height: 24),

        SectionCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const IconBadge(Icons.sensors_outlined),
              const SizedBox(width: 14),
              Expanded(child: Text(tr('Drive Mode'), style: DLText.section)),
            ]),
            const SizedBox(height: 12),
            Text(
              tr('Keep the app open on your phone mount. If your phone feels a crash-level impact, you get 15 seconds to cancel before your emergency contacts are messaged with your location.'),
              style: DLText.body.copyWith(color: DL.muted),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                icon: const Icon(Icons.play_arrow_outlined),
                label: Text(tr('Start Drive Mode')),
                onPressed: s.contacts.isEmpty ? null : () => push(context, const DriveModeScreen()),
              ),
            ),
            if (s.contacts.isEmpty) ...[
              const SizedBox(height: 10),
              Text(tr('Add an emergency contact below first.'), style: DLText.small),
            ],
          ]),
        ),
        const SizedBox(height: 12),
        InfoRow(
          icon: Icons.videocam_outlined,
          title: tr('Witness mode'),
          subtitle: tr('Parked? Leave a phone watching. It writes down the plates around a bump.'),
          onTap: () => push(context, const WitnessScreen()),
        ),
        const SizedBox(height: 12),

        IntrinsicHeight(
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Expanded(
              child: _EmergencyTile(
                tone: Tone.error,
                icon: Icons.call_outlined,
                label: tr('Call 112'),
                caption: tr('Police, fire, ambulance'),
                onTap: () => launchUrl(Uri.parse('tel:112')),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _EmergencyTile(
                icon: Icons.sms_outlined,
                label: tr('Send SOS'),
                caption: s.contacts.isEmpty ? tr('Add a contact first') : tr('Text your location'),
                onTap: s.contacts.isEmpty ? null : () => sendSos(context, s.contacts),
              ),
            ),
          ]),
        ),
        const SizedBox(height: 32),

        Label(tr('Share with family')),
        const SizedBox(height: 12),
        const TripCard(),
        const SizedBox(height: 12),
        InfoRow(
          icon: Icons.medical_information_outlined,
          tone: v.medicalShare && v.hasMedical ? Tone.success : null,
          title: tr('Medical info'),
          subtitle: v.medicalShare && v.hasMedical
              ? [if (v.bloodGroup != null) tr('Blood group {g}', {'g': v.bloodGroup}), tr('shown on accident reports')].join(' · ')
              : tr('Blood group and allergies, shown only if someone reports an accident'),
          onTap: () => push(context, const MedicalInfoScreen()),
        ),
        const SizedBox(height: 32),

        Row(children: [
          Expanded(child: Label(tr('Emergency contacts'))),
          TextButton.icon(
            icon: const Icon(Icons.add),
            label: Text(tr('Add')),
            onPressed: s.contacts.length >= 5 ? null : () => _addContact(context),
          ),
        ]),
        const SizedBox(height: 4),
        Swap(
          child: s.contacts.isEmpty
              ? Text(tr('Family or friends who should know if something happens on the road. Up to 5.'),
                  key: const ValueKey('none'), style: DLText.body.copyWith(color: DL.muted))
              : Card(
                  key: const ValueKey('list'),
                  clipBehavior: Clip.antiAlias,
                  child: AnimatedSize(
                    duration: DL.medium,
                    curve: DL.ease,
                    alignment: Alignment.topCenter,
                    child: Column(children: [
                      for (var i = 0; i < s.contacts.length; i++) ...[
                        if (i > 0) const Divider(),
                        ListTile(
                          key: ValueKey(s.contacts[i].id),
                          leading: CircleAvatar(
                            backgroundColor: DL.ground,
                            foregroundColor: DL.ink,
                            child: Text(s.contacts[i].name.characters.first.toUpperCase(), style: DLText.strong),
                          ),
                          title: Text(s.contacts[i].name),
                          subtitle: Text(s.contacts[i].phone, style: DLText.small),
                          trailing: IconButton(
                            icon: const Icon(Icons.delete_outline, color: DL.muted),
                            tooltip: tr('Remove'),
                            onPressed: () => s.removeContact(s.contacts[i].id),
                          ),
                        ),
                      ],
                    ]),
                  ),
                ),
        ),
      ])),
    );
  }

  Future<void> _addContact(BuildContext context) async {
    final name = TextEditingController();
    final phone = TextEditingController();
    final key = GlobalKey<FormState>();
    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (c) => Padding(
        padding: EdgeInsets.fromLTRB(20, 0, 20, MediaQuery.of(c).viewInsets.bottom + 24),
        child: Form(
          key: key,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(tr('Add emergency contact'), style: DLText.title),
            const SizedBox(height: 20),
            FieldLabel(tr('Name')),
            TextFormField(
              controller: name,
              autofocus: true,
              textCapitalization: TextCapitalization.words,
              decoration: InputDecoration(hintText: tr('Name, e.g. Mom')),
              validator: (v) => (v ?? '').trim().isEmpty ? tr('Enter a name') : null,
            ),
            const SizedBox(height: 16),
            FieldLabel(tr('Mobile number')),
            TextFormField(
              controller: phone,
              keyboardType: TextInputType.phone,
              inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9+]'))],
              decoration: InputDecoration(hintText: tr('Mobile number'), prefixText: '+91 '),
              validator: (v) => RegExp(r'^\d{10}$').hasMatch((v ?? '').replaceFirst(RegExp(r'^\+?91'), ''))
                  ? null
                  : tr('Enter a 10-digit mobile number'),
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: () {
                if (key.currentState!.validate()) Navigator.pop(c, true);
              },
              child: Text(tr('Save')),
            ),
          ]),
        ),
      ),
    );
    if (ok == true && context.mounted) {
      final digits = phone.text.replaceFirst(RegExp(r'^\+?91'), '');
      try {
        await AppScope.read(context).addContact(name.text.trim(), '+91$digits');
      } catch (e) {
        if (context.mounted) showError(context, e);
      }
    }
  }
}

/// Emergency action tile. Error-tinted for 112 (a text-on-tint pair, not a
/// saturated fill); plain card with a violet icon otherwise.
class _EmergencyTile extends StatelessWidget {
  const _EmergencyTile({required this.icon, required this.label, required this.caption, required this.onTap, this.tone});
  final IconData icon;
  final String label;
  final String caption;
  final VoidCallback? onTap;
  final Tone? tone;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    final fg = tone?.fg ?? (enabled ? DL.violet : DL.muted);
    return Pressable(
      enabled: enabled,
      child: Card(
      color: tone?.bg,
      shape: tone == null ? null : const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(DL.rCard))),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(icon, color: fg, size: 26),
            const SizedBox(height: 14),
            Text(label, style: DLText.section.copyWith(color: tone?.fg ?? (enabled ? DL.ink : DL.muted))),
            const SizedBox(height: 2),
            Text(caption, style: DLText.small.copyWith(color: tone?.fg ?? DL.muted)),
          ]),
        ),
      ),
      ),
    );
  }
}

/// Opens the SMS app with every contact and a location link filled in.
/// Sending SMS silently would need the SEND_SMS permission, which Google Play
/// only grants to default SMS apps, so the user (or a bystander) taps send.
Future<void> sendSos(BuildContext context, List<EmergencyContact> contacts, {bool crash = false}) async {
  final vehicle = AppScope.read(context).vehicle;
  String location = tr('Location unavailable');
  try {
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
    if (perm == LocationPermission.always || perm == LocationPermission.whileInUse) {
      final p = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, timeLimit: Duration(seconds: 8)),
      );
      location = 'https://maps.google.com/?q=${p.latitude.toStringAsFixed(6)},${p.longitude.toStringAsFixed(6)}';
    }
  } catch (_) {}

  final car = vehicle == null ? '' : '${vehicle.make} ${vehicle.model} (${vehicle.prettyReg})';
  final body = switch ((crash, vehicle == null)) {
    (true, false) => tr('EMERGENCY: Connect detected a possible crash in {car}. Please call now. Location: {loc}', {'car': car, 'loc': location}),
    (true, true) => tr('EMERGENCY: Connect detected a possible crash. Please call now. Location: {loc}', {'loc': location}),
    (false, false) => tr('SOS: I need help in {car}. Location: {loc}', {'car': car, 'loc': location}),
    (false, true) => tr('SOS: I need help. Location: {loc}', {'loc': location}),
  };
  final recipients = contacts.map((c) => c.phone).join(defaultTargetPlatform == TargetPlatform.iOS ? ',' : ';');
  final uri = Uri.parse('sms:$recipients?body=${Uri.encodeComponent(body)}');
  if (!await launchUrl(uri) && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('Couldn\'t open your messages app.'))));
  }
}

class DriveModeScreen extends StatefulWidget {
  const DriveModeScreen({super.key});

  @override
  State<DriveModeScreen> createState() => _DriveModeScreenState();
}

class _DriveModeScreenState extends State<DriveModeScreen> with SingleTickerProviderStateMixin {
  late final CrashDetector _detector = CrashDetector(onSuspectedCrash: _onCrash);

  /// Drains the ring continuously over the 15 s; the numeral ticks per second.
  late final _ring = AnimationController(vsync: this, duration: const Duration(seconds: 15));
  Timer? _countdown;
  int _secondsLeft = 0;
  bool _sent = false;
  bool _test = false;

  @override
  void initState() {
    super.initState();
    _detector.start();
  }

  @override
  void dispose() {
    _detector.stop();
    _countdown?.cancel();
    _ring.dispose();
    super.dispose();
  }

  void _onCrash(double g, {bool test = false}) {
    if (_countdown != null || !mounted) return;
    _test = test;
    HapticFeedback.heavyImpact();
    setState(() {
      _secondsLeft = 15;
      _sent = false;
    });
    _ring.value = 1;
    _ring.animateTo(0, duration: const Duration(seconds: 15), curve: Curves.linear);
    _countdown = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) return timer.cancel();
      HapticFeedback.mediumImpact();
      setState(() => _secondsLeft--);
      if (_secondsLeft <= 0) {
        timer.cancel();
        _countdown = null;
        setState(() => _sent = true);
        if (!_test) sendSos(context, AppScope.read(context).contacts, crash: true);
      }
    });
  }

  void _cancel() {
    _countdown?.cancel();
    _ring.stop();
    setState(() {
      _countdown = null;
      _secondsLeft = 0;
    });
  }

  @override
  Widget build(BuildContext context) {
    final counting = _countdown != null;
    // Inverted ink screen: readable on a dashboard mount, one amber element (the countdown ring).
    return Scaffold(
      backgroundColor: DL.ink,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(children: [
            Row(children: [
              PulseDot(color: counting ? DL.amber : DL.onDark, pulse: true),
              const SizedBox(width: 10),
              Label(tr('Drive Mode on'), color: DL.onDarkMuted),
              const Spacer(),
              if (!counting)
                TextButton(
                  style: TextButton.styleFrom(foregroundColor: DL.onDark),
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(tr('Stop')),
                ),
            ]),
            const Spacer(),
            Swap(
              alignment: Alignment.center,
              child: counting ? _countdownView(key: const ValueKey('count')) : _watchingView(key: ValueKey('watch-$_sent')),
            ),
            const Spacer(),
            Swap(
              alignment: Alignment.bottomCenter,
              child: counting
                  ? SizedBox(
                      key: const ValueKey('cancel'),
                      width: double.infinity,
                      height: 72,
                      child: FilledButton(
                        style: ButtonStyle(
                          backgroundColor: const WidgetStatePropertyAll(DL.card),
                          foregroundColor: const WidgetStatePropertyAll(DL.ink),
                          textStyle: WidgetStatePropertyAll(DLText.section.copyWith(fontSize: 20, fontWeight: FontWeight.w700)),
                        ),
                        onPressed: _cancel,
                        child: Text(tr('I\'m OK, cancel')),
                      ),
                    )
                  : SizedBox(
                      key: const ValueKey('test'),
                      width: double.infinity,
                      child: OutlinedButton(
                        style: const ButtonStyle(
                          backgroundColor: WidgetStatePropertyAll(Colors.transparent),
                          foregroundColor: WidgetStatePropertyAll(DL.onDark),
                          side: WidgetStatePropertyAll(BorderSide(color: DL.muted)),
                        ),
                        onPressed: () => _onCrash(0, test: true),
                        child: Text(tr('Test the countdown (nothing is sent)')),
                      ),
                    ),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _countdownView({Key? key}) => Column(key: key, mainAxisSize: MainAxisSize.min, children: [
        Text(tr('Crash detected?'), style: DLText.title.copyWith(color: DL.onDark)),
        const SizedBox(height: 28),
        SizedBox.square(
          dimension: 200,
          child: Stack(alignment: Alignment.center, children: [
            SizedBox.expand(
              child: AnimatedBuilder(
                animation: _ring,
                builder: (_, _) => CircularProgressIndicator(
                  value: _ring.value,
                  strokeWidth: 6,
                  strokeCap: StrokeCap.butt,
                  color: DL.amber,
                  backgroundColor: DL.muted,
                ),
              ),
            ),
            AnimatedSwitcher(
              duration: DL.fast,
              transitionBuilder: (child, a) => FadeTransition(
                opacity: a,
                child: SlideTransition(position: Tween(begin: const Offset(0, 0.15), end: Offset.zero).animate(a), child: child),
              ),
              child: Text('$_secondsLeft', key: ValueKey(_secondsLeft), style: DLText.display.copyWith(fontSize: 88, color: DL.onDark)),
            ),
          ]),
        ),
        const SizedBox(height: 24),
        Text(_test ? tr('Test: nothing will be sent') : tr('Alerting your emergency contacts'),
            style: DLText.body.copyWith(color: DL.onDarkMuted)),
      ]);

  Widget _watchingView({Key? key}) => Column(key: key, mainAxisSize: MainAxisSize.min, children: [
        if (_sent) const DrawCheck(size: 88, tone: Tone.success) else const _Radar(),
        const SizedBox(height: 24),
        Text(_sent ? (_test ? tr('Test complete') : tr('Emergency message opened')) : tr('Watching for crashes'),
            textAlign: TextAlign.center, style: DLText.title.copyWith(color: DL.onDark)),
        const SizedBox(height: 10),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Text(
            _sent && _test
                ? tr('In a real crash your contacts would now get a message with your location.')
                : tr('Keep this screen open while you drive.'),
            style: DLText.body.copyWith(color: DL.onDarkMuted),
            textAlign: TextAlign.center,
          ),
        ),
      ]);
}

/// The shield with a slow ring spreading from it: Drive Mode is listening.
class _Radar extends StatefulWidget {
  const _Radar();

  @override
  State<_Radar> createState() => _RadarState();
}

class _RadarState extends State<_Radar> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 2400))..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const icon = Icon(Icons.shield_outlined, color: DL.onDark, size: 88);
    if (reduceMotion(context)) return const SizedBox.square(dimension: 140, child: Center(child: icon));
    return SizedBox.square(
      dimension: 140,
      child: AnimatedBuilder(
        animation: _c,
        builder: (_, child) {
          final t = DL.ease.transform(_c.value);
          return Stack(alignment: Alignment.center, children: [
            Container(
              width: 88 + 52 * t,
              height: 88 + 52 * t,
              decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: DL.onDarkMuted.withValues(alpha: 0.5 * (1 - t)), width: 1.5)),
            ),
            child!,
          ]);
        },
        child: icon,
      ),
    );
  }
}



/// Live trip sharing: start, share the link, watch it tick, stop.
class TripCard extends StatelessWidget {
  const TripCard({super.key});

  static Future<void> shareLink(ActiveTrip t, String car) => SharePlus.instance.share(ShareParams(
        text: tr('Follow my drive live until {time}: {url}', {'time': DateFormat.jm().format(t.endsAt), 'url': Config.tripUrl(t.token)}),
        subject: tr('Live location: {car}', {'car': car}),
      ));

  Future<void> _start(BuildContext context) async {
    final hours = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (c) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(tr('Share a live trip'), style: DLText.title),
          const SizedBox(height: 8),
          Text(
            tr('Anyone with the link sees where you are and the route so far, updated every 15 seconds. It stops by itself.'),
            style: DLText.body.copyWith(color: DL.muted, height: 1.5),
          ),
          const SizedBox(height: 20),
          Label(tr('Share for')),
          const SizedBox(height: 10),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final h in const [1, 2, 4, 8, 12])
              ActionChip(label: Text(tr('{n} h', {'n': h})), onPressed: () => Navigator.pop(c, h)),
          ]),
        ]),
      ),
    );
    if (hours == null || !context.mounted) return;
    final s = AppScope.read(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final t = await TripShare.start(s, hours);
      await shareLink(t, s.vehicle?.title ?? '');
    } on LocationUnavailable {
      messenger.showSnackBar(SnackBar(content: Text(tr('Turn on location and allow Connect to use it to share a trip.'))));
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ActiveTrip?>(
      valueListenable: TripShare.active,
      builder: (context, t, _) => Swap(
        child: t == null
            ? InfoRow(
                key: const ValueKey('idle'),
                icon: Icons.share_location_outlined,
                title: tr('Share a live trip'),
                subtitle: tr('Family follows your drive on a link. No app needed.'),
                onTap: () => _start(context),
              )
            : _LiveTrip(key: const ValueKey('live'), trip: t),
      ),
    );
  }
}

class _LiveTrip extends StatelessWidget {
  const _LiveTrip({super.key, required this.trip});
  final ActiveTrip trip;

  @override
  Widget build(BuildContext context) {
    final sent = trip.sentAt;
    return SectionCard(
      selected: true,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const PulseDot(),
          const SizedBox(width: 10),
          Expanded(child: Text(tr('Sharing your trip'), style: DLText.section.copyWith(color: DL.violetDeep))),
          StatusBadge(tr('Until {time}', {'time': DateFormat.jm().format(trip.endsAt)}), tone: Tone.info),
        ]),
        const SizedBox(height: 8),
        Text(
          sent == null ? tr('Waiting for the first GPS fix…') : tr('Location sent {ago}', {'ago': timeAgo(sent)}),
          style: DLText.small.copyWith(color: DL.violetDeep),
        ),
        const SizedBox(height: 14),
        Row(children: [
          Expanded(
            child: OutlinedButton.icon(
              style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 12)),
              icon: const Icon(Icons.share_outlined),
              label: Text(tr('Share link')),
              onPressed: () => TripCard.shareLink(trip, AppScope.read(context).vehicle?.title ?? ''),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: FilledButton.icon(
              style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 12)),
              icon: const Icon(Icons.stop_circle_outlined),
              label: Text(tr('Stop sharing')),
              onPressed: TripShare.stop,
            ),
          ),
        ]),
      ]),
    );
  }
}

/// A slim reminder on Home while a trip is being shared, so it's never on
/// without the owner noticing.
class TripBanner extends StatelessWidget {
  const TripBanner({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ActiveTrip?>(
      valueListenable: TripShare.active,
      builder: (context, t, _) => Swap(
        child: t == null
            ? const SizedBox(key: ValueKey('off'), width: double.infinity)
            : Padding(
                key: const ValueKey('on'),
                padding: const EdgeInsets.only(bottom: 12),
                child: SectionCard(
                  selected: true,
                  padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
                  child: Row(children: [
                    const PulseDot(),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(tr('Sharing your trip until {time}', {'time': DateFormat.jm().format(t.endsAt)}),
                          style: DLText.strong.copyWith(color: DL.violetDeep)),
                    ),
                    TextButton(onPressed: TripShare.stop, child: Text(tr('Stop'))),
                  ]),
                ),
              ),
      ),
    );
  }
}
