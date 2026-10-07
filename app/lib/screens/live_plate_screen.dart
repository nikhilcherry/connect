import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

import '../l10n.dart';
import '../services/plate_detector.dart';
import '../services/plate_reader.dart';
import '../theme.dart';

/// Live camera view: our own plate detector runs on every few frames, on the
/// phone, and draws a box on each plate it sees. Nothing leaves the phone
/// while you look around; tapping a box photographs it, reads it and returns
/// the plate to the previous screen, which does the one and only lookup.
class LivePlateScreen extends StatefulWidget {
  const LivePlateScreen({super.key});

  @override
  State<LivePlateScreen> createState() => _LivePlateScreenState();
}

class _LivePlateScreenState extends State<LivePlateScreen> with WidgetsBindingObserver {
  CameraController? _cam;
  PlateDetector? _detector;
  List<PlateBox> _boxes = const [];
  Size _frame = Size.zero; // size of the upright frame the boxes are in
  String? _error;
  bool _busy = false;
  bool _reading = false;
  int _ms = 0; // last detection time, shown so the speed is visible
  DateTime _last = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _start();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
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
      final cam = CameraController(
        back,
        ResolutionPreset.medium,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.yuv420,
      );
      await cam.initialize();
      _detector = await PlateDetector.load();
      if (!mounted) {
        await cam.dispose();
        return;
      }
      setState(() => _cam = cam);
      await cam.startImageStream((img) => _onFrame(img, back.sensorOrientation));
    } catch (e) {
      debugPrint('live view failed: $e');
      if (mounted) setState(() => _error = tr('The camera isn\'t available.'));
    }
  }

  Future<void> _onFrame(CameraImage img, int rotation) async {
    final now = DateTime.now();
    if (_busy || _reading || now.difference(_last).inMilliseconds < 250 || _detector == null) return;
    _busy = true;
    _last = now;
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
      final boxes = await _detector!.detect(px, minScore: 0.4);
      if (mounted) {
        setState(() {
          _boxes = boxes;
          _frame = Size(px.width.toDouble(), px.height.toDouble());
          _ms = sw.elapsedMilliseconds;
        });
      }
    } catch (e) {
      debugPrint('frame failed: $e');
    } finally {
      _busy = false;
    }
  }

  /// Photographs the scene, reads the plate in it, and hands it back.
  Future<void> _pick() async {
    final cam = _cam;
    if (cam == null || _reading || _boxes.isEmpty) return;
    setState(() => _reading = true);
    try {
      await cam.stopImageStream();
      final shot = await cam.takePicture();
      final reading = await readPlatesInPhoto(File(shot.path));
      if (!mounted) return;
      if (reading.plates.isNotEmpty) {
        Navigator.of(context).pop(reading.plates.first);
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('Couldn\'t read that plate. Get a bit closer and try again.'))));
      await cam.startImageStream((img) => _onFrame(img, cam.description.sensorOrientation));
    } catch (e) {
      debugPrint('pick failed: $e');
    } finally {
      if (mounted) setState(() => _reading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cam = _cam;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(title: Text(tr('Live plate view'))),
      body: SafeArea(
        child: _error != null
            ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(_error!, style: DLText.body.copyWith(color: DL.onDark))))
            : cam == null || !cam.value.isInitialized
                ? const Center(child: CircularProgressIndicator())
                : Column(children: [
                    Expanded(
                      child: LayoutBuilder(builder: (context, c) {
                        // The preview is upright; its aspect ratio is height/width of the sensor frame.
                        final ar = 1 / cam.value.aspectRatio;
                        return Center(
                          child: AspectRatio(
                            aspectRatio: ar,
                            child: GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: _pick,
                              child: Stack(fit: StackFit.expand, children: [
                                CameraPreview(cam),
                                if (_frame != Size.zero) CustomPaint(painter: _BoxPainter(_boxes, _frame)),
                                if (_reading) const ColoredBox(color: Color(0x88000000), child: Center(child: CircularProgressIndicator())),
                              ]),
                            ),
                          ),
                        );
                      }),
                    ),
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        _boxes.isEmpty ? tr('Point the camera at a number plate') : tr('{n} in view. Tap to read it.', {'n': _boxes.length}),
                        textAlign: TextAlign.center,
                        style: DLText.body.copyWith(color: DL.onDark, fontWeight: FontWeight.w700),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Text(
                        _ms == 0 ? '' : tr('Detected on this phone in {ms} ms', {'ms': _ms}),
                        style: DLText.small.copyWith(color: DL.onDarkMuted),
                      ),
                    ),
                  ]),
      ),
    );
  }
}

class _BoxPainter extends CustomPainter {
  _BoxPainter(this.boxes, this.frame);
  final List<PlateBox> boxes;
  final Size frame;

  @override
  void paint(Canvas canvas, Size size) {
    final sx = size.width / frame.width, sy = size.height / frame.height;
    final stroke = Paint()
      ..color = DL.violet
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;
    final fill = Paint()..color = DL.violet.withValues(alpha: 0.18);
    for (final b in boxes) {
      final r = Rect.fromLTRB(b.left * sx, b.top * sy, b.right * sx, b.bottom * sy);
      canvas.drawRect(r, fill);
      canvas.drawRect(r, stroke);
    }
  }

  @override
  bool shouldRepaint(_BoxPainter old) => old.boxes != boxes || old.frame != frame;
}
