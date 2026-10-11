import 'dart:async';

import 'package:flutter/services.dart';

import '../data/app_state.dart';
import 'ble_link.dart';
import 'notifications.dart';
import 'whisper.dart';

/// Wires [BleLink] to the app: what a nearby phone shouts is kept, buzzed
/// about if it is for one of this phone's cars, and taken to the server as soon
/// as there is a signal. Same path as a message heard by sound.
class BleRelay {
  static Future<bool> start(AppState s) => BleLink.instance.start(
    // Only what has still to reach a server: once delivered (by anyone we
    // can see) it stops being repeated, which is what ends the gossip.
    carrying: () => [
      for (final h in WhisperStore.heard.value)
        if (h.state == WhisperState.carrying) h.whisper,
    ],
    onHeard: (w) async {
      final car = s.vehicles.where((v) => v.regNumber == w.plate).firstOrNull;
      if (!await WhisperStore.add(w, mine: car != null)) return;
      HapticFeedback.heavyImpact();
      if (car != null) Notifications.showWhisper(w.kind, car, w.nonce);
      unawaited(WhisperStore.flush(s.deliverWhisper));
    },
  );
}
