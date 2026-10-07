import '../data/car_catalog.dart';

/// What the damage detector can find, in the model's class order
/// (ml/README.md: 0 crack, 1 dent, 2 glass_shatter, 3 lamp_broken, 4 scratch, 5 tire_flat).
enum DamageType {
  crack(/*t*/'Crack', 'crack'),
  dent(/*t*/'Dent', 'dent'),
  glassShatter(/*t*/'Shattered glass', 'glass_shatter'),
  lampBroken(/*t*/'Broken lamp', 'lamp_broken'),
  scratch(/*t*/'Scratch', 'scratch'),
  tireFlat(/*t*/'Flat tyre', 'tire_flat');

  const DamageType(this.label, this.wire);
  final String label;
  final String wire;
}

/// One detected damaged area; the box is normalised 0..1 in the photo.
class DamageFinding {
  const DamageFinding(this.type, this.score, this.left, this.top, this.right, this.bottom);
  final DamageType type;
  final double score;
  final double left, top, right, bottom;
  double get areaFraction => ((right - left) * (bottom - top)).clamp(0.0, 1.0);
}

/// Rough INR repair cost for ONE job of each kind on a small mass-market car at a
/// typical Indian garage, as (low, high). **Hand-set indicative figures, not learned
/// from data and not a quote**: change them here and nowhere else.
const baseCostInr = <DamageType, (int, int)>{
  DamageType.scratch: (800, 2500), // polish / touch-up up to a panel repaint
  DamageType.dent: (2000, 6000), // paintless dent removal up to panel beating + paint
  DamageType.crack: (3000, 9000), // bumper or trim repair up to replacement
  DamageType.glassShatter: (5000, 18000), // side/rear glass up to a windscreen
  DamageType.lampBroken: (3500, 15000), // lamp unit
  DamageType.tireFlat: (600, 5500), // puncture repair up to a new tyre
};

const _luxury = {'BMW', 'Mercedes-Benz', 'Mercedes', 'Audi', 'Volvo', 'Jaguar', 'Land Rover', 'Lexus', 'Porsche', 'Mini'};
const _upper = {'Skoda', 'Volkswagen', 'Jeep', 'Citroen', 'Citroën'};
const _mid = {'Toyota', 'Honda', 'Kia', 'MG', 'Nissan', 'Renault'};

/// How much dearer parts and labour are than for a small mass-market car.
({double size, double brand}) costFactors({String? make, int? lengthMm}) {
  final l = lengthMm ?? 4000;
  final size = l < 3900 ? 0.85 : (l < 4300 ? 1.0 : (l < 4600 ? 1.25 : 1.55));
  final m = make ?? '';
  final brand = _luxury.contains(m) ? 2.2 : (_upper.contains(m) ? 1.3 : (_mid.contains(m) ? 1.1 : 1.0));
  return (size: size, brand: brand);
}

class CostLine {
  const CostLine(this.type, this.count, this.low, this.high);
  final DamageType type;
  final int count;
  final int low, high;
}

class CostEstimate {
  const CostEstimate(this.lines, this.low, this.high, this.notes);
  final List<CostLine> lines;
  final int low, high;
  final List<String> notes;
  bool get isEmpty => lines.isEmpty;
}

int _round100(num v) => ((v / 100).round() * 100).toInt();

/// An indicative repair cost range from what was found, the car, and how large each
/// damaged area is in the photo. Several areas of the same kind overlap in labour (one
/// paint job covers neighbouring panels), so each extra one of a kind costs 70% of
/// the one before. Never presented as a quote.
CostEstimate estimateRepairCost(List<DamageFinding> findings, {String? make, int? lengthMm, double minScore = 0.3}) {
  final f = findings.where((x) => x.score >= minScore).toList();
  if (f.isEmpty) return const CostEstimate([], 0, 0, []);
  final k = costFactors(make: make, lengthMm: lengthMm);
  final lines = <CostLine>[];
  var low = 0.0, high = 0.0;
  for (final type in DamageType.values) {
    final mine = f.where((x) => x.type == type).toList()..sort((a, b) => b.areaFraction.compareTo(a.areaFraction));
    if (mine.isEmpty) continue;
    final (bl, bh) = baseCostInr[type]!;
    var l = 0.0, h = 0.0, decay = 1.0;
    for (final d in mine) {
      // a large damaged area is a bigger job than a small one
      final a = d.areaFraction;
      final sev = a < 0.02 ? 0.8 : (a < 0.08 ? 1.0 : 1.5);
      l += bl * k.size * k.brand * sev * decay;
      h += bh * k.size * k.brand * sev * decay;
      decay *= 0.7;
    }
    lines.add(CostLine(type, mine.length, _round100(l), _round100(h)));
    low += l;
    high += h;
  }
  final notes = <String>[
    if (k.brand > 1.2) /*t*/'Premium make: parts and paint cost more.',
    if (lengthMm != null && lengthMm >= 4600) /*t*/'Large car: bigger panels cost more to repair.',
  ];
  return CostEstimate(lines, _round100(low), _round100(high), notes);
}

/// The size/brand inputs from the user's saved car, when it is in the catalogue.
({String? make, int? lengthMm}) carDetails(String? make, String? model) {
  final spec = carCatalog.where((c) => c.make == make && c.model == model).firstOrNull;
  return (make: make, lengthMm: spec?.lengthMm);
}
