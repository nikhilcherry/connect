import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart' show DateFormat;
import 'package:path_provider/path_provider.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:share_plus/share_plus.dart';

import '../l10n.dart';
import '../main.dart';
import '../services/device.dart';
import '../services/plate_detector.dart';
import '../services/plate_reader.dart';
import '../services/plate_recognizer.dart';
import '../services/witness.dart';
import '../services/witness_report.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/motion.dart';
import 'plate_scan_screen.dart';

/// Witness mode: the phone watches from a parked car. Our plate detector and
/// reader run on the camera a few times a second and the last minute of
/// plates is kept in memory. A bump freezes it: the plates in view before and
/// just after, two frames, the time and the force are written down as an
/// incident. Nothing leaves the phone.
///
/// The camera only runs while this screen is open, so the screen is kept
/// awake; this is a mode for a phone left on the dashboard, not a background
/// service.
class WitnessScreen extends StatefulWidget {
  const WitnessScreen({super.key});

  @override
  State<WitnessScreen> createState() => _WitnessScreenState();
}

class _WitnessScreenState extends State<WitnessScreen> {
  CameraController? _cam;
  PlateDetector? _detector;
  PlateRecognizer? _reader;
  StreamSubscription<UserAccelerometerEvent>? _accel;
  final _memory = SightingMemory();
  final _bumps = BumpDetector(level: BumpLevel.firm);

  List<PlateBox> _boxes = const [];
  List<String?> _read = const []; // what each box says, when it could be read
  Size _frame = Size.zero;
  Pixels? _last; // the newest frame, kept in case the next moment is a bump
  String? _error;
  bool _busy = false;
  int _ms = 0;
  DateTime _lastRun = DateTime.fromMillisecondsSinceEpoch(0);

  // A bump being recorded: the frames go on being read for a few seconds first.
  DateTime? _bumpAt;
  double _peak = 0;
  bool _manual = false;
  Pixels? _bumpFrame;
  Timer? _settle;

  @override
  void initState() {
    super.initState();
    ScreenAwake.keep(true);
    _start();
    _accel = userAccelerometerEventStream(samplingPeriod: SensorInterval.gameInterval).listen(_onMotion, onError: (Object e) {
      debugPrint('no accelerometer: $e');
    });
  }

  @override
  void dispose() {
    ScreenAwake.keep(false);
    _accel?.cancel();
    _settle?.cancel();
    final cam = _cam;
    _cam = null;
    if (cam != null) {
      cam.stopImageStream().catchError((_) {}).whenComplete(cam.dispose);
    }
    super.dispose();
  }

  Future<void> _start() async {
    try {
      final cams = await availableCameras();
      final back = cams.firstWhere((c) => c.lensDirection == CameraLensDirection.back, orElse: () => cams.first);
      // 720p: a plate across the road has to keep enough pixels to be read.
      final cam = CameraController(back, ResolutionPreset.high, enableAudio: false, imageFormatGroup: ImageFormatGroup.yuv420);
      await cam.initialize();
      _detector = await PlateDetector.load();
      try {
        _reader = await PlateRecognizer.load();
      } catch (e) {
        debugPrint('no plate reader on this phone: $e');
      }
      if (!mounted) {
        await cam.dispose();
        return;
      }
      setState(() => _cam = cam);
      await cam.startImageStream((img) => _onFrame(img, back.sensorOrientation));
    } catch (e) {
      debugPrint('witness camera failed: $e');
      if (mounted) setState(() => _error = tr('The camera isn\'t available.'));
    }
  }

