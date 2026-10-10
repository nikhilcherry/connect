import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Live numbers from the road scan, polled once a second while Drive Mode is on.
class RoadStatus {
  const RoadStatus({
    this.running = false,
    this.ready = false,
    this.info = '',
    this.fps = 0,
    this.thermal = 0,
    this.paused = false,
    this.potholes = 0,
    this.violations = 0,
    this.triple = 0,
    this.noHelmet = 0,
    this.gps = false,
    this.last = '-',
    this.demo = false,
  });

  final bool running;

  /// Models are loaded and frames are being processed.
  final bool ready;
  final String info;
  final double fps;

  /// Android thermal status: 0 normal ... 3 severe, 4 critical.
  final int thermal;

  /// The scan stopped itself to let the phone cool.
  final bool paused;
  final int potholes;
  final int violations;
  final int triple;
  final int noHelmet;
  final bool gps;

  /// The most recent thing caught, as the native side words it ("TRIPLE RIDING #3", "pothole 0.62").
  final String last;

  /// A recorded clip is standing in for the camera (lab builds only).
  final bool demo;

  factory RoadStatus.fromMap(Map<Object?, Object?> m) {
    int i(String k) => (m[k] as num?)?.toInt() ?? 0;
    return RoadStatus(
      running: m['running'] == true,
      ready: m['ready'] == true,
      info: (m['info'] as String?) ?? '',
      fps: (m['fps'] as num?)?.toDouble() ?? 0,
      thermal: i('thermal'),
      paused: m['paused'] == true,
      potholes: i('potholes'),
      violations: i('violations'),
      triple: i('triple'),
      noHelmet: i('noHelmet'),
      gps: m['gps'] == true,
      last: (m['last'] as String?) ?? '-',
      demo: m['demo'] == true,
    );
  }
}

/// One thing the scan caught: a pothole, triple riding, or a rider without a helmet.
class RoadEvent {
  const RoadEvent({
    required this.id,
    required this.type,
    required this.time,
    required this.score,
    required this.plateText,
    required this.plateValid,
    required this.framePath,
    this.platePath,
    this.lat,
    this.lon,
  });

  final String id;

  /// `pothole`, `triple_riding` or `no_helmet`.
  final String type;
  final DateTime time;
  final double score;
  final String plateText;
  final bool plateValid;
  final String framePath;
  final String? platePath;
  final double? lat;
  final double? lon;

  bool get isViolation => type != 'pothole';

  factory RoadEvent.fromMap(Map<Object?, Object?> m) => RoadEvent(
        id: m['id'] as String,
        type: m['type'] as String,
        time: DateTime.fromMillisecondsSinceEpoch((m['timeMs'] as num).toInt()),
        score: (m['score'] as num?)?.toDouble() ?? 0,
        plateText: (m['plateText'] as String?) ?? '',
        plateValid: m['plateValid'] == true,
        framePath: m['framePath'] as String,
        platePath: m['platePath'] as String?,
        lat: (m['lat'] as num?)?.toDouble(),
        lon: (m['lon'] as num?)?.toDouble(),
      );
}

/// Drive Mode's road scan. The camera, models and rules run natively on the phone (GPU), in a
/// foreground service so they keep going with the screen off. Nothing is uploaded: events and
/// photos stay in the app's own storage and are deleted after 7 days.
///
/// Every call is safe on phones and test runs without the native side: it just reports "not
/// available" and Drive Mode carries on with crash detection alone.
class RoadGuard {
  static const _channel = MethodChannel('connect/roadguard');
  static const _pref = 'road_scan_on';

  /// Lab builds only: play frames from this folder instead of opening the camera.
  static String? demoDir;

  /// The user's choice; on by default.
  static final enabled = ValueNotifier<bool>(true);

  static Future<void> load() async {
    try {
      enabled.value = (await SharedPreferences.getInstance()).getBool(_pref) ?? true;
    } catch (_) {}
  }

  static Future<void> setEnabled(bool on) async {
    enabled.value = on;
    try {
      await (await SharedPreferences.getInstance()).setBool(_pref, on);
    } catch (_) {}
  }

  static Future<bool> available() async {
    try {
      return await _channel.invokeMethod<bool>('available') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Asks for camera access if needed, then starts the scan. False if it could not start.
  static Future<bool> start() async {
    try {
      return await _channel.invokeMethod<bool>('start', {'demoDir': demoDir}) ?? false;
    } catch (_) {
      return false;
    }
  }

  /// The latest frame with detections drawn on it (JPEG), or null if there is none yet.
  static Future<Uint8List?> preview() async {
    try {
      return await _channel.invokeMethod<Uint8List>('preview');
    } catch (_) {
      return null;
    }
  }

  static Future<void> stop() async {
    try {
      await _channel.invokeMethod<void>('stop');
    } catch (_) {}
  }

  static Future<RoadStatus?> status() async {
    try {
      final m = await _channel.invokeMethod<Map<Object?, Object?>>('status');
      return m == null ? null : RoadStatus.fromMap(m);
    } catch (_) {
      return null;
    }
  }

  /// Everything the scan saved since [since], oldest first.
  static Future<List<RoadEvent>> events(DateTime since) async {
    try {
      final list = await _channel.invokeMethod<List<Object?>>('events', since.millisecondsSinceEpoch) ?? const [];
      return [for (final e in list) RoadEvent.fromMap(e as Map<Object?, Object?>)];
    } catch (_) {
      return const [];
    }
  }
}
