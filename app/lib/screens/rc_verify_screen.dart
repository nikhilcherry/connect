import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../l10n.dart';
import '../main.dart';
import '../services/rc_check.dart';
import '../services/rc_mock.dart';
import '../services/vehicle_read.dart';
import '../theme.dart';
import '../widgets/common.dart';

enum _Step { looking, details, upload, checking, rejected, done }

/// Step 2 of onboarding. Shows what the RC database says about the plate,
/// asks for the owner's own Registration Certificate, has the local vision
/// model read it, compares the two (and the car photo), and only then lets
/// them continue. Pops with the [RcResult], or null.
class RcVerifyScreen extends StatefulWidget {
  const RcVerifyScreen({super.key, required this.plate, this.car});
  final String plate;
  final CarRead? car;

  @override
  State<RcVerifyScreen> createState() => _RcVerifyScreenState();
}

class _RcVerifyScreenState extends State<RcVerifyScreen> {
  _Step _step = _Step.looking;
  RcRecord? _rc;
  RcResult? _result;
  int _shown = 0; // how many comparison lines have been revealed so far
  File? _photo;

  @override
  void initState() {
    super.initState();
    _lookup();
  }

  Future<void> _lookup() async {
    var rc = await AppScope.read(context).lookupRc(widget.plate);
    // Demo records look like the car in the photo, not a random one.
    final car = widget.car;
    if (rc.mock && car != null) {
      rc = rc.adaptedTo(make: car.make, model: car.model, colour: car.colour, fuel: car.fuel);
    }
    // A beat of "looking up" so the step is visible, not a flash.
    await Future<void>.delayed(const Duration(milliseconds: 900));
    if (!mounted) return;
    setState(() {
      _rc = rc;
      _step = _Step.details;
    });
  }

