import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// The two things the app asks of the phone itself that no plugin it already
/// uses offers (android/.../MainActivity.kt). Only Android answers; anywhere
/// else these quietly do nothing.
const _channel = MethodChannel('connect/device');

/// The phone's media volume, which decides how far a frame sent by sound
/// carries. A send borrows it and hands it back; with headphones or a
/// speaker attached it is left alone.
class MediaVolume {
  /// Raises the media volume to [fraction] of full for a send; returns what
  /// to pass to [restore], or null when nothing was changed.
  static Future<int?> borrow([double fraction = 1.0]) async {
    try {
      return await _channel.invokeMethod<int>('borrowVolume', fraction);
    } on MissingPluginException {
      return null;
    } catch (e) {
      debugPrint('volume: $e');
      return null;
    }
  }

  static Future<void> restore(int? previous) async {
    if (previous == null) return;
    try {
      await _channel.invokeMethod<void>('restoreVolume', previous);
    } catch (e) {
      debugPrint('volume: $e');
    }
  }
}

/// Keeps the screen from sleeping while a screen that has to stay awake is
/// open (Witness mode: the camera stops when the screen does).
class ScreenAwake {
  static Future<void> keep(bool on) async {
    try {
      await _channel.invokeMethod<void>('keepAwake', on);
    } on MissingPluginException {
      // not Android
    } catch (e) {
      debugPrint('keep awake: $e');
    }
  }
}
