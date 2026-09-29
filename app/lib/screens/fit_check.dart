import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/car_catalog.dart';
import '../l10n.dart';
import '../main.dart';
import '../theme.dart';
import '../widgets/common.dart';

enum Fit {
  // Tight is neutral, not amber: a results list can show dozens of them and
  // amber is allowed once per screen.
  comfortable(/*t*/'Fits', Tone.success, Icons.check_circle_outline),
  tight(/*t*/'Tight', Tone.neutral, Icons.error_outline),
  no(/*t*/'Won\'t fit', Tone.error, Icons.highlight_off);

  const Fit(this.label, this.tone, this.icon);
  final String label;
  final Tone tone;
  final IconData icon;
}

/// Space rules of thumb for a parking slot:
/// - length: 300 mm to spare is the minimum, 600 mm is comfortable;
/// - width: ~600 mm beside the car to open one door, ~1200 mm to open both;
/// - height: 50 mm is the minimum, 150 mm is comfortable (bumps, roof antennas).
({Fit fit, List<String> notes}) assess(CarSpec car, int slotL, int slotW, int? slotH) {
  final notes = <String>[];
  var worst = Fit.comfortable;
  void grade(Fit f) {
    if (f.index > worst.index) worst = f;
  }

  final dl = slotL - car.lengthMm;
  if (dl < 300) {
    grade(Fit.no);
    notes.add(dl < 0 ? tr('Car is {n} mm longer than the spot', {'n': -dl}) : tr('Only {n} mm to spare lengthwise', {'n': dl}));
  } else if (dl < 600) {
    grade(Fit.tight);
    notes.add(tr('{n} mm to spare lengthwise', {'n': dl}));
  }

  final dw = slotW - car.widthMm;
  if (dw < 600) {
    grade(Fit.no);
    notes.add(dw < 0 ? tr('Car is {n} mm wider than the spot', {'n': -dw}) : tr('Not enough room to open a door ({n} mm beside the car)', {'n': dw}));
  } else if (dw < 1200) {
    grade(Fit.tight);
    notes.add(tr('Room to open doors on one side only'));
  }

  if (slotH != null) {
    final dh = slotH - car.heightMm;
    if (dh < 50) {
      grade(Fit.no);
      notes.add(dh < 0 ? tr('Car is {n} mm taller than the clearance', {'n': -dh}) : tr('Only {n} mm under the barrier', {'n': dh}));
    } else if (dh < 150) {
      grade(Fit.tight);
      notes.add(tr('{n} mm headroom — watch for roof antennas and carriers', {'n': dh}));
    }
  }
  return (fit: worst, notes: notes);
}

class FitCheckScreen extends StatefulWidget {
  const FitCheckScreen({super.key});

  @override
  State<FitCheckScreen> createState() => _FitCheckScreenState();
}

class _FitCheckScreenState extends State<FitCheckScreen> {
  bool _feet = true;
  final _l = TextEditingController();
  final _w = TextEditingController();
  final _h = TextEditingController();

  @override
  void initState() {
    super.initState();
    for (final c in [_l, _w, _h]) {
      c.addListener(() => setState(() {}));
    }
  }

  int? _mm(TextEditingController c) {
    final v = double.tryParse(c.text.trim());
    if (v == null || v <= 0) return null;
    return (_feet ? v * 304.8 : v * 1000).round();
  }

