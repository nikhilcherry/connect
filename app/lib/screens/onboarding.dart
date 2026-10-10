import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/car_catalog.dart';
import '../data/models.dart';
import '../main.dart';
import '../l10n.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'car_photo_screen.dart';
import 'family_screen.dart';

class WelcomeScreen extends StatelessWidget {
  const WelcomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, box) => SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: box.maxHeight - 36),
              child: IntrinsicHeight(
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  const _Logo(),
                  const Spacer(),
                  const SizedBox(height: 32),
                  Label(tr('Free · no sign-up')),
                  const SizedBox(height: 12),
                  Text(tr('Anyone can reach you about your car.'), style: DLText.display),
                  const SizedBox(height: 14),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 440),
                    child: Text(tr('No phone number on the dashboard. Strangers scan your tag, you get the message.'),
                        style: DLText.body.copyWith(color: DL.muted)),
                  ),
                  const SizedBox(height: 32),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Column(children: [
                        _Point(Icons.lock_outline, tr('Your number stays private'), tr('Chat through Connect. Neither side sees a phone number.')),
                        const Divider(),
                        _Point(Icons.local_parking_outlined, tr('Blocked in? Lights on? Being towed?'), tr('People near your car tell you in two taps. No app needed.')),
                        const Divider(),
                        _Point(Icons.health_and_safety_outlined, tr('Help after a crash'), tr('Drive Mode alerts your family if your phone detects a crash.')),
                        const Divider(),
                        _Point(Icons.event_available_outlined, tr('Never miss a renewal'), tr('Reminders before PUC, insurance and service are due.')),
                      ]),
                    ),
                  ),
                  const Spacer(),
                  const SizedBox(height: 24),
                  FilledButton(
                    onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const CarPhotoScreen())),
                    child: Text(tr('Add my car')),
                  ),
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const JoinFamilyScreen())),
                    child: Text(tr('Join a family car with a code')),
                  ),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Logo extends StatelessWidget {
  const _Logo();
  @override
  Widget build(BuildContext context) {
    return Row(children: [
      Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(color: DL.ink, borderRadius: BorderRadius.circular(DL.rButton)),
        child: const Icon(Icons.link, color: DL.onDark, size: 22),
      ),
      const SizedBox(width: 10),
      Text('Connect', style: DLText.section.copyWith(fontFamily: 'SpaceGrotesk', fontWeight: FontWeight.w700)),
    ]);
  }
}

class _Point extends StatelessWidget {
  const _Point(this.icon, this.title, this.body);
  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        IconBadge(icon, size: 40),
        const SizedBox(width: 14),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: DLText.strong),
            const SizedBox(height: 2),
            Text(body, style: DLText.small),
          ]),
        ),
      ]),
    );
  }
}

// Stored in English (the scan page shows them); translated only for display.
const _colours = [/*t*/'White', /*t*/'Silver', /*t*/'Grey', /*t*/'Black', /*t*/'Red', /*t*/'Blue', /*t*/'Brown', /*t*/'Green', /*t*/'Orange', /*t*/'Yellow'];

/// Edit (from Garage) the owner's vehicle. Adding a car starts at [CarPhotoScreen].
class VehicleFormScreen extends StatefulWidget {
  const VehicleFormScreen({super.key, required Vehicle this.existing});
  final Vehicle? existing;

  @override
  State<VehicleFormScreen> createState() => _VehicleFormScreenState();
}

class _VehicleFormScreenState extends State<VehicleFormScreen> {
  final _form = GlobalKey<FormState>();
  late final _reg = TextEditingController(text: widget.existing?.regNumber ?? '');
  late final _make = TextEditingController(text: widget.existing?.make ?? '');
  late final _model = TextEditingController(text: widget.existing?.model ?? '');
  late final _nick = TextEditingController(text: widget.existing?.nickname ?? '');
  late String? _colour = widget.existing?.colour;
  CarSpec? _spec;
  late bool _manual = widget.existing != null;
  bool _saving = false;