  Future<void> _onFrame(CameraImage img, int rotation) async {
    final now = DateTime.now();
    if (_busy || _detector == null || now.difference(_lastRun).inMilliseconds < 300) return;
    _busy = true;
    _lastRun = now;
    try {
      final sw = Stopwatch()..start();
      final px = yuv420ToPixels(
        y: img.planes[0].bytes,
        u: img.planes[1].bytes,
        v: img.planes[2].bytes,
        width: img.width,
        height: img.height,
        yRowStride: img.planes[0].bytesPerRow,
        uvRowStride: img.planes[1].bytesPerRow,
        uvPixelStride: img.planes[1].bytesPerPixel ?? 1,
        rotation: rotation,
      );
      final boxes = (await _detector!.detect(px, minScore: 0.45)).take(3).toList();
      final read = <String?>[];
      for (final b in boxes) {
        // A box whose text is unsure or not plate-shaped is still drawn, just not remembered.
        final r = _reader?.readBox(px, b);
        String? text;
        if (r != null && r.confidence >= 0.5 && isValidPlate(r.text)) {
          text = r.text;
          _memory.add(PlateSighting(r.text, now, r.confidence));
        }
        read.add(text);
      }
      _last = px;
      if (mounted) {
        setState(() {
          _boxes = boxes;
          _read = read;
          _frame = Size(px.width.toDouble(), px.height.toDouble());
          _ms = sw.elapsedMilliseconds;
        });
      }
    } catch (e) {
      debugPrint('witness frame failed: $e');
    } finally {
      _busy = false;
    }
  }

  void _onMotion(UserAccelerometerEvent e) {
    final g = math.sqrt(e.x * e.x + e.y * e.y + e.z * e.z) / 9.81;
    final now = DateTime.now();
    if (_bumpAt != null) {
      // The first reading over the line is rarely the hardest; the peak comes within the next moment.
      if (g > _peak && now.difference(_bumpAt!).inMilliseconds < 400) _peak = g;
      return;
    }
    if (_bumps.feed(g, now)) _onBump(g);
  }

  void _onBump(double g, {bool manual = false}) {
    if (_bumpAt != null || _cam == null) return;
    HapticFeedback.heavyImpact();
    setState(() {
      _bumpAt = DateTime.now();
      _peak = g;
      _manual = manual;
      _bumpFrame = _last;
    });
    _settle = Timer(Incident.after, _record);
  }

  Future<void> _record() async {
    final at = _bumpAt;
    if (at == null) return;
    final plates = rankPlates(_memory.between(at.subtract(Incident.before), at.add(Incident.after)));
    final photos = <String>[];
    try {
      final dir = Directory('${(await getApplicationDocumentsDirectory()).path}/witness');
      await dir.create(recursive: true);
      final frames = [?_bumpFrame, if (_last != null && !identical(_last, _bumpFrame)) _last!];
      for (final (i, px) in frames.indexed) {
        final f = File('${dir.path}/${at.millisecondsSinceEpoch}_$i.png');
        await f.writeAsBytes(await px.toPng());
        photos.add(f.path);
      }
    } catch (e) {
      debugPrint('witness frames not saved: $e');
    }
    final incident = Incident(at: at, peakG: _peak, plates: plates, photos: photos, manual: _manual);
    await WitnessLog.add(incident);
    if (!mounted) return;
    setState(() {
      _bumpAt = null;
      _bumpFrame = null;
    });
    push(context, IncidentScreen(incident));
  }

