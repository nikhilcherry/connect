import 'package:connect/services/damage_cost.dart';
import 'package:flutter_test/flutter_test.dart';

DamageFinding f(DamageType t, {double score = 0.8, double area = 0.04}) {
  final side = area.clamp(0.0001, 1.0) == area ? (area == 0 ? 0.0 : _sqrt(area)) : 0.2;
  return DamageFinding(t, score, 0.1, 0.1, 0.1 + side, 0.1 + side);
}

double _sqrt(double v) {
  var x = v;
  for (var i = 0; i < 30; i++) {
    x = 0.5 * (x + v / x);
  }
  return x;
}

void main() {
  test('nothing found costs nothing', () {
    final e = estimateRepairCost([]);
    expect(e.isEmpty, isTrue);
    expect(e.low, 0);
    expect(e.high, 0);
  });

  test('findings below the confidence floor are ignored', () {
    expect(estimateRepairCost([f(DamageType.dent, score: 0.1)]).isEmpty, isTrue);
  });

  test('one medium dent on a mid-size mass-market car is inside the table range', () {
    final e = estimateRepairCost([f(DamageType.dent)], make: 'Maruti Suzuki', lengthMm: 4000);
    expect(e.lines.single.type, DamageType.dent);
    expect(e.low, 2000);
    expect(e.high, 6000);
  });

  test('a premium make and a large car cost more than a small hatchback', () {
    final hatch = estimateRepairCost([f(DamageType.scratch)], make: 'Maruti Suzuki', lengthMm: 3600);
    final luxury = estimateRepairCost([f(DamageType.scratch)], make: 'BMW', lengthMm: 4700);
    expect(luxury.low, greaterThan(hatch.low * 3));
    expect(luxury.high, greaterThan(hatch.high * 3));
    expect(luxury.notes, isNotEmpty);
  });

  test('a bigger damaged area is a bigger job', () {
    final small = estimateRepairCost([f(DamageType.dent, area: 0.01)]);
    final large = estimateRepairCost([f(DamageType.dent, area: 0.12)]);
    expect(large.high, greaterThan(small.high));
  });

  test('extra damage of the same kind overlaps instead of adding in full', () {
    final one = estimateRepairCost([f(DamageType.scratch)]);
    final three = estimateRepairCost([f(DamageType.scratch), f(DamageType.scratch), f(DamageType.scratch)]);
    expect(three.high, greaterThan(one.high));
    expect(three.high, lessThan(one.high * 3));
    expect(three.lines.single.count, 3);
  });

  test('different kinds add up and each gets its own line', () {
    final e = estimateRepairCost([f(DamageType.dent), f(DamageType.lampBroken), f(DamageType.scratch)]);
    expect(e.lines.map((l) => l.type), [DamageType.dent, DamageType.lampBroken, DamageType.scratch]);
    expect(e.low, greaterThan(2000 + 3500));
    expect(e.low % 100, 0);
  });

  test('low is never above high', () {
    for (final t in DamageType.values) {
      final e = estimateRepairCost([f(t)]);
      expect(e.low, lessThanOrEqualTo(e.high));
    }
  });

  test('the catalogue gives a car\'s length', () {
    expect(carDetails('Tata', 'Nexon').lengthMm, 3995);
    expect(carDetails('Tata', 'Nonexistent').lengthMm, isNull);
  });
}
