import 'package:connect/services/rc_mock.dart';
import 'package:connect/services/vehicle_read.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  adaptTests();
  test('makers and models match across how the RC and a photo name them', () {
    expect(sameMaker('MARUTI SUZUKI INDIA LTD', 'Maruti Suzuki'), isTrue);
    expect(sameMaker('Hyundai Motor India', 'Hyundai'), isTrue);
    expect(sameMaker('Tata Motors', 'Maruti Suzuki'), isFalse);
    expect(sameModel('SWIFT VXI', 'Swift'), isTrue);
    expect(sameModel('Creta SX(O)', 'Creta'), isTrue);
    expect(sameModel('Nexon XZ+', 'Swift'), isFalse);
  });

  test('colours come back in the app\'s own list', () {
    expect(canonicalColour('Dark Gray'), 'Grey');
    expect(canonicalColour('PEARL WHITE'), 'White');
    expect(canonicalColour('Purple'), isNull);
    expect(canonicalColour(null), isNull);
  });

  final demo = RcRecord.demo('KA01AB1234'); // a made-up record
  final real = RcRecord.fromServer('KA01AB1234', {
    'make': 'MARUTI SUZUKI INDIA LTD', 'model': 'SWIFT VXI', 'fuel': 'PETROL', 'mock': false,
  });

  test('against demo data any RC is accepted, a wrong plate only warns', () {
    for (final read in [
      {'plate': 'KA01AB1234', 'make': 'Zzz', 'chassis': 'MA3ABCDEF123456'},
      {'plate': 'MH12XY9999'},
      {'plate': null},
    ]) {
      final c = compareRc(plate: 'KA01AB1234', lookup: demo, read: read);
      expect(RcResult(rc: demo, read: const {}, checks: c, usedModel: true).accepted, isTrue);
    }
    expect(compareRc(plate: 'KA01AB1234', lookup: demo, read: {'plate': 'MH12XY9999'}).first.state, CheckState.warn);
  });

  test('against a real record a wrong registration number is rejected', () {
    expect(compareRc(plate: 'KA01AB1234', lookup: real, read: {'plate': 'MH12XY9999'}).first.state, CheckState.fail);
  });

  test('against a real record a different maker is rejected too', () {
    final good = compareRc(plate: 'KA01AB1234', lookup: real, read: {'plate': 'KA01AB1234', 'make': 'Maruti Suzuki', 'model': 'Swift'});
    expect(good.any((c) => c.state == CheckState.fail), isFalse);
    final wrong = compareRc(plate: 'KA01AB1234', lookup: real, read: {'plate': 'KA01AB1234', 'make': 'Tata Motors'});
    expect(wrong.any((c) => c.state == CheckState.fail), isTrue);
  });

  test('the car photo is compared with the RC, as a warning', () {
    final c = compareRc(
        plate: 'KA01AB1234', lookup: real, read: {'plate': 'KA01AB1234', 'make': 'Maruti Suzuki'},
        car: const CarRead(plate: 'KA01AB1234', make: 'Hyundai'));
    expect(c.last.state, CheckState.warn);
  });

  test('what is kept on the vehicle', () {
    final d = const CarRead(plate: 'KA01AB1234', bodyType: 'SUV', features: 'roof rails').toDetails();
    expect(d, {'body_type': 'SUV', 'features': 'roof rails'});
  });
}

void adaptTests() {
  test('a demo record is bent to the car seen, and then to the RC read', () {
    final d = RcRecord.demo('KA01AB1234').adaptedTo(make: 'Hyundai', model: 'Creta', colour: 'Red', fuel: 'diesel');
    expect(d.make, 'Hyundai');
    expect(d.colour, 'Red');
    expect(d.fuel, 'Diesel');
    expect(d.plate, 'KA01AB1234');
    final r = d.adaptedTo(owner: 'RAHUL KUMAR', chassis: 'MA3FJEB1S00123456', registered: '2021-03-15');
    expect(r.ownerMasked, 'RA*** KU***');
    expect(r.chassisLast4, '3456');
    expect(r.registered, DateTime(2021, 3, 15));
    final c = compareRc(plate: 'KA01AB1234', lookup: r, read: {'plate': 'KA01AB1234', 'owner': 'RAHUL KUMAR', 'chassis': 'MA3FJEB1S00123456', 'make': 'Hyundai'});
    expect(c.where((x) => x.state == CheckState.fail), isEmpty);
    expect(c.firstWhere((x) => x.label.startsWith('Owner')).state, CheckState.pass);
  });
}
