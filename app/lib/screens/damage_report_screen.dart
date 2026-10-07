import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../data/car_catalog.dart';
import '../l10n.dart';
import '../main.dart';
import '../services/damage_cost.dart';
import '../services/damage_detector.dart';
import '../services/damage_report.dart';
import '../services/plate_detector.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/motion.dart';

/// Photograph (or open) damage on a car: a model on the phone finds dents, scratches,
/// cracks and broken glass, draws a box on each, and gives a rough repair cost range
/// from what it found, the car and how large each damaged area is. Saves an evidence PDF.
/// The photo never leaves the phone.
class DamageReportScreen extends StatefulWidget {
  const DamageReportScreen({super.key, this.photo, this.photoUrl, this.plate});

  /// A photo to analyse straight away (e.g. one the stranger sent with an alert).
  final File? photo;
  final String? photoUrl;
  final String? plate;

  @override
  State<DamageReportScreen> createState() => _DamageReportScreenState();
}

class _DamageReportScreenState extends State<DamageReportScreen> {
  Pixels? _px;
  File? _file;
  List<DamageFinding> _found = const [];
  CarSpec? _car;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final v = AppScope.read(context).vehicle;
    if (v != null) _car = carCatalog.where((c) => c.make == v.make && c.model == v.model).firstOrNull;
    if (widget.photo != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _analyse(widget.photo!));
    } else if (widget.photoUrl != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _download(widget.photoUrl!));
    }
  }

  Future<void> _download(String url) async {
    setState(() => _busy = true);
    try {
      final client = HttpClient();
      final res = await (await client.getUrl(Uri.parse(url))).close();
      final bytes = await res.fold<BytesBuilder>(BytesBuilder(), (b, d) => b..add(d));
      final dir = await getTemporaryDirectory();
      final f = File('${dir.path}/alert_photo.jpg');
      await f.writeAsBytes(bytes.takeBytes());
      await _analyse(f);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = tr('The photo couldn\'t be loaded.');
        });
      }
    }
  }

  Future<void> _pick(ImageSource source) async {
    final shot = await ImagePicker().pickImage(source: source, maxWidth: 2000, imageQuality: 90);
    if (shot != null) await _analyse(File(shot.path));
  }

  Future<void> _analyse(File f) async {
    if (!mounted) return;
    setState(() {
      _busy = true;
      _error = null;
      _file = f;
    });
    try {
      final px = await Pixels.fromFile(f, maxSide: 1600);
      final found = await (await DamageDetector.load()).detect(px);
      if (!mounted) return;
      setState(() {
        _px = px;
        _found = found;
        _busy = false;
      });
    } catch (e) {
      debugPrint('damage analysis failed: $e');
      if (mounted) {
        setState(() {
          _busy = false;
          _error = tr('Couldn\'t analyse that photo on this phone.');
        });
      }
    }
  }

  CostEstimate get _estimate => estimateRepairCost(_found, make: _car?.make, lengthMm: _car?.lengthMm);

  Future<void> _share() async {
    final px = _px;
    if (px == null) return;
    final png = await annotatedPhoto(px, _found);
    final pdf = await buildDamageReport(
      annotatedPng: png,
      findings: _found,
      estimate: _estimate,
      car: _car?.name,
      plate: widget.plate,
    );
    final dir = await getTemporaryDirectory();
    final f = File('${dir.path}/damage-report.pdf');
    await f.writeAsBytes(pdf);
    await SharePlus.instance.share(ShareParams(files: [XFile(f.path, mimeType: 'application/pdf')], text: tr('Damage report')));
  }

  @override
  Widget build(BuildContext context) {
    final money = NumberFormat.decimalPattern('en_IN');
    final est = _estimate;
    return Scaffold(
      appBar: AppBar(title: Text(tr('Check damage'))),
      body: SafeArea(
        child: ListView(padding: const EdgeInsets.fromLTRB(20, 8, 20, 32), children: revealAll([
          ScreenTitle(tr('Damage and rough cost'), eyebrow: tr('On-device')),
          const SizedBox(height: 8),
          Text(
            tr('Photograph a dent, scratch or crack. A model on this phone finds it, marks it and gives a rough repair cost. The photo never leaves the phone.'),
            style: DLText.body.copyWith(color: DL.muted),
          ),
          const SizedBox(height: 20),
          Row(children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: _busy ? null : () => _pick(ImageSource.camera),
                icon: const Icon(Icons.photo_camera_outlined),
                label: Text(tr('Photograph')),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _busy ? null : () => _pick(ImageSource.gallery),
                icon: const Icon(Icons.photo_library_outlined),
                label: Text(tr('From gallery')),
              ),
            ),
          ]),
          if (_busy) ...[const SizedBox(height: 24), const Center(child: CircularProgressIndicator())],
          if (_error != null) ...[const SizedBox(height: 16), Text(_error!, style: DLText.body.copyWith(color: DL.error))],
          if (_px != null && !_busy) ...[
            const SizedBox(height: 20),
            ClipRRect(
              borderRadius: BorderRadius.circular(DL.rCard),
              child: AspectRatio(
                aspectRatio: _px!.width / _px!.height,
                child: Stack(fit: StackFit.expand, children: [
                  Image.file(_file!, fit: BoxFit.fill),
                  CustomPaint(painter: _DamagePainter(_found)),
                ]),
              ),
            ),
            const SizedBox(height: 16),
            FieldLabel(tr('Which car is it?')),
            DropdownButtonFormField<CarSpec?>(
              initialValue: _car,
              isExpanded: true,
              decoration: InputDecoration(hintText: tr('Not sure')),
              items: [
                DropdownMenuItem<CarSpec?>(value: null, child: Text(tr('Not sure'))),
                for (final c in carCatalog) DropdownMenuItem<CarSpec?>(value: c, child: Text(c.name)),
              ],
              onChanged: (c) => setState(() => _car = c),
            ),
            const SizedBox(height: 16),
            if (_found.isEmpty)
              SectionCard(child: Text(tr('No damage found in this photo. Try again closer, in better light.'), style: DLText.body))
            else
              SectionCard(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Label(tr('What it found')),
                  const SizedBox(height: 10),
                  for (final l in est.lines)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Row(children: [
                        Container(width: 12, height: 12, decoration: BoxDecoration(color: damageColor(l.type), shape: BoxShape.circle)),
                        const SizedBox(width: 10),
                        Expanded(child: Text('${tr(l.type.label)}  ×${l.count}', style: DLText.strong)),
                        Text('₹${money.format(l.low)} – ${money.format(l.high)}', style: DLText.body),
                      ]),
                    ),
                  const Divider(),
                  const SizedBox(height: 8),
                  Text(tr('Rough repair cost'), style: DLText.small.copyWith(color: DL.muted)),
                  Text('₹${money.format(est.low)} – ₹${money.format(est.high)}', style: DLText.title),
                  const SizedBox(height: 8),
                  for (final n in est.notes) Text(tr(n), style: DLText.small.copyWith(color: DL.muted)),
                  if (est.lines.any((l) => !reliableDamage.contains(l.type)))
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        tr('Broken lamps and flat tyres are the least reliable: the model saw few examples of them.'),
                        style: DLText.small.copyWith(color: DL.error),
                      ),
                    ),
                ]),
              ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _share,
              icon: const Icon(Icons.picture_as_pdf_outlined),
              label: Text(tr('Save report as PDF')),
            ),
            const SizedBox(height: 16),
            FootNote(tr('A rough estimate from the photo, not a quote or an inspection. Real cost depends on parts, paint and the garage. Get a written quote before repairing.')),
          ],
        ])),
      ),
    );
  }
}

class _DamagePainter extends CustomPainter {
  _DamagePainter(this.findings);
  final List<DamageFinding> findings;

  @override
  void paint(Canvas canvas, Size size) {
    for (final f in findings) {
      final r = Rect.fromLTRB(f.left * size.width, f.top * size.height, f.right * size.width, f.bottom * size.height);
      final c = damageColor(f.type);
      canvas.drawRect(r, Paint()..color = c.withValues(alpha: 0.15));
      canvas.drawRect(
        r,
        Paint()
          ..color = c
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3,
      );
    }
  }

  @override
  bool shouldRepaint(_DamagePainter old) => old.findings != findings;
}