  bool get _editing => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    if (e != null) {
      _spec = carCatalog.where((c) => c.make == e.make && c.model == e.model).firstOrNull;
    }
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    if (!mounted) return;
    if (!_manual && _spec == null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('Pick your car model, or enter it manually.'))));
      return;
    }
    setState(() => _saving = true);
    final s = AppScope.read(context);
    final make = _manual ? _make.text.trim() : _spec!.make;
    final model = _manual ? _model.text.trim() : _spec!.model;
    final spec = carCatalog.where((c) => c.make == make && c.model == model).firstOrNull;
    try {
      final fields = {
        'reg_number': _normaliseReg(_reg.text),
        'make': make,
        'model': model,
        'colour': _colour,
        'nickname': _nick.text.trim().isEmpty ? null : _nick.text.trim(),
        'length_mm': spec?.lengthMm ?? widget.existing?.lengthMm,
        'width_mm': spec?.widthMm ?? widget.existing?.widthMm,
        'height_mm': spec?.heightMm ?? widget.existing?.heightMm,
      };
      await s.saveVehicle(fields);
      if (!mounted) return;
      Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        final dup = e.toString().contains('duplicate');
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(dup ? tr('This car is already added.') : tr('Couldn\'t save. Check your internet and try again.')),
        ));
      }
    }
  }

  static String _normaliseReg(String s) => s.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(tr('Edit car'))),
      body: SafeArea(
        child: Form(
          key: _form,
          child: ListView(padding: const EdgeInsets.fromLTRB(20, 8, 20, 32), children: [
            FieldLabel(tr('Number plate')),
            TextFormField(
              controller: _reg,
              // The plate is what strangers are checked against; only the owner changes it.
              readOnly: _editing && !AppScope.read(context).isOwner,
              textCapitalization: TextCapitalization.characters,
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9 ]')),
                LengthLimitingTextInputFormatter(14),
                // Hardware keyboards ignore textCapitalization.
                TextInputFormatter.withFunction((_, v) => v.copyWith(text: v.text.toUpperCase())),
              ],
              style: DLText.numeral.copyWith(fontSize: 24, letterSpacing: 2),
              decoration: const InputDecoration(hintText: 'KA 01 AB 1234'),
              validator: (v) {
                final r = _normaliseReg(v ?? '');
                if (!RegExp(r'^[A-Z]{2}\d{1,2}[A-Z]{0,3}\d{1,4}$').hasMatch(r) &&
                    !RegExp(r'^\d{2}BH\d{4}[A-Z]{1,2}$').hasMatch(r)) {
                  return tr('Enter the number as printed, e.g. KA 01 AB 1234');
                }
                return null;
              },
            ),
            const SizedBox(height: 8),
            Text(tr('People scanning your tag type its last 4 characters. It\'s never shown to them.'), style: DLText.small),
            const SizedBox(height: 24),
            Row(children: [
              Expanded(child: Label(tr('Car model'))),
              TextButton(
                onPressed: () => setState(() => _manual = !_manual),
                child: Text(_manual ? tr('Pick from list') : tr('Not listed?')),
              ),
            ]),
            if (!_manual)
              Autocomplete<CarSpec>(
                initialValue: TextEditingValue(text: _spec?.name ?? ''),
                displayStringForOption: (c) => c.name,
                optionsBuilder: (v) {
                  final q = v.text.toLowerCase().trim();
                  if (q.isEmpty) return carCatalog;
                  return carCatalog.where((c) => c.name.toLowerCase().contains(q));
                },
                onSelected: (c) => setState(() => _spec = c),
                fieldViewBuilder: (context, controller, focus, onSubmit) => TextField(
                  controller: controller,
                  focusNode: focus,
                  onChanged: (_) {
                    if (_spec != null) setState(() => _spec = null);
                  },
                  decoration: InputDecoration(hintText: tr('Search, e.g. Swift, Nexon, Creta'), prefixIcon: const Icon(Icons.search_outlined)),
                ),
              )
            else ...[
              TextFormField(
                controller: _make,
                textCapitalization: TextCapitalization.words,
                decoration: InputDecoration(hintText: tr('Brand, e.g. Maruti Suzuki')),
                validator: (v) => (v ?? '').trim().isEmpty ? tr('Enter the brand') : null,
              ),
              const SizedBox(height: 10),
              TextFormField(
                controller: _model,
                textCapitalization: TextCapitalization.words,
                decoration: InputDecoration(hintText: tr('Model, e.g. Swift')),
                validator: (v) => (v ?? '').trim().isEmpty ? tr('Enter the model') : null,
              ),
            ],
            const SizedBox(height: 24),
            Label(tr('Colour')),
            const SizedBox(height: 8),
            Text(tr('Helps people confirm they found the right car.'), style: DLText.small),
            const SizedBox(height: 12),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final c in _colours)
                ChoiceChip(label: Text(tr(c)), selected: _colour == c, onSelected: (on) => setState(() => _colour = on ? c : null)),
            ]),
            const SizedBox(height: 24),
            FieldLabel(tr('Nickname (optional)')),
            TextField(
              controller: _nick,
              textCapitalization: TextCapitalization.sentences,
              maxLength: 40,
              decoration: InputDecoration(hintText: tr('e.g. Dad\'s car')),
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _saving ? null : _save,
              child: _saving
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.5, color: DL.muted))
                  : Text(tr('Save')),
            ),
          ]),
        ),
      ),
    );
  }
}
