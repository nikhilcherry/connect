import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import '../config.dart';
import '../data/app_state.dart';

/// FCM push: alerts and society notices arrive even when the app is closed.
/// The system tray shows them (the server sends a notification payload on the
/// app's `alerts` / `society` channels), so no background Dart code runs.
class Push {
  /// Set when someone taps a push while the app is running or starting.
  static final opened = StreamController<Map<String, dynamic>>.broadcast();
  static RemoteMessage? _initial;

  static Future<void> init(AppState state) async {
    if (!Config.pushConfigured) return;
    try {
      await Firebase.initializeApp(
        options: const FirebaseOptions(
          apiKey: Config.firebaseApiKey,
          appId: Config.firebaseAppId,
          messagingSenderId: Config.firebaseSenderId,
          projectId: Config.firebaseProjectId,
        ),
      );
      final fcm = FirebaseMessaging.instance;
      await fcm.requestPermission();
      _initial = await fcm.getInitialMessage();
      FirebaseMessaging.onMessageOpenedApp.listen((m) => opened.add(m.data));
      // On screen, realtime already updates the app and raises a local
      // notification, so a foreground push only needs a refresh.
      FirebaseMessaging.onMessage.listen((_) => state.onForeground());
      fcm.onTokenRefresh.listen((t) => _register(state, t));
      final token = await fcm.getToken();
      if (token != null) await _register(state, token);
    } catch (e) {
      debugPrint('push init failed: $e');
    }
  }

  /// The push that launched the app, if any. Read once, after the first frame.
  static Map<String, dynamic>? takeInitial() {
    final d = _initial?.data;
    _initial = null;
    return d;
  }

  static Future<void> _register(AppState state, String token) async {
    // Registration needs a session; the first bootstrap may still be running.
    for (var i = 0; i < 10 && state.userId == null; i++) {
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    try {
      await state.registerPushToken(token);
    } catch (e) {
      debugPrint('push token registration failed: $e');
    }
  }
}