  Future<void> _pick(ImageSource src) async {
    final f = await ImagePicker().pickImage(source: src, maxWidth: 1024, imageQuality: 85);
    if (f == null || !mounted) return;
    final s = AppScope.read(context);
    final file = File(f.path);
    setState(() {
      _photo = file;
      _step = _Step.checking;
      _shown = 0;
      _result = null;
    });
    // The local model reads every field off the RC. If it can't be reached,
    // the phone's own text reader still confirms the registration number.
    var read = await s.visionRead('rc', await file.readAsBytes());
    final usedModel = read != null;
    if (read == null) {
      bool ok;
      try {
        ok = await rcPhotoMatches(file, widget.plate);
      } catch (_) {
        ok = false;
      }
      read = {'plate': ok ? widget.plate : null};
    }
    if (!mounted) return;
    // A demo record is made to agree with the RC the owner just showed (all
    // but the plate, which stays as typed); a real one is left alone.
    var lookup = _rc!;
    if (lookup.mock) {
      lookup = lookup.adaptedTo(
          make: read['make'], model: read['model'], fuel: read['fuel'], colour: read['colour'], owner: read['owner'],
          chassis: read['chassis'], engine: read['engine'], registered: read['registered']);
    }
    final checks = compareRc(plate: widget.plate, lookup: lookup, read: read, car: widget.car);
    final result = RcResult(rc: lookup, read: read, checks: checks, usedModel: usedModel);
    setState(() => _result = result);
    for (var i = 1; i <= checks.length; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 350));
      if (!mounted) return;
      setState(() => _shown = i);
    }
    await Future<void>.delayed(const Duration(milliseconds: 350));
    if (mounted) setState(() => _step = result.accepted ? _Step.done : _Step.rejected);
  }

  String _date(DateTime d) {
    const m = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${d.day} ${m[d.month - 1]} ${d.year}';
  }

  Widget _checkRow(RcCheck c, {required bool shown}) {
    final (icon, color) = switch (c.state) {
      CheckState.pass => (Icons.check_circle, DL.success),
      CheckState.warn => (Icons.error_outline, DL.amber),
      CheckState.fail => (Icons.cancel, DL.error),
      CheckState.skip => (Icons.remove_circle_outline, DL.muted),
    };
    final note = switch (c.state) {
      CheckState.skip => c.detail == null ? tr('Not readable on the RC') : tr('Can\'t be confirmed against demo data'),
      CheckState.warn => tr('Doesn\'t match, worth a look'),
      CheckState.fail => c.detail == null ? tr('Not found on the RC') : tr('Doesn\'t match'),
      CheckState.pass => c.detail,
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        shown ? Icon(icon, color: color, size: 22) : const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(tr(c.label), style: shown ? DLText.body : DLText.small),
            if (shown && note != null) Text(note, style: DLText.small),
          ]),
        ),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final rc = _rc;
    final res = _result;
    return Scaffold(
      appBar: AppBar(title: Text(tr('Verify ownership'))),
      body: SafeArea(
        child: ListView(padding: const EdgeInsets.fromLTRB(20, 8, 20, 32), children: [
          Label(tr('Step 2 of 3')),
          const SizedBox(height: 8),
          Text(widget.plate, style: DLText.numeral.copyWith(fontSize: 28, letterSpacing: 3)),
          const SizedBox(height: 16),
          if (_step == _Step.looking) ...[
            const SizedBox(height: 40),
            const Center(child: CircularProgressIndicator(strokeWidth: 2.5)),
            const SizedBox(height: 16),
            Center(child: Text(tr('Checking the RC database…'), style: DLText.small)),
          ] else if (rc != null) ...[
            SectionCard(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Expanded(child: Text('${rc.make} ${rc.model}', style: DLText.strong)),
                  StatusBadge(tr('RC found'), tone: Tone.success),
                ]),
                const SizedBox(height: 4),
                Text('${rc.fuel} · ${rc.colour} · ${rc.norms}', style: DLText.small),
                const Divider(height: 28),
                _row(tr('Registered'), _date(rc.registered)),
                _row(tr('RTO'), rc.rto),
                _row(tr('Insurance until'), _date(rc.insuranceUpto), ok: rc.insured),
                _row(tr('Fitness until'), _date(rc.fitnessUpto)),
                _row(tr('Pollution (PUC) until'), _date(rc.pucUpto), ok: rc.pucValid),
                _row(tr('Registered owner'), rc.ownerMasked),
                _row(tr('Hypothecation'), rc.financed ? tr('Active loan') : tr('None')),
              ]),
            ),
            if (rc.mock) ...[
              const SizedBox(height: 10),
              FootNote(tr('Demo data: no RC provider is connected yet.'), icon: Icons.science_outlined),
            ],
            const SizedBox(height: 20),
            if (_step == _Step.details)
              FilledButton(onPressed: () => setState(() => _step = _Step.upload), child: Text(tr('This is my car'))),
            if (_step == _Step.upload) ...[
              Text(tr('Now prove it\'s yours'), style: DLText.title),
              const SizedBox(height: 8),
              Text(tr('Photograph the front of your Registration Certificate (RC), or upload it from DigiLocker. Local AI reads it and we compare it with the record above. We don\'t keep the photo.'),
                  style: DLText.small),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: () => _pick(ImageSource.camera),
                icon: const Icon(Icons.photo_camera_outlined),
                label: Text(tr('Photograph RC')),
              ),
              const SizedBox(height: 10),
              OutlinedButton.icon(
                onPressed: () => _pick(ImageSource.gallery),
                icon: const Icon(Icons.upload_file_outlined),
                label: Text(tr('Choose from gallery')),
              ),
            ],
            if (_step == _Step.checking || _step == _Step.done || _step == _Step.rejected) ...[
              if (_photo != null)
                ClipRRect(borderRadius: BorderRadius.circular(DL.rCard), child: Image.file(_photo!, height: 140, width: double.infinity, fit: BoxFit.cover)),
              const SizedBox(height: 16),
              Text(
                  switch (_step) {
                    _Step.done => tr('Ownership confirmed'),
                    _Step.rejected => tr('This RC doesn\'t match'),
                    _ => res == null ? tr('Local AI is reading your RC…') : tr('Comparing with the RC lookup…'),
                  },
                  style: DLText.title),
              const SizedBox(height: 12),
              if (res == null) ...[
                const Padding(padding: EdgeInsets.symmetric(vertical: 16), child: Center(child: CircularProgressIndicator(strokeWidth: 2.5))),
                FootNote(tr('Local AI can take up to a minute the first time.'), icon: Icons.hourglass_empty),
              ]
              else ...[
                for (var i = 0; i < res.checks.length; i++) _checkRow(res.checks[i], shown: i < _shown),
                if (!res.usedModel && _step != _Step.checking) ...[
                  const SizedBox(height: 8),
                  FootNote(tr('The local AI wasn\'t reachable, so only the registration number was checked.'), icon: Icons.cloud_off_outlined),
                ],
              ],
              if (_step == _Step.rejected) ...[
                const SizedBox(height: 12),
                Text(tr('Make sure the whole front of the RC is in frame, well lit and not blurred, and that it is the RC for {plate}.', {'plate': widget.plate}),
                    style: DLText.small),
                const SizedBox(height: 16),
                FilledButton(onPressed: () => setState(() => _step = _Step.upload), child: Text(tr('Try again'))),
              ],
              if (_step == _Step.done) ...[
                const SizedBox(height: 20),
                FilledButton(onPressed: () => Navigator.of(context).pop(res), child: Text(tr('Continue'))),
              ],
            ],
          ],
        ]),
      ),
    );
  }

  Widget _row(String k, String v, {bool? ok}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(children: [
          Expanded(child: Text(k, style: DLText.small)),
          if (ok != null) Padding(padding: const EdgeInsets.only(right: 6), child: Icon(ok ? Icons.check_circle : Icons.error_outline, size: 16, color: ok ? DL.success : DL.amber)),
          Text(v, style: DLText.strong),
        ]),
      );
}
