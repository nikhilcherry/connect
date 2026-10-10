import 'package:connect/services/rc_check.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('plate on the RC text matches, tolerating one OCR slip', () {
    const text = 'CERTIFICATE OF REGISTRATION\nReg. No. KA 01 AB 1234\nOwner: R K';
    expect(rcTextMatchesPlate(text, 'KA01AB1234'), isTrue);
    expect(rcTextMatchesPlate(text.replaceAll('1234', '1Z34'), 'KA01AB1234'), isTrue);
  });
  test('a different plate or unrelated text is rejected', () {
    expect(rcTextMatchesPlate('Reg. No. KA 01 AB 9999', 'KA01AB1234'), isFalse);
    expect(rcTextMatchesPlate('hello world', 'KA01AB1234'), isFalse);
    expect(rcTextMatchesPlate('', 'KA01AB1234'), isFalse);
  });
}
