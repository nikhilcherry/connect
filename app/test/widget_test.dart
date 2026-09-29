import 'package:connect/config.dart';
import 'package:connect/data/car_catalog.dart';
import 'package:connect/data/models.dart';
import 'package:connect/screens/fit_check.dart';
import 'package:connect/screens/parking_screen.dart';
import 'package:connect/services/parking.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Fit Check', () {
    const swift = CarSpec('Maruti Suzuki', 'Swift', 3860, 1735, 1520);
    const fortuner = CarSpec('Toyota', 'Fortuner', 4795, 1855, 1835);

    test('a standard 5 m x 2.5 m slot fits a hatchback comfortably', () {
      expect(assess(swift, 5000, 3000, null).fit, Fit.comfortable);
    });

    test('a big SUV in the same slot is tight lengthwise', () {
      final r = assess(fortuner, 5000, 3100, null);
      expect(r.fit, Fit.no);
      expect(r.notes.single, contains('205 mm'));
    });

    test('a 1.8 m basement barrier stops a Fortuner but not a Swift', () {
      expect(assess(fortuner, 6000, 3200, 1800).fit, Fit.no);
      expect(assess(swift, 6000, 3200, 1800).fit, Fit.comfortable);
    });

    test('width that only lets one door open is tight', () {
      expect(assess(swift, 5000, 2500, null).fit, Fit.tight);
    });

    test('catalog dimensions are within the database CHECK ranges', () {
      for (final c in carCatalog) {
        expect(c.lengthMm, inInclusiveRange(2000, 7000), reason: c.name);
        expect(c.widthMm, inInclusiveRange(1000, 2600), reason: c.name);
        expect(c.heightMm, inInclusiveRange(1000, 2600), reason: c.name);
      }
    });
  });

  test('registration numbers are spaced for display', () {
    Vehicle v(String reg) => Vehicle(id: 'x', owner: 'u', regNumber: reg, make: 'm', model: 'm');
    expect(v('KA01AB1234').prettyReg, 'KA 01 AB 1234');
    expect(v('DL3CAB1234').prettyReg, 'DL 3 CAB 1234');
    expect(v('22BH1234AA').prettyReg, '22BH1234AA');
  });

  group('Back by', () {
    Vehicle v(DateTime? backAt) => Vehicle(id: 'x', owner: 'u', regNumber: 'KA01AB1234', make: 'm', model: 'm', backAt: backAt);

    test('status shows only while the time is in the future', () {
      expect(v(DateTime.now().add(const Duration(minutes: 5))).isAway, isTrue);
      expect(v(DateTime.now().subtract(const Duration(minutes: 1))).isAway, isFalse);
      expect(v(null).isAway, isFalse);
    });

    test('a picked time earlier than now means tomorrow', () {
      final now = DateTime(2026, 9, 17, 22, 0);
      expect(nextOccurrence(const TimeOfDay(hour: 23, minute: 30), now: now), DateTime(2026, 9, 17, 23, 30));
      expect(nextOccurrence(const TimeOfDay(hour: 1, minute: 15), now: now), DateTime(2026, 9, 18, 1, 15));
    });
  });

  group('Parking', () {
    test('a spot survives being saved and loaded', () {
      final spot = ParkingSpot(
        savedAt: DateTime(2026, 9, 17, 18, 5),
        lat: 12.9716,
        lng: 77.5946,
        accuracyM: 8,
        note: 'B2, pillar 14',
        meterEndsAt: DateTime(2026, 9, 17, 20),
      );
      final back = ParkingSpot.fromJson(spot.toJson());
      expect(back.lat, 12.9716);
      expect(back.note, 'B2, pillar 14');
      expect(back.meterEndsAt, DateTime(2026, 9, 17, 20));
      expect(back.photoPath, isNull);
    });

    test('walking directions are a plain maps link, no API key', () {
      final spot = ParkingSpot(savedAt: DateTime(2026), lat: 12.9716, lng: 77.5946);
      expect(spot.directionsUrl.toString(),
          'https://www.google.com/maps/dir/?api=1&destination=12.971600,77.594600&travelmode=walking');
      expect(ParkingSpot(savedAt: DateTime(2026)).hasLocation, isFalse);
    });

    test('time left reads naturally', () {
      expect(formatDuration(const Duration(minutes: 42)), '42 min');
      expect(formatDuration(const Duration(hours: 1, minutes: 5)), '1 h 5 min');
    });
  });

  test('printed tags point at connect.example.com/t/CODE', () {
    // Run without --dart-define=SCAN_BASE_URL, as release builds are.
    expect(Config.tagUrl('EE5WRD6P'), 'https://connect.example.com/t/EE5WRD6P');
  });
}
