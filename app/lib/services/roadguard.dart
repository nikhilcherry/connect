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
    this.videoClip = '',
    this.videoIndex = 0,
    this.videoCount = 0,
    this.videoDone = false,
    this.streamHost = '',
    this.streamState = '',
    this.aiOn = false,
    this.aiCalls = 0,
    this.aiFail = 0,
    this.aiCost = 0,
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

  /// While video clips stand in for the camera: the clip being scanned (1-based index of count), and whether
  /// the last one has finished.
  final String videoClip;
  final int videoIndex;
  final int videoCount;
  final bool videoDone;

  /// While a live dashcam stream stands in for the camera: its host, and `connecting`, `live` or `lost`.
  final String streamHost;
  final String streamState;

  /// AI second opinion: on, how many checks were asked, how many failed, and what they cost (USD).
  final bool aiOn;
  final int aiCalls;
  final int aiFail;
  final double aiCost;

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
      videoClip: (m['videoClip'] as String?) ?? '',
      videoIndex: i('videoIndex'),
      videoCount: i('videoCount'),
      videoDone: m['videoDone'] == true,
      streamHost: (m['streamHost'] as String?) ?? '',
      streamState: (m['streamState'] as String?) ?? '',
      aiOn: m['aiOn'] == true,
      aiCalls: i('aiCalls'),
      aiFail: i('aiFail'),
      aiCost: (m['aiCost'] as num?)?.toDouble() ?? 0,
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
    required this.note,
    required this.framePath,
    this.vehiclePath,
    this.plateHiRes = false,
    this.platePath,
    this.lat,
    this.lon,
    this.imported = false,
    this.clip = '',
    this.timeKnown = true,
  });

  final String id;

  /// `pothole`, `triple_riding` or `no_helmet`.
  final String type;

  /// When it happened. For footage from a video clip this is the clip's own recorded time, not when it was scanned;
  /// see [timeKnown].
  final DateTime time;
  final double score;
  final String plateText;
  final bool plateValid;

  /// How the event was decided ("ai: people=3 ..." or "riders=3").
  final String note;
  final String framePath;
  final String? platePath;

  /// The vehicle at full detail, from the full-resolution still, when one could be taken.
  final String? vehiclePath;

  /// The plate crop comes from the full-resolution still, not the low-resolution analysis frame.
  final bool plateHiRes;
  final double? lat;
  final double? lon;

  bool get isViolation => type == 'triple_riding' || type == 'no_helmet';

  /// The number plate is clear enough to act on: a crop was saved and the text read from it is a valid
  /// plate. A blurry crop that reads as nonsense does not count.
  bool get plateClear => platePath != null && plateValid && plateText.isNotEmpty;

  bool get hasLocation => lat != null && lon != null;

  /// Footage from a video clip, not the live camera: its place and time are the clip's own, and may be unknown.
  final bool imported;
  final String clip;

  /// False for a clip with no recorded time: [time] is then only when it was scanned, and it must not be reported.
  final bool timeKnown;

  factory RoadEvent.fromMap(Map<Object?, Object?> m) => RoadEvent(
        id: m['id'] as String,
        type: m['type'] as String,
        time: DateTime.fromMillisecondsSinceEpoch(((m['occurredMs'] ?? m['timeMs']) as num).toInt()),
        score: (m['score'] as num?)?.toDouble() ?? 0,
        plateText: (m['plateText'] as String?) ?? '',
        plateValid: m['plateValid'] == true,
        note: (m['note'] as String?) ?? '',
        framePath: m['framePath'] as String,
        vehiclePath: m['vehiclePath'] as String?,
        plateHiRes: m['plateHiRes'] == true,
        platePath: m['platePath'] as String?,
        lat: (m['lat'] as num?)?.toDouble(),
        lon: (m['lon'] as num?)?.toDouble(),
        imported: m['imported'] == true,
        clip: (m['clip'] as String?) ?? '',
        timeKnown: m['imported'] != true || m['occurredMs'] != null,
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
  static const _prefAi = 'road_scan_ai';

  /// Lab builds only: play frames from this folder instead of opening the camera.
  static String? demoDir;

  /// Video clips to scan instead of the camera, for one drive. Cleared when the drive ends.
  static List<String>? videos;

  /// A dashcam's live-view address (MJPEG over http) to scan instead of the camera, for one drive.
  static String? stream;

  /// The user's choice; on by default.
  static final enabled = ValueNotifier<bool>(true);

  /// Opt-in second opinion from a cloud AI on suspect vehicles. Off by default: it uploads a cropped
  /// photo of the vehicle. Only offered when this build has a key.
  static final aiEnabled = ValueNotifier<bool>(false);
  static final aiAvailable = ValueNotifier<bool>(false);

  static Future<void> load() async {
    try {
      final p = await SharedPreferences.getInstance();
      enabled.value = p.getBool(_pref) ?? true;
      aiEnabled.value = p.getBool(_prefAi) ?? false;
    } catch (_) {}
    try {
      aiAvailable.value = await _channel.invokeMethod<bool>('aiAvailable') ?? false;
    } catch (_) {}
  }

  static Future<void> setEnabled(bool on) async {
    enabled.value = on;
    try {
      await (await SharedPreferences.getInstance()).setBool(_pref, on);
    } catch (_) {}
  }

  static Future<void> setAiEnabled(bool on) async {
    aiEnabled.value = on;
    try {
      await (await SharedPreferences.getInstance()).setBool(_prefAi, on);
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
      return await _channel.invokeMethod<bool>('start', {'demoDir': demoDir, 'ai': aiEnabled.value, 'videos': videos, 'stream': stream}) ?? false;
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
    videos = null;
    stream = null;
  }

  /// Opens the system picker for one or more video clips; their addresses, or none if cancelled.
  static Future<List<String>> pickVideos() => _pick('pickVideos');

  /// Opens the system picker for a folder, and answers with every video clip in it (oldest name first).
  static Future<List<String>> pickVideoFolder() => _pick('pickVideoFolder');

  static Future<List<String>> _pick(String method) async {
    try {
      final l = await _channel.invokeMethod<List<Object?>>(method) ?? const [];
      return [for (final e in l) e as String];
    } catch (_) {
      return const [];
    }
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
