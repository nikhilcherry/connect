import 'package:connect/services/situation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a damaged bumper reads as an urgent accident report', () {
    final s = interpretLabels({'Car': 0.95, 'Bumper': 0.8, 'Road surface': 0.6})!;
    expect(s.kind, 'accident');
    expect(s.urgency, Urgency.high);
    expect(s.note, isNotEmpty);
  });

  test('headlights point at lights_on', () {
    expect(interpretLabels({'Automotive lighting': 0.9, 'Car': 0.9})!.kind, 'lights_on');
  });

  test('a tow truck is urgent', () {
    final s = interpretLabels({'Tow truck': 0.7})!;
    expect(s.kind, 'towing');
    expect(s.urgency, Urgency.high);
  });

  test('a gate in frame suggests blocking', () {
    expect(interpretLabels({'Gate': 0.8, 'Car': 0.9})!.kind, 'blocking');
  });

  test('weak or unrelated labels give no suggestion', () {
    expect(interpretLabels({'Bumper': 0.3}), isNull);
    expect(interpretLabels({'Cat': 0.99}), isNull);
    expect(interpretLabels({}), isNull);
  });
}