  @override
  Widget build(BuildContext context) {
    final cam = _cam;
    final recent = _memory.recent(DateTime.now(), const Duration(seconds: 60));
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Text(tr('Witness mode')),
        actions: [
          IconButton(
            tooltip: tr('Past incidents'),
            icon: const Icon(Icons.history),
            onPressed: () => push(context, const WitnessLogScreen()),
          ),
        ],
      ),
      body: SafeArea(
        child: _error != null
            ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(_error!, style: DLText.body.copyWith(color: DL.onDark))))
            : cam == null || !cam.value.isInitialized
                ? const Center(child: CircularProgressIndicator())
                : Column(children: [
                    Expanded(
                      child: Center(
                        child: AspectRatio(
                          // The preview is upright; its aspect ratio is height/width of the sensor frame.
                          aspectRatio: 1 / cam.value.aspectRatio,
                          child: Stack(fit: StackFit.expand, children: [
                            CameraPreview(cam),
                            if (_frame != Size.zero) CustomPaint(painter: _PlatePainter(_boxes, _read, _frame)),
                            if (_bumpAt != null)
                              Align(
                                alignment: Alignment.topCenter,
                                child: Container(
                                  margin: const EdgeInsets.all(12),
                                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                                  decoration: BoxDecoration(color: DL.amber, borderRadius: BorderRadius.circular(DL.rButton)),
                                  child: Text(
                                    _manual ? tr('Marked. Watching what happens next…') : tr('Bump felt. Watching what happens next…'),
                                    style: DLText.strong.copyWith(color: DL.onDark),
                                  ),
                                ),
                              ),
                          ]),
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                      child: Row(children: [
                        const PulseDot(color: DL.success),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            recent.isEmpty
                                ? tr('Watching. No plate read in the last minute.')
                                : tr('Watching. In view in the last minute: {plates}', {'plates': recent.take(3).map((p) => p.plate).join(', ')}),
                            style: DLText.small.copyWith(color: DL.onDark),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ]),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                      child: Row(children: [
                        Expanded(child: Text(tr('What counts as a bump'), style: DLText.small.copyWith(color: DL.onDarkMuted))),
                        DropdownButton<BumpLevel>(
                          value: _bumps.level,
                          dropdownColor: DL.ink,
                          underline: const SizedBox(),
                          iconEnabledColor: DL.onDark,
                          style: DLText.strong.copyWith(color: DL.onDark),
                          items: [for (final l in BumpLevel.values) DropdownMenuItem(value: l, child: Text(tr(l.label)))],
                          onChanged: (l) => setState(() => _bumps.level = l!),
                        ),
                      ]),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                      child: SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed: _bumpAt != null ? null : () => _onBump(0, manual: true),
                          icon: const Icon(Icons.flag_outlined),
                          label: Text(tr('Mark this moment')),
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: Text(
                        _ms == 0 ? '' : tr('Read on this phone in {ms} ms a frame', {'ms': _ms}),
                        style: DLText.small.copyWith(color: DL.onDarkMuted),
                      ),
                    ),
                  ]),
      ),
    );
  }
}

/// A box on each plate in view, with what the reader made of it.
class _PlatePainter extends CustomPainter {
  _PlatePainter(this.boxes, this.read, this.frame);
  final List<PlateBox> boxes;
  final List<String?> read;
  final Size frame;

  @override
  void paint(Canvas canvas, Size size) {
    final sx = size.width / frame.width, sy = size.height / frame.height;
    final stroke = Paint()
      ..color = DL.violet
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;
    for (var i = 0; i < boxes.length; i++) {
      final b = boxes[i];
      final r = Rect.fromLTRB(b.left * sx, b.top * sy, b.right * sx, b.bottom * sy);
      canvas.drawRect(r, stroke);
      final text = i < read.length ? read[i] : null;
      if (text == null) continue;
      final label = TextPainter(
        text: TextSpan(text: text, style: DLText.strong.copyWith(color: DL.onDark, fontSize: 13)),
        textDirection: TextDirection.ltr,
      )..layout();
      final at = Offset(r.left, math.max(0, r.top - label.height - 6));
      canvas.drawRect(Rect.fromLTWH(at.dx, at.dy, label.width + 10, label.height + 4), Paint()..color = DL.violet);
      label.paint(canvas, at + const Offset(5, 2));
    }
  }

  @override
  bool shouldRepaint(_PlatePainter old) => old.boxes != boxes || old.read != read || old.frame != frame;
}

/// What the phone wrote down around one bump, and what can be done with it.
class IncidentScreen extends StatelessWidget {
  const IncidentScreen(this.incident, {super.key});
  final Incident incident;

