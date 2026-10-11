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
import '../services/dashcam_stream.dart';
import '../services/roadguard.dart';
import '../services/trip_share.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/motion.dart';
import 'drive_report_screen.dart';
import 'medical_screen.dart';
import 'witness_screen.dart';

class SafetyTab extends StatelessWidget {
  const SafetyTab({super.key});

  /// Use a dashcam instead of the phone's camera: its live view over Wi-Fi, or its footage (some clips, or a
  /// whole folder). Footage keeps each clip's own time and place.
  Future<void> _scanVideo(BuildContext context) async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.wifi_tethering),
            title: Text(tr('Connect a dashcam')),
            subtitle: Text(tr('Live video over its Wi-Fi')),
            onTap: () => Navigator.of(ctx).pop('dashcam'),
          ),
          ListTile(
            leading: const Icon(Icons.video_library_outlined),
            title: Text(tr('Pick videos')),
            subtitle: Text(tr('One or more clips')),
            onTap: () => Navigator.of(ctx).pop('videos'),
          ),
          ListTile(
            leading: const Icon(Icons.folder_open_outlined),
            title: Text(tr('Pick a folder')),
            subtitle: Text(tr('All the clips in a dashcam folder')),
            onTap: () => Navigator.of(ctx).pop('folder'),
          ),
        ]),
      ),
    );
    if (choice == null || !context.mounted) return;
    if (choice == 'dashcam') {
      final url = await _askDashcam(context);
      if (url == null || !context.mounted) return;
      await DashcamAddress.remember(url);
      RoadGuard.stream = url;
      if (!context.mounted) return;
      push(context, const DriveModeScreen());
      return;
    }
    final clips = choice == 'folder' ? await RoadGuard.pickVideoFolder() : await RoadGuard.pickVideos();
    if (clips.isEmpty || !context.mounted) return;
    RoadGuard.videos = clips;
    push(context, const DriveModeScreen());
  }

  /// Asks for the dashcam's live-view address; null if cancelled.
  Future<String?> _askDashcam(BuildContext context) async {
    final field = TextEditingController(text: await DashcamAddress.lastUsed());
    if (!context.mounted) return null;
    String? error;
    return showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setInner) => AlertDialog(
          title: Text(tr('Connect a dashcam')),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(tr('Its live-view address, for example http://192.168.1.254:8192. Join the dashcam\'s Wi-Fi first.'), style: DLText.small),
            const SizedBox(height: 12),
            TextField(
              controller: field,
              keyboardType: TextInputType.url,
              autocorrect: false,
              decoration: InputDecoration(labelText: tr('Dashcam address'), hintText: 'http://192.168.1.254:8192', errorText: error),
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.of(ctx).pop(), child: Text(tr('Cancel'))),
            FilledButton(
              onPressed: () {
                final a = DashcamAddress.parse(field.text);
                if (a.ok) {
                  Navigator.of(ctx).pop(a.url);
                } else {
                  setInner(() => error = switch (a.error!) {
                        DashcamAddressError.rtsp => tr('RTSP streams aren\'t supported yet. Use the dashcam\'s MJPEG (http) address.'),
                        _ => tr('Enter the dashcam\'s address, like http://192.168.1.254:8192'),
                      });
                }
              },
              child: Text(tr('Connect')),
            ),
          ],
        ),
      ),
    );
  }

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
            const SizedBox(height: 14),
            ValueListenableBuilder<bool>(
              valueListenable: RoadGuard.enabled,
              builder: (_, on, _) => Row(children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(tr('Scan the road with the camera'), style: DLText.body.copyWith(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 2),
                    Text(tr('Finds potholes, triple riding and riders without helmets. Everything stays on this phone.'), style: DLText.small),
                  ]),
                ),
                Switch(value: on, onChanged: RoadGuard.setEnabled),
              ]),
            ),
            ValueListenableBuilder<bool>(
              valueListenable: RoadGuard.aiAvailable,
              builder: (_, available, _) => !available
                  ? const SizedBox.shrink()
                  : ValueListenableBuilder<bool>(
                      valueListenable: RoadGuard.aiEnabled,
                      builder: (_, aiOn, _) => Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Row(children: [
                          Expanded(
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text(tr('Double-check with AI'), style: DLText.body.copyWith(fontWeight: FontWeight.w600)),
                              const SizedBox(height: 2),
                              Text(
                                tr('Sends a cropped photo of a suspect vehicle to a cloud AI service for a second opinion. Needs internet. Off by default.'),
                                style: DLText.small,
                              ),
                            ]),
                          ),
                          Switch(value: aiOn, onChanged: RoadGuard.setAiEnabled),
                        ]),
                      ),
                    ),
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
        const SizedBox(height: 32),

        Label(tr('More ways to scan')),
        const SizedBox(height: 12),
        InfoRow(
          icon: Icons.wifi_tethering,
          title: tr('Use a dashcam or video'),
          subtitle: tr('Scan a dashcam\'s live view, or clips saved from it.'),
          onTap: s.contacts.isEmpty ? null : () => _scanVideo(context),
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

  // Road scan (potholes, triple riding, no helmet) runs alongside crash detection.
  _RoadState _roadState = _RoadState.off;
  RoadStatus? _road;
  Timer? _roadTimer;
  Timer? _previewTimer;
  bool _previewBusy = false;
  Uint8List? _frame;
  bool _finishing = false;
  // Not `late`: it must be stamped when Drive Mode opens, not when Stop first reads it.
  final DateTime _startedAt = DateTime.now();

  @override
  void initState() {
    super.initState();
    _detector.start();
    _startRoad();
  }

  @override
  void dispose() {
    _detector.stop();
    _roadTimer?.cancel();
    _previewTimer?.cancel();
    RoadGuard.stop();
    _countdown?.cancel();
    _ring.dispose();
    super.dispose();
  }

  Future<void> _startRoad() async {
    if (!RoadGuard.enabled.value) return;
    setState(() => _roadState = _RoadState.starting);
    final ok = await RoadGuard.start();
    if (!mounted) {
      RoadGuard.stop();
      return;
    }
    if (!ok) {
      final supported = await RoadGuard.available();
      if (mounted) setState(() => _roadState = supported ? _RoadState.denied : _RoadState.unavailable);
      return;
    }
    setState(() => _roadState = _RoadState.running);
    _roadTimer = Timer.periodic(const Duration(seconds: 1), (_) async {
      final st = await RoadGuard.status();
      if (mounted && st != null) setState(() => _road = st);
      // A batch of clips ends by itself: collect what it found and show the report.
      if (mounted && st != null && st.videoDone && !_finishing) {
        _finishing = true;
        _stopDrive();
      }
    });
    // The live view: a few frames a second, rendered natively only when asked for.
    _previewTimer = Timer.periodic(const Duration(milliseconds: 250), (_) async {
      if (_previewBusy) return;
      _previewBusy = true;
      final f = await RoadGuard.preview();
      _previewBusy = false;
      if (mounted && f != null) setState(() => _frame = f);
    });
  }

  /// Stop: collect what the scan caught, shut it down, and show the report if there is one.
  Future<void> _stopDrive() async {
    _roadTimer?.cancel();
    _previewTimer?.cancel();
    var found = const <RoadEvent>[];
    if (_roadState == _RoadState.running) {
      found = await RoadGuard.events(_startedAt);
      await RoadGuard.stop();
    }
    if (!mounted) return;
    final nav = Navigator.of(context);
    if (found.isEmpty) {
      nav.pop();
    } else {
      nav.pushReplacement(MaterialPageRoute(builder: (_) => DriveReportScreen(events: found)));
    }
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
                  onPressed: _stopDrive,
                  child: Text(tr('Stop')),
                ),
            ]),
            // The middle scrolls when the live view makes it taller than the screen, so nothing overflows.
            Expanded(
              child: Center(
                child: SingleChildScrollView(
                  child: Swap(
                    alignment: Alignment.center,
                    child: counting ? _countdownView(key: const ValueKey('count')) : _watchingView(key: ValueKey('watch-$_sent')),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
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
        if (_roadState != _RoadState.off) ...[const SizedBox(height: 28), _RoadPanel(state: _roadState, status: _road, frame: _frame)],
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

enum _RoadState { off, starting, running, unavailable, denied }

/// Road scan on Drive Mode's dark screen, in one card: the live camera view with what the models
/// found drawn on it, what the scan is doing, and the counts so far.
class _RoadPanel extends StatelessWidget {
  const _RoadPanel({required this.state, required this.status, required this.frame});

  final _RoadState state;
  final RoadStatus? status;
  final Uint8List? frame;

  static String? _lastLabel(String last) {
    final l = last.toLowerCase();
    if (l.startsWith('triple')) return tr('Triple riding');
    if (l.startsWith('no helmet')) return tr('Rider without helmet');
    if (l.startsWith('pothole')) return tr('Pothole');
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final s = status;
    final live = state == _RoadState.running && s != null && s.ready;
    final line = switch (state) {
      _RoadState.off => tr('Road scan is off'),
      _RoadState.starting => tr('Road scan: starting...'),
      _RoadState.unavailable => tr('Road scan isn\'t available on this phone.'),
      _RoadState.denied => tr('Allow camera access to scan the road.'),
      _RoadState.running => !live
          ? tr('Road scan: loading...')
          : s.paused
              ? tr('Paused to cool the phone')
              : s.thermal >= 2
                  ? tr('Phone is warm: scanning slower')
                  : s.streamHost.isNotEmpty
                      ? switch (s.streamState) {
                          'live' => tr('Dashcam: {host}', {'host': s.streamHost}),
                          'lost' => tr('Dashcam connection lost. Reconnecting...'),
                          _ => tr('Connecting to the dashcam...'),
                        }
                      : s.videoCount > 0
                          ? tr('Clip {i} of {n}: {name}', {'i': '${s.videoIndex}', 'n': '${s.videoCount}', 'name': s.videoClip})
                          : tr('Scanning the road'),
    };
    final last = live ? _lastLabel(s.last) : null;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 520),
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(DL.rCard),
          border: Border.all(color: DL.muted),
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          if (state == _RoadState.running)
            SizedBox(
              height: 320,
              width: double.infinity,
              child: frame == null
                  ? const ColoredBox(color: Colors.black, child: Center(child: SizedBox.square(dimension: 22, child: CircularProgressIndicator(strokeWidth: 2, color: DL.onDarkMuted))))
                  : Stack(fit: StackFit.expand, children: [
                      ColoredBox(color: Colors.black, child: Image.memory(frame!, fit: BoxFit.contain, gaplessPlayback: true)),
                      if (s != null && s.streamHost.isNotEmpty)
                        Positioned(
                          left: 8,
                          top: 8,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            color: DL.success,
                            child: Text(tr('Live from a dashcam'), style: DLText.small.copyWith(color: DL.onDark, fontWeight: FontWeight.w700)),
                          ),
                        ),
                      if (s != null && s.demo)
                        Positioned(
                          left: 8,
                          top: 8,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            color: DL.error,
                            child: Text(s.videoCount > 0 ? tr('Footage from a video, not the camera') : tr('Test feed, not the camera'), style: DLText.small.copyWith(color: DL.onDark, fontWeight: FontWeight.w700)),
                          ),
                        ),
                    ]),
            ),
          Padding(
            padding: const EdgeInsets.all(14),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                Icon(Icons.videocam_outlined, size: 18, color: live ? DL.onDark : DL.onDarkMuted),
                const SizedBox(width: 8),
                Flexible(child: Text(line, style: DLText.body.copyWith(color: DL.onDark))),
              ]),
              if (live) ...[
                const SizedBox(height: 12),
                Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
                  _count(tr('Potholes'), s.potholes),
                  _count(tr('Violations'), s.violations),
                ]),
                if (s.aiOn) ...[
                  const SizedBox(height: 8),
                  Text(tr('AI second opinions: {n}', {'n': '${s.aiCalls - s.aiFail}'}), style: DLText.small.copyWith(color: DL.onDarkMuted)),
                ],
                if (last != null) ...[
                  const SizedBox(height: 10),
                  Text(tr('Last: {x}', {'x': last}), style: DLText.small.copyWith(color: DL.onDarkMuted)),
                ],
              ],
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _count(String label, int n) => Column(children: [
        Text('$n', style: DLText.title.copyWith(color: DL.onDark)),
        const SizedBox(height: 2),
        Text(label, style: DLText.small.copyWith(color: DL.onDarkMuted)),
      ]);
}
