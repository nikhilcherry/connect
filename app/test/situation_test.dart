import 'package:connect/services/damage_cost.dart';
import 'package:connect/services/situation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a crash or wreck reads as an urgent accident report', () {
    final s = interpretLabels({'Car': 0.95, 'Wreck': 0.8, 'Road': 0.6})!;
    expect(s.kind, 'accident');
    expect(s.urgency, Urgency.high);
    expect(s.note, isNotEmpty);
  });

  test('a tow truck is urgent', () {
    final s = interpretLabels({'Tow truck': 0.7})!;
    expect(s.kind, 'towing');
    expect(s.urgency, Urgency.high);
  });

  test('a gate in frame suggests blocking', () {
    expect(interpretLabels({'Gate': 0.8, 'Car': 0.9})!.kind, 'blocking');
  });

  test('an ordinary car photo gives no suggestion', () {
    // Labels ML Kit really returned for a plain parked car, measured on-device.
    final plain = {
      'Vehicle': 0.96, 'Car': 0.91, 'Wheel': 0.70, 'Road': 0.70, 'Bumper': 0.63,
      'Windshield': 0.55, 'Van': 0.42, 'Tire': 0.38, 'Asphalt': 0.34,
    };
    expect(interpretLabels(plain), isNull);
  });

  test('weak or unrelated labels give no suggestion', () {
    expect(interpretLabels({'Wreck': 0.3}), isNull);
    expect(interpretLabels({'Cat': 0.99}), isNull);
    expect(interpretLabels({}), isNull);
  });

  group('situationFromDamage', () {
    DamageFinding f(DamageType t, double score) => DamageFinding(t, score, 0.1, 0.1, 0.3, 0.3);
    String label(DamageType t) => t.label;
    String draft(String w) => 'I can see damage on your car: $w.';

    test('names what it found, counted, as an accident or damage report', () {
      final s = situationFromDamage([f(DamageType.scratch, 0.8), f(DamageType.scratch, 0.6), f(DamageType.dent, 0.5)], label: label, draft: draft)!;
      expect(s.kind, 'accident');
      expect(s.note, 'I can see damage on your car: scratch x2, dent.');
      expect(s.urgency, Urgency.normal);
    });

    test('shattered glass is urgent', () {
      expect(situationFromDamage([f(DamageType.glassShatter, 0.7)], label: label, draft: draft)!.urgency, Urgency.high);
    });

    test('low-confidence findings and the unreliable classes are ignored', () {
      expect(situationFromDamage([f(DamageType.dent, 0.2)], label: label, draft: draft), isNull);
      expect(situationFromDamage([f(DamageType.lampBroken, 0.9), f(DamageType.tireFlat, 0.9)], label: label, draft: draft), isNull);
      expect(situationFromDamage(const [], label: label, draft: draft), isNull);
    });
  });
}