  Future<void> _share(BuildContext context) async {
    final v = AppScope.read(context).vehicle;
    final pdf = await buildWitnessReport(incident, car: v?.title, plate: v?.prettyReg);
    final f = File('${(await getTemporaryDirectory()).path}/incident-record.pdf');
    await f.writeAsBytes(pdf);
    await SharePlus.instance.share(ShareParams(files: [XFile(f.path, mimeType: 'application/pdf')], text: tr('Incident record')));
  }

  @override
  Widget build(BuildContext context) {
    final photos = incident.photos.where((p) => File(p).existsSync()).toList();
    return Scaffold(
      appBar: AppBar(title: Text(tr('Incident'))),
      body: SafeArea(
        child: ListView(padding: const EdgeInsets.fromLTRB(20, 8, 20, 32), children: revealAll([
          ScreenTitle(DateFormat('d MMM, h:mm:ss a').format(incident.at), eyebrow: tr('Witness mode')),
          const SizedBox(height: 8),
          Text(
            incident.manual ? tr('Marked by hand.') : tr('The phone felt a bump of about {g} g.', {'g': incident.peakG.toStringAsFixed(1)}),
            style: DLText.body.copyWith(color: DL.muted),
          ),
          if (photos.isNotEmpty) ...[
            const SizedBox(height: 16),
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              for (var i = 0; i < photos.length; i++) ...[
                if (i > 0) const SizedBox(width: 8),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    ClipRRect(borderRadius: BorderRadius.circular(DL.rCard), child: Image.file(File(photos[i]), fit: BoxFit.cover)),
                    const SizedBox(height: 6),
                    Text(i == 0 ? tr('At the bump') : tr('A few seconds after'), style: DLText.small),
                  ]),
                ),
              ],
            ]),
          ],
          const SizedBox(height: 24),
          Label(tr('Plates in view around that moment')),
          const SizedBox(height: 12),
          if (incident.plates.isEmpty)
            SectionCard(child: Text(tr('No plate was read around that moment. The photos may still show the car.'), style: DLText.body))
          else
            for (final p in incident.plates) ...[
              SectionCard(
                padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
                child: Row(children: [
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(p.plate, style: DLText.numeral.copyWith(fontSize: 22)),
                      const SizedBox(height: 4),
                      Text(tr('Read in {n} frames', {'n': p.count}), style: DLText.small),
                    ]),
                  ),
                  TextButton(onPressed: () => push(context, PlateScanScreen(plate: p.plate)), child: Text(tr('Reach the owner'))),
                ]),
              ),
              const SizedBox(height: 8),
            ],
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: () => _share(context),
            icon: const Icon(Icons.picture_as_pdf_outlined),
            label: Text(tr('Save record as PDF')),
          ),
          const SizedBox(height: 16),
          FootNote(tr('Plates are read by a model on this phone and can be wrong: check them against the photos. Nothing here has left the phone.')),
        ])),
      ),
    );
  }
}

/// Every incident kept on this phone.
class WitnessLogScreen extends StatelessWidget {
  const WitnessLogScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(tr('Past incidents'))),
      body: SafeArea(
        child: ValueListenableBuilder<List<Incident>>(
          valueListenable: WitnessLog.incidents,
          builder: (context, all, _) => ListView(padding: const EdgeInsets.fromLTRB(20, 8, 20, 32), children: [
            if (all.isEmpty)
              EmptyState(
                icon: Icons.videocam_outlined,
                title: tr('Nothing recorded'),
                body: tr('When the phone feels a bump in Witness mode, what it saw is kept here.'),
              ),
            for (final i in all) ...[
              InfoRow(
                icon: i.manual ? Icons.flag_outlined : Icons.car_crash_outlined,
                tone: i.plates.isEmpty ? null : Tone.info,
                title: DateFormat('d MMM, h:mm a').format(i.at),
                subtitle: i.plates.isEmpty ? tr('No plate read') : i.plates.map((p) => p.plate).join(', '),
                onTap: () => push(context, IncidentScreen(i)),
              ),
              const SizedBox(height: 8),
            ],
          ]),
        ),
      ),
    );
  }
}
