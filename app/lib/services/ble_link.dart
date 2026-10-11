import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_ble_peripheral/flutter_ble_peripheral.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'whisper.dart';

/// How whispers ride in a Bluetooth advertisement.
///
/// There is no connection and no pairing: a phone that is carrying messages
/// shouts them, every phone in range hears them. On a hill road two cars share
/// a link for a few seconds, which is too short to set up a connection but long
/// enough to hear a few adverts.
///
///   byte 0   0xC7, a Connect advert, format version 1
///   then     one or more of: a length byte, then that many bytes of
///            [Whisper.encode]
///
/// A legacy advert holds 31 bytes and the manufacturer header takes four of
/// them, so 27 are ours: two whispers for a ten-character plate, one for an
/// eleven-character one next to a short one.
class BleCodec {
  static const magic = 0xC7;

  /// Bluetooth SIG's company id for experiments, so no real vendor's filter matches.
  static const companyId = 0xFFFF;
  static const maxBytes = 27;

  /// As many of [ws] as fit, in order. Null when none do.
  static Uint8List? pack(Iterable<Whisper> ws) {
    final out = <int>[magic];
    for (final w in ws) {
      final b = w.encode();
      if (out.length + 1 + b.length > maxBytes) continue;
      out
        ..add(b.length)
        ..addAll(b);
    }
    return out.length == 1 ? null : Uint8List.fromList(out);
  }

  /// Every well-formed whisper in [data]; anything else is dropped, never thrown.
  static List<Whisper> unpack(List<int> data) {
    if (data.isEmpty || data[0] != magic) return const [];
    final found = <Whisper>[];
    var i = 1;
    while (i < data.length) {
      final n = data[i++];
      if (n == 0 || i + n > data.length) break;
      final w = Whisper.decode(data.sublist(i, i + n));
      if (w != null) found.add(w);
      i += n;
    }
    return found;
  }

  /// The carried messages in groups that each fit one advert, so everything gets a turn.
  static List<Uint8List> rounds(List<Whisper> ws) {
    final left = [...ws];
    final out = <Uint8List>[];
    while (left.isNotEmpty) {
      final packed = pack(left);
      if (packed == null) {
        left.removeAt(0);
        continue;
      }
      final took = unpack(packed);
      out.add(packed);
      left.removeWhere(took.contains);
    }
    return out;
  }
}

/// Phone-to-phone relay over Bluetooth Low Energy: no internet, no hardware.
///
/// Advertises the messages this phone is carrying and listens for others'.
/// What it hears goes to [onHeard], which stores it like a sound whisper, so a
/// message hops car to car down the hill until some phone has a signal and
/// delivers it.
class BleLink {
  BleLink._();
  static final instance = BleLink._();

  /// The company id and period are the only knobs; everything else is on the phone.
  static const turn = Duration(seconds: 2);

  final _radio = FlutterBlePeripheral();
  Timer? _timer;
  StreamSubscription<List<ScanResult>>? _scan;
  List<Whisper> Function()? _carrying;
  int _round = 0;
  bool _on = false;

  /// Whispers heard from other phones since [start], for the screen's counter.
  final heard = ValueNotifier<int>(0);

  /// True while the radio is up.
  final running = ValueNotifier<bool>(false);

  bool get isOn => _on;

  /// Starts both halves. [carrying] is asked afresh every turn so a message
  /// that has been delivered stops being repeated. Quietly does nothing, and
  /// returns false, on a phone without Bluetooth LE or without permission.
  Future<bool> start({
    required List<Whisper> Function() carrying,
    required FutureOr<void> Function(Whisper) onHeard,
  }) async {
    if (_on) return true;
    try {
      if (!await FlutterBluePlus.isSupported) return false;
      final granted = await _radio.requestPermission() == PeripheralBluetoothState.granted;
      if (!granted && !await _radio.isBluetoothOn) {
        return false;
      }
      _carrying = carrying;
      _on = true;
      _scan = FlutterBluePlus.onScanResults.listen((results) {
        for (final r in results) {
          final data = r.advertisementData.manufacturerData[BleCodec.companyId];
          if (data == null) continue;
          for (final w in BleCodec.unpack(data)) {
            heard.value++;
            unawaited(Future.sync(() => onHeard(w)));
          }
        }
      });
      await FlutterBluePlus.startScan(
        withMsd: [
          MsdFilter(BleCodec.companyId, data: [BleCodec.magic], mask: [0xFF]),
        ],
        continuousUpdates: true,
        continuousDivisor: 1,
        androidScanMode: AndroidScanMode.lowLatency,
        androidUsesFineLocation: false,
      );
      _timer = Timer.periodic(turn, (_) => _advertise());
      unawaited(_advertise());
      running.value = true;
      return true;
    } catch (e) {
      debugPrint('ble link did not start: $e');
      await stop();
      return false;
    }
  }

  Future<void> stop() async {
    _on = false;
    running.value = false;
    _timer?.cancel();
    _timer = null;
    await _scan?.cancel();
    _scan = null;
    try {
      await FlutterBluePlus.stopScan();
      await _radio.stop();
    } catch (e) {
      debugPrint('ble link stop: $e');
    }
  }

  Future<void> _advertise() async {
    if (!_on) return;
    try {
      final rounds = BleCodec.rounds(_carrying?.call() ?? const []);
      if (rounds.isEmpty) {
        if (await _radio.isAdvertising) await _radio.stop();
        return;
      }
      final payload = rounds[_round++ % rounds.length];
      if (await _radio.isAdvertising) await _radio.stop();
      await _radio.start(
        advertiseData: AdvertiseDataCore(
          manufacturerId: BleCodec.companyId,
          manufacturerData: payload,
        ),
        androidSettings: const AndroidAdvertiseSettings(
          advertiseSettings: AdvertiseSettings(),
        ),
      );
    } catch (e) {
      debugPrint('ble advert failed: $e');
    }
  }
}