  @override
  Widget build(BuildContext context) {
    final v = AppScope.of(context).vehicle;
    final mine = v == null
        ? null
        : carCatalog.where((c) => c.make == v.make && c.model == v.model).firstOrNull ??
            (v.lengthMm != null && v.widthMm != null && v.heightMm != null
                ? CarSpec(v.make, v.model, v.lengthMm!, v.widthMm!, v.heightMm!)
                : null);
    final l = _mm(_l), w = _mm(_w), h = _mm(_h);
    final ready = l != null && w != null;

    final ranked = ready
        ? (carCatalog.map((c) => (car: c, r: assess(c, l, w, h))).toList()
          ..sort((a, b) {
            final byFit = a.r.fit.index.compareTo(b.r.fit.index);
            return byFit != 0 ? byFit : b.car.lengthMm.compareTo(a.car.lengthMm);
          }))
        : const <({CarSpec car, ({Fit fit, List<String> notes}) r})>[];
    final fitting = ranked.where((x) => x.r.fit != Fit.no).length;

    InputDecoration dec(String hint) => InputDecoration(hintText: hint, suffixText: _feet ? 'ft' : 'm');
    final fmt = [FilteringTextInputFormatter.allow(RegExp(r'^\d{0,2}(\.\d{0,2})?'))];
    const numeric = TextInputType.numberWithOptions(decimal: true);

    return Scaffold(
      appBar: AppBar(title: Text(tr('Fit Check'))),
      body: SafeArea(
        child: ListView(padding: const EdgeInsets.fromLTRB(20, 8, 20, 32), children: [
          ScreenTitle(tr('Will it fit?')),
          const SizedBox(height: 8),
          Text(tr('Measure your parking spot or garage with a tape. We\'ll tell you what fits, which is handy before buying a car.'),
              style: DLText.body.copyWith(color: DL.muted)),
          const SizedBox(height: 24),
          SegmentedButton<bool>(
            segments: [ButtonSegment(value: true, label: Text(tr('Feet'))), ButtonSegment(value: false, label: Text(tr('Metres')))],
            selected: {_feet},
            onSelectionChanged: (s) => setState(() => _feet = s.first),
          ),
          const SizedBox(height: 20),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                FieldLabel(tr('Length')),
                TextField(controller: _l, keyboardType: numeric, inputFormatters: fmt, decoration: dec(tr('e.g. 16.5'))),
              ]),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                FieldLabel(tr('Width')),
                TextField(controller: _w, keyboardType: numeric, inputFormatters: fmt, decoration: dec(tr('e.g. 8'))),
              ]),
            ),
          ]),
          const SizedBox(height: 16),
          FieldLabel(tr('Height limit (optional)')),
          TextField(controller: _h, keyboardType: numeric, inputFormatters: fmt, decoration: dec(tr('Basement barrier or garage door'))),
          const SizedBox(height: 32),
          if (!ready)
            Text(tr('Enter length and width to see results.'), style: DLText.small)
          else ...[
            if (mine != null) ...[
              Label(tr('Your car')),
              const SizedBox(height: 12),
              _ResultCard(car: mine, result: assess(mine, l, w, h), highlight: true),
              const SizedBox(height: 32),
            ],
            Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Text('$fitting', style: DLText.numeral.copyWith(color: DL.violet)),
              const SizedBox(width: 8),
              Expanded(child: Text(tr('of {n} popular cars fit', {'n': carCatalog.length}), style: DLText.small)),
            ]),
            const SizedBox(height: 12),
            Card(
              clipBehavior: Clip.antiAlias,
              child: Column(children: [
                for (var i = 0; i < ranked.length; i++) ...[
                  if (i > 0) const Divider(),
                  _ResultCard(car: ranked[i].car, result: ranked[i].r),
                ],
              ]),
            ),
            const SizedBox(height: 12),
            Text(tr('Uses typical manufacturer dimensions; variants differ slightly. Mirrors are not included in width.'), style: DLText.small),
          ],
        ]),
      ),
    );
  }
}

class _ResultCard extends StatelessWidget {
  const _ResultCard({required this.car, required this.result, this.highlight = false});
  final CarSpec car;
  final ({Fit fit, List<String> notes}) result;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final f = result.fit;
    final content = Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(padding: const EdgeInsets.only(top: 2), child: Icon(f.icon, color: f.tone.mark, size: highlight ? 26 : 22)),
      const SizedBox(width: 12),
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(car.name, style: highlight ? DLText.section : DLText.strong),
          const SizedBox(height: 2),
          Text('${(car.lengthMm / 1000).toStringAsFixed(2)} × ${(car.widthMm / 1000).toStringAsFixed(2)} m', style: DLText.small),
          for (final n in result.notes) Text(n, style: DLText.small.copyWith(color: DL.ink)),
        ]),
      ),
      const SizedBox(width: 8),
      StatusBadge(tr(f.label), tone: f.tone),
    ]);
    return highlight
        ? SectionCard(child: content)
        : Padding(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14), child: content);
  }
}
