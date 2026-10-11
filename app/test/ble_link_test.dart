import 'package:connect/data/models.dart';
import 'package:connect/l10n.dart';
import 'package:connect/services/ble_link.dart';
import 'package:connect/services/whisper.dart';
import 'package:flutter_test/flutter_test.dart';

Whisper w(String plate, int n, {AlertKind k = AlertKind.blocking}) =>
    Whisper(plate: plate, kind: k, nonce: n, lang: AppLang.hi);

void main() {
  test('two whispers fit one advert and come back intact', () {
    final a = w('KA01AB1234', 1), b = w('KA05MX9999', 2, k: AlertKind.towing);
    final packed = BleCodec.pack([a, b])!;
    expect(packed.length, lessThanOrEqualTo(BleCodec.maxBytes));
    expect(BleCodec.unpack(packed), [a, b]);
  });

  test('one that does not fit is skipped, not truncated', () {
    final long = w('KA01AB12345', 1), long2 = w('KA05MX99991', 2);
    final packed = BleCodec.pack([long, long2])!;
    expect(BleCodec.unpack(packed), [long]);
  });

  test('rounds give every carried message a turn', () {
    final ws = [for (var i = 0; i < 5; i++) w('KA01AB123$i', i)];
    final got = BleCodec.rounds(ws).expand(BleCodec.unpack).toSet();
    expect(got, ws.toSet());
  });

  test('noise and foreign adverts are ignored', () {
    expect(BleCodec.unpack([]), isEmpty);
    expect(BleCodec.unpack([0x01, 0x02, 0x03]), isEmpty);
    expect(BleCodec.unpack([BleCodec.magic, 40, 1, 2]), isEmpty);
    expect(BleCodec.unpack([BleCodec.magic, 0]), isEmpty);
    expect(BleCodec.pack(const []), isNull);
  });
}
