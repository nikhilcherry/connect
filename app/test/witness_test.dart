import 'package:connect/services/witness.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  final t0 = DateTime(2026, 10, 10, 0, 30);
  PlateSighting seen(String plate, int ms, [double confidence = 0.8]) => PlateSighting(plate, t0.add(Duration(milliseconds: ms)), confidence);

  group('the frames vote', () {
    test('a plate read the same way in most frames wins, and a one-character misread is the same car', () {
      final ranked = rankPlates([
        seen('KA01AB1234', 0),
        seen('KA01AB1234', 300),
        seen('KA01A81234', 600), // B read as 8
        seen('KA01AB1234', 900),
        seen('KA01AB123', 1200), // last digit cut off at the frame edge
        seen('MH12DE1433', 1500),
        seen('MH12DE1433', 1800),
      ]);
      expect(ranked.map((c) => c.plate), ['KA01AB1234', 'MH12DE1433']);
      expect(ranked.first.count, 5, reason: 'three exact readings and two near-misses');
      expect(ranked.first.firstSeen, t0);
      expect(ranked.first.lastSeen, t0.add(const Duration(milliseconds: 1200)));
      expect(ranked.last.count, 2);
    });

    test('a single unsure reading is not a car', () {
      expect(rankPlates([seen('TN09BC4521', 0, 0.6)]), isEmpty);
    });

    test('a single near-certain reading is', () {
      expect(rankPlates([seen('TN09BC4521', 0, 0.97)]).single.plate, 'TN09BC4521');
    });

    test('two different cars one digit apart are told apart by which was read more', () {
      // The weaker reading folds into the stronger; with a fleet of near-identical plates this
      // would hide a car, which is why the report shows the photos too.
      final ranked = rankPlates([seen('KA01AB1234', 0), seen('KA01AB1234', 1), seen('KA01AB1234', 2), seen('KA01AB1235', 3)]);
      expect(ranked.single.plate, 'KA01AB1234');
      expect(ranked.single.count, 4);
    });

    test('one character apart means exactly one', () {
      expect(oneCharacterApart('KA01AB1234', 'KA01A81234'), isTrue);
      expect(oneCharacterApart('KA01AB1234', 'KA01AB123'), isTrue);
      expect(oneCharacterApart('KA01AB1234', 'A01AB1234'), isTrue);
      expect(oneCharacterApart('KA01AB1234', 'KA01AB1234'), isFalse);
      expect(oneCharacterApart('KA01AB1234', 'KA01A81239'), isFalse);
      expect(oneCharacterApart('KA01AB1234', 'KA01AB12'), isFalse);
    });
  });

  group('the memory', () {
    test('keeps the last stretch and forgets what is older', () {
      final m = SightingMemory(keep: const Duration(seconds: 90));
      m.add(seen('KA01AB1234', 0));
      m.add(seen('KA01AB1234', 1000));
      m.add(seen('MH12DE1433', 100000));
      m.add(seen('MH12DE1433', 100300));
      expect(m.between(t0, t0.add(const Duration(minutes: 5))).map((s) => s.plate).toSet(), {'MH12DE1433'});
    });

    test('an incident takes the plates from before the bump and just after', () {
      final m = SightingMemory();
      m.add(seen('GJ05XY7788', 0)); // drove past half a minute earlier
      m.add(seen('GJ05XY7788', 300));
      m.add(seen('KA01AB1234', 28000)); // pulls in
      m.add(seen('KA01AB1234', 29000));
      final bump = t0.add(const Duration(seconds: 30));
      m.add(seen('KA01AB1234', 31000)); // still there
      m.add(seen('DL3CAB1234', 40000)); // someone else, later
      m.add(seen('DL3CAB1234', 40300));
      final around = rankPlates(m.between(bump.subtract(Incident.before), bump.add(Incident.after)));
      expect(around.single.plate, 'KA01AB1234');
      expect(around.single.count, 3);
    });
  });

  group('bumps', () {
    test('a knock over the threshold is a bump; its ringing is not a second one', () {
      final d = BumpDetector(level: BumpLevel.firm);
      expect(d.feed(0.05, t0), isFalse, reason: 'a parked car is nearly still');
      expect(d.feed(0.5, t0), isFalse, reason: 'under the level chosen');
      expect(d.feed(1.4, t0.add(const Duration(milliseconds: 20))), isTrue);
      expect(d.feed(1.1, t0.add(const Duration(milliseconds: 60))), isFalse);
      expect(d.feed(0.9, t0.add(const Duration(seconds: 3))), isFalse);
      expect(d.feed(0.9, t0.add(const Duration(seconds: 9))), isTrue);
    });

    test('the level can be changed while watching', () {
      final d = BumpDetector(level: BumpLevel.hard);
      expect(d.feed(1.0, t0), isFalse);
      d.level = BumpLevel.light;
      expect(d.feed(0.35, t0), isTrue);
    });

    test('every level is far below what Drive Mode calls a crash', () {
      expect(BumpLevel.values.every((l) => l.g < 4.0), isTrue);
      expect(BumpLevel.light.g < BumpLevel.firm.g && BumpLevel.firm.g < BumpLevel.hard.g, isTrue);
    });
  });

  test('incidents are still there after the app restarts, newest first', () async {
    SharedPreferences.setMockInitialValues({});
    WitnessLog.reset();
    final plates = rankPlates([seen('KA01AB1234', 0), seen('KA01AB1234', 300)]);
    await WitnessLog.add(Incident(at: t0, peakG: 1.3, plates: plates, photos: const ['/x/a.png']));
    await WitnessLog.add(Incident(at: t0.add(const Duration(hours: 1)), peakG: 0, plates: const [], manual: true));
    WitnessLog.reset();
    await WitnessLog.load();
    final back = WitnessLog.incidents.value;
    expect(back, hasLength(2));
    expect(back.first.manual, isTrue);
    expect(back.last.plates.single.plate, 'KA01AB1234');
    expect(back.last.plates.single.count, 2);
    expect(back.last.peakG, 1.3);
    expect(back.last.photos, ['/x/a.png']);
    expect(back.last.at, t0);
  });
}
