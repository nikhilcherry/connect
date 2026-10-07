import 'package:connect/services/plate_reader.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('reads a clean plate', () {
    expect(extractPlates('KA01AB1234'), contains('KA01AB1234'));
  });

  test('handles spaces, dashes and lowercase', () {
    expect(extractPlates('ka 01 ab-1234'), contains('KA01AB1234'));
  });

  test('plate split over two lines (two-row plates)', () {
    expect(extractPlates('KA 01\nAB 1234'), contains('KA01AB1234'));
  });

  test('repairs O/0 and I/1 confusions by position', () {
    expect(extractPlates('KAO1AB123Q'), contains('KA01AB1230'));
    expect(extractPlates('MH12DE1433'), contains('MH12DE1433'));
    // older Delhi-style plates (district number + letter) are real plates too
    expect(extractPlates('DL3C AB 1234'), contains('DL3CAB1234'));
    expect(extractPlates('DL 8S BT 6438'), contains('DL8SBT6438'));
    expect(extractPlates('DL3CD.1210'), contains('DL3CD1210'));
  });

  test('finds a plate inside surrounding text', () {
    expect(extractPlates('BHARAT\nTN09BX4567\nMotors'), contains('TN09BX4567'));
  });

  test('Bharat series', () {
    expect(extractPlates('22 BH 1234 AA'), contains('22BH1234AA'));
  });

  test('rejects text that is not a plate', () {
    expect(extractPlates('Hello world 12345'), isEmpty);
    expect(extractPlates('XX99ZZ9999'), isEmpty, reason: 'XX is not a state code');
  });
}
