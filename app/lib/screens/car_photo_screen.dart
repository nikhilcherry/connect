import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../l10n.dart';
import '../main.dart';
import '../services/notifications.dart';
import '../services/plate_reader.dart';
import '../services/vehicle_read.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'rc_verify_screen.dart';
import 'tag_screen.dart';

/// Step 1 of onboarding: a photo of the car and nothing typed. The plate is
/// read on the phone; the make, model, colour and extra details by the local
/// vision model. Step 2 is the RC check, which then saves the car.
class CarPhotoScreen extends StatefulWidget {
  const CarPhotoScreen({super.key, this.addAnother = false});

  /// Adds a further car to an account that already has one.
  final bool addAnother;

  @override
  State<CarPhotoScreen> createState() => _CarPhotoScreenState();
}

class _CarPhotoScreenState extends State<CarPhotoScreen> {
  final _form = GlobalKey<FormState>();
  final _plate = TextEditingController();
  final _make = TextEditingController();
  final _model = TextEditingController();
  File? _photo;
  bool _reading = false;
  bool _plateDone = false, _carDone = false;
  bool _modelDown = false; // the local model didn't answer
  bool _read = false; // a photo has been read (even if it found little)
  bool _saving = false;
  String? _colour;
  Map<String, String?> _seen = const {};

  static String _norm(String s) => s.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');

  Future<void> _pick(ImageSource src) async {
    // 768 px is plenty for the model and keeps the upload small.
    final f = await ImagePicker().pickImage(source: src, maxWidth: 768, imageQuality: 80);
    if (f == null || !mounted) return;
    final s = AppScope.read(context);
    final file = File(f.path);
    setState(() {
      _photo = file;
      _reading = true;
      _read = false;
      _plateDone = _carDone = _modelDown = false;
      _plate.clear();
      _make.clear();
      _model.clear();
      _colour = null;
      _seen = const {};
    });
    // The plate is read at full size on the phone (the picked file is
    // downscaled, so re-pick is not needed: the detector copes with 768 px).
    final plateJob = readPlatesInPhoto(file).then((r) {
      if (!mounted) return;
      setState(() {
        _plateDone = true;
        if (r.plates.isNotEmpty) _plate.text = r.plates.first;
      });
    }).catchError((_) {
      if (mounted) setState(() => _plateDone = true);
    });
    final carJob = file.readAsBytes().then((b) => s.visionRead('car', b)).then((v) {
      if (!mounted) return;
      setState(() {
        _carDone = true;
        _modelDown = v == null;
        _seen = v ?? const {};
        _make.text = v?['make'] ?? '';
        _model.text = v?['model'] ?? '';
        _colour = canonicalColour(v?['colour']);
        // The model also reads plates; use it when the phone couldn't.
        final p = v?['plate'];
        if (_plate.text.isEmpty && p != null && isValidPlate(_norm(p))) _plate.text = _norm(p);
      });
    });
    await Future.wait([plateJob, carJob]);
    if (mounted) {
      setState(() {
        _reading = false;
        _read = true;
      });
    }
  }

  CarRead get _car => CarRead(
        plate: _norm(_plate.text),
        make: _make.text.trim().isEmpty ? null : _make.text.trim(),
        model: _model.text.trim().isEmpty ? null : _model.text.trim(),
        colour: _colour,
        bodyType: _seen['body_type'],
        fuel: _seen['fuel'],
        features: _seen['features'],
        condition: _seen['condition'],
      );

  Future<void> _next() async {
    if (!_form.currentState!.validate()) return;
    final car = _car;
    final res = await Navigator.of(context).push<RcResult>(MaterialPageRoute(builder: (_) => RcVerifyScreen(plate: car.plate, car: car)));
    if (res == null || !mounted) return;
    await _save(car, res);
  }

