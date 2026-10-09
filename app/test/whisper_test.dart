import 'package:connect/data/models.dart';
import 'package:connect/l10n.dart';
import 'package:connect/services/acoustic_modem.dart';
import 'package:connect/services/whisper.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('what goes through the air', () {
    test('a plate and a reason survive the trip', () {
      for (final plate in ['KA01AB1234', '22BH1234AA', 'DL3CAB1234', 'MH12A1', 'KA01ABC1234']) {
        for (final kind in AlertKind.values) {
          final w = Whisper(plate: plate, kind: kind, nonce: 0xBEEF, lang: AppLang.kn);
          final bytes = w.encode();
          expect(bytes.length, lessThanOrEqualTo(AcousticModem.maxPayload), reason: plate);
          expect(Whisper.decode(bytes), w, reason: '$plate $kind');
        }
      }
    });

    test('a ten-character plate makes a frame of about two seconds', () {
      final bytes = const Whisper(plate: 'KA01AB1234', kind: AlertKind.lightsOn, nonce: 1).encode();
      expect(bytes, hasLength(12));
      expect(const AcousticModem(ModemProfile.ultrasonic).frameTime(bytes.length).inMilliseconds, inInclusiveRange(1800, 2300));
    });

    test('it also survives the modem', () {
      const w = Whisper(plate: 'TN09BC4521', kind: AlertKind.towing, nonce: 513, lang: AppLang.ta);
      const modem = AcousticModem(ModemProfile.ultrasonic);
      expect(Whisper.decode(modem.decode(modem.encode(w.encode()))!), w);
    });

    test('anything else is not an alert', () {
      final good = const Whisper(plate: 'KA01AB1234', kind: AlertKind.blocking, nonce: 7).encode();
      expect(Whisper.decode([...good]..[0] = 0x12), isNull, reason: 'a later format version');
      expect(Whisper.decode([...good]..[1] = 0x0F), isNull, reason: 'a reason that does not exist');
      expect(Whisper.decode([...good]..[1] = 0x70), isNull, reason: 'a language that does not exist');
      expect(Whisper.decode(good.sublist(0, 6)), isNull, reason: 'too short to hold a plate');
      expect(Whisper.decode([...good]..[4] = 0xFF), isNull, reason: 'not a letter or a digit');
      expect(Whisper.decode(const WhisperAck(7, owner: true).encode()), isNull);
    });

    test('padding inside a plate is refused', () {
      // Eight six-bit codes: K, A, a pad, then 0 1 A B 1. Nobody packs that, so nobody should read it.
      List<int> bytesOf(List<int> codes) {
        final bits = codes.map((c) => c.toRadixString(2).padLeft(6, '0')).join();
        return [for (var i = 0; i < bits.length; i += 8) int.parse(bits.substring(i, i + 8), radix: 2)];
      }

      expect(unpackPlate(bytesOf([21, 11, 1, 2, 11, 12, 2, 0])), 'KA01AB1', reason: 'a pad at the end is how a short plate is packed');
      expect(packPlate('KA01AB1'), bytesOf([21, 11, 1, 2, 11, 12, 2, 0]));
      expect(unpackPlate(bytesOf([21, 11, 0, 1, 2, 11, 12, 2])), isNull);
      expect(unpackPlate(bytesOf([21, 11, 1, 2, 11, 12, 2, 37])), isNull, reason: '37 and up mean nothing');
    });

    test('the answer says who heard', () {
      expect(WhisperAck.decode(const WhisperAck(0xBEEF, owner: true).encode())!.owner, isTrue);
      final carried = WhisperAck.decode(const WhisperAck(0xBEEF, owner: false).encode())!;
      expect(carried.owner, isFalse);
      expect(carried.nonce, 0xBEEF);
      expect(WhisperAck.decode(const Whisper(plate: 'KA01AB1234', kind: AlertKind.other, nonce: 1).encode()), isNull);
      expect(WhisperAck.decode([0x21, 0, 1, 9]), isNull);
    });

    test('every phone that heard it gives the server the same reference', () {
      const w = Whisper(plate: 'KA01AB1234', kind: AlertKind.lightsOn, nonce: 0x0A1B);
      final here = DateTime.utc(2026, 10, 9, 18, 0), there = DateTime.utc(2026, 10, 9, 18, 0, 40).toLocal();
      expect(w.ref(here), 'snd-20261009-1-0a1b');
      expect(w.ref(there), w.ref(here));
      expect(w.ref(here), matches(RegExp(r'^[A-Za-z0-9:_-]{6,64}$')), reason: 'the shape the scan function accepts');
      expect(const Whisper(plate: 'KA01AB1234', kind: AlertKind.towing, nonce: 0x0A1B).ref(here), isNot(w.ref(here)));
      expect(w.kindWire, 'lights_on');
    });
  });

  group('what a phone carries', () {
    const w1 = Whisper(plate: 'KA01AB1234', kind: AlertKind.lightsOn, nonce: 1);
    const w2 = Whisper(plate: 'KA05MN4321', kind: AlertKind.blocking, nonce: 2);
    const w3 = Whisper(plate: 'MH12DE1433', kind: AlertKind.towing, nonce: 3);

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      WhisperStore.reset();
    });

    test('a message repeated by its sender is kept once', () async {
      final t = DateTime(2026, 10, 9, 23);
      expect(await WhisperStore.add(w1, mine: false, now: t), isTrue);
      expect(await WhisperStore.add(w1, mine: false, now: t.add(const Duration(seconds: 5))), isFalse);
      expect(await WhisperStore.add(w2, mine: true, now: t), isTrue);
      expect(WhisperStore.heard.value.map((h) => h.whisper.plate), ['KA05MN4321', 'KA01AB1234'], reason: 'newest first');
    });

    test('what it carries is still there after the app restarts', () async {
      await WhisperStore.add(w1, mine: true);
      await WhisperStore.add(w2, mine: false, own: true);
      WhisperStore.reset();
      await WhisperStore.load();
      final back = WhisperStore.heard.value;
      expect(back.map((h) => h.whisper), [w2, w1]);
      expect(back.first.own, isTrue);
      expect(back.last.mine, isTrue);
      expect(back.every((h) => h.state == WhisperState.carrying), isTrue);
    });

    test('with no signal everything waits; with one, each message is settled once', () async {
      await WhisperStore.add(w1, mine: false);
      await WhisperStore.add(w2, mine: false);
      await WhisperStore.add(w3, mine: false);

      final tried = <String>[];
      await WhisperStore.flush((h) async {
        tried.add(h.whisper.plate);
        return Delivery.later;
      });
      expect(tried, ['KA01AB1234'], reason: 'oldest first, and no point trying the rest without a signal');
      expect(WhisperStore.heard.value.every((h) => h.state == WhisperState.carrying), isTrue);

      tried.clear();
      await WhisperStore.flush((h) async {
        tried.add(h.whisper.plate);
        return h.whisper == w2 ? Delivery.unknownCar : Delivery.delivered;
      });
      expect(tried, ['KA01AB1234', 'KA05MN4321', 'MH12DE1433']);
      String state(Whisper w) => WhisperStore.heard.value.firstWhere((h) => h.whisper == w).state.name;
      expect([state(w1), state(w2), state(w3)], ['delivered', 'unknownCar', 'delivered']);

      tried.clear();
      await WhisperStore.flush((h) async {
        tried.add(h.whisper.plate);
        return Delivery.delivered;
      });
      expect(tried, isEmpty, reason: 'nothing is delivered twice');
    });
  });
}