  Future<void> _save(CarRead car, RcResult res) async {
    setState(() => _saving = true);
    final s = AppScope.read(context);
    // The RC is the authority on make and model; the photo fills any gap.
    // What the owner confirmed in step 1 wins; the RC read fills a gap. (A
    // small model often splits "MARUTI SUZUKI" / "SWIFT VXI" badly.)
    final make = (car.make ?? res.read['make'] ?? res.rc.make).trim();
    final model = (car.model ?? res.read['model'] ?? res.rc.model).trim();
    final spec = catalogMatch(make, model);
    try {
      final fields = {
        'reg_number': car.plate,
        'make': make.length > 40 ? make.substring(0, 40) : make,
        'model': model.length > 60 ? model.substring(0, 60) : model,
        'colour': car.colour ?? canonicalColour(res.read['colour']),
        'length_mm': spec?.lengthMm,
        'width_mm': spec?.widthMm,
        'height_mm': spec?.heightMm,
        'details': {...car.toDetails(), ...res.toDetails()},
      };
      Future<void> store(Map<String, dynamic> f) => widget.addAnother ? s.addVehicle(f) : s.saveVehicle(f);
      try {
        await store(fields);
      } catch (e) {
        // A server that hasn't had the `details` migration yet must not stop
        // onboarding: save the car without the extra info.
        if (!e.toString().contains('details')) rethrow;
        await store({...fields}..remove('details'));
      }
      if (!mounted) return;
      if (widget.addAnother) {
        Navigator.of(context).pop();
      } else {
        await Notifications.requestPermission();
        if (!mounted) return;
        Navigator.of(context).pushAndRemoveUntil(MaterialPageRoute(builder: (_) => const TagScreen(firstTime: true)), (r) => false);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      final dup = e.toString().contains('duplicate');
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(dup ? tr('This car is already added.') : tr('Couldn\'t save. Check your internet and try again.')),
      ));
    }
  }

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(child: Text(k, style: DLText.small)),
          const SizedBox(width: 12),
          Flexible(child: Text(v, style: DLText.strong, textAlign: TextAlign.end)),
        ]),
      );

  Widget _step(String text, bool done) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(children: [
          done
              ? const Icon(Icons.check_circle, color: DL.success, size: 22)
              : const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
          const SizedBox(width: 12),
          Expanded(child: Text(text, style: done ? DLText.body : DLText.small)),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    final noPlate = _read && _plate.text.isEmpty;
    return Scaffold(
      appBar: AppBar(title: Text(widget.addAnother ? tr('Add another car') : tr('Your car'))),
      body: SafeArea(
        child: Form(
          key: _form,
          child: ListView(padding: const EdgeInsets.fromLTRB(20, 8, 20, 32), children: [
            Label(tr('Step 1 of 3')),
            const SizedBox(height: 8),
            Text(tr('Take a photo of your car'), style: DLText.title),
            const SizedBox(height: 8),
            Text(tr('Stand back so the whole car and its number plate are in the frame. We read the details from the photo, you type nothing.'),
                style: DLText.small),
            const SizedBox(height: 20),
            if (_photo != null)
              ClipRRect(borderRadius: BorderRadius.circular(DL.rCard), child: Image.file(_photo!, height: 200, width: double.infinity, fit: BoxFit.cover)),
            if (_photo != null) const SizedBox(height: 16),
            if (!_reading) ...[
              FilledButton.icon(
                onPressed: () => _pick(ImageSource.camera),
                icon: const Icon(Icons.photo_camera_outlined),
                label: Text(_photo == null ? tr('Photograph my car') : tr('Retake photo')),
              ),
              const SizedBox(height: 10),
              OutlinedButton.icon(
                onPressed: () => _pick(ImageSource.gallery),
                icon: const Icon(Icons.photo_library_outlined),
                label: Text(tr('Choose from gallery')),
              ),
            ],
            if (_reading || _read) ...[
              const SizedBox(height: 20),
              _step(tr('Reading the number plate on your phone'), _plateDone),
              _step(tr('Local AI is identifying the car'), _carDone),
              if (_reading) FootNote(tr('Local AI can take up to a minute the first time.'), icon: Icons.hourglass_empty),
            ],
            if (_read) ...[
              const SizedBox(height: 20),
              if (_modelDown) ...[
                FootNote(tr('The local AI isn\'t reachable right now, so please check the make and model below.'), icon: Icons.cloud_off_outlined),
                const SizedBox(height: 12),
              ],
              if (noPlate) ...[
                FootNote(tr('We couldn\'t read the plate. Retake the photo closer, or type it below.'), icon: Icons.info_outline),
                const SizedBox(height: 12),
              ],
              SectionCard(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  FieldLabel(tr('Number plate')),
                  TextFormField(
                    controller: _plate,
                    textCapitalization: TextCapitalization.characters,
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9 ]')),
                      LengthLimitingTextInputFormatter(14),
                      TextInputFormatter.withFunction((_, v) => v.copyWith(text: v.text.toUpperCase())),
                    ],
                    style: DLText.numeral.copyWith(fontSize: 24, letterSpacing: 2),
                    decoration: const InputDecoration(hintText: 'KA 01 AB 1234'),
                    validator: (v) {
                      final r = _norm(v ?? '');
                      if (!RegExp(r'^[A-Z]{2}\d{1,2}[A-Z]{0,3}\d{1,4}$').hasMatch(r) && !RegExp(r'^\d{2}BH\d{4}[A-Z]{1,2}$').hasMatch(r)) {
                        return tr('Enter the number as printed, e.g. KA 01 AB 1234');
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 16),
                  FieldLabel(tr('Make')),
                  TextFormField(
                    controller: _make,
                    textCapitalization: TextCapitalization.words,
                    decoration: InputDecoration(hintText: tr('Brand, e.g. Maruti Suzuki')),
                    validator: (v) => (v ?? '').trim().isEmpty ? tr('Enter the brand') : null,
                  ),
                  const SizedBox(height: 12),
                  FieldLabel(tr('Model')),
                  TextFormField(
                    controller: _model,
                    textCapitalization: TextCapitalization.words,
                    decoration: InputDecoration(hintText: tr('Model, e.g. Swift')),
                    validator: (v) => (v ?? '').trim().isEmpty ? tr('Enter the model') : null,
                  ),
                  if (_colour != null || _seen['body_type'] != null || _seen['features'] != null) ...[
                    const Divider(height: 28),
                    if (_colour != null) _kv(tr('Colour'), tr(_colour!)),
                    if (_seen['body_type'] != null) _kv(tr('Body type'), _seen['body_type']!),
                    if (_seen['features'] != null) _kv(tr('Notable'), _seen['features']!),
                  ],
                ]),
              ),
              const SizedBox(height: 8),
              FootNote(tr('Read from your photo. Fix anything that\'s wrong; the next step checks it against your RC.'), icon: Icons.auto_awesome_outlined),
              const SizedBox(height: 20),
              FilledButton(
                onPressed: _saving ? null : _next,
                child: _saving
                    ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.5, color: DL.muted))
                    : Text(tr('Next: verify RC')),
              ),
            ],
          ]),
        ),
      ),
    );
  }
}
