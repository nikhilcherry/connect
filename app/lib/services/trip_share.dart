import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/app_state.dart';
import '../l10n.dart';

class ActiveTrip {
  ActiveTrip({required this.id, required this.token, required this.endsAt, this.lastFix, this.sentAt});
  final String id;
  final String token;
  final DateTime endsAt;
  final Position? lastFix;
  final DateTime? sentAt;

  ActiveTrip copyWith({Position? lastFix, DateTime? sentAt}) =>
      ActiveTrip(id: id, token: token, endsAt: endsAt, lastFix: lastFix ?? this.lastFix, sentAt: sentAt ?? this.sentAt);

  Map<String, dynamic> toJson() => {'id': id, 'token': token, 'endsAt': endsAt.toIso8601String()};
  factory ActiveTrip.fromJson(Map<String, dynamic> j) =>
      ActiveTrip(id: j['id'] as String, token: j['token'] as String, endsAt: DateTime.parse(j['endsAt'] as String));
}

/// Live trip sharing: the phone posts its position to the trip row at most
/// every 15 s; people with the link see it on web/trip.html, which polls.
/// On Android a foreground-service notification keeps it going with the
/// screen off, and says so, so it's never silent tracking.
class TripShare {
  static final active = ValueNotifier<ActiveTrip?>(null);
  static const _key = 'trip_v1';
  static const _sendEvery = Duration(seconds: 15);
  static const _trailStepM = 30.0;
  static const _trailMax = 120;

  static StreamSubscription<Position>? _sub;
  static Timer? _endTimer;
  static final _trail = <List<double>>[];
  static AppState? _state;

  /// Picks an unfinished trip back up after the app restarts.
  static Future<void> resume(AppState state) async {
    _state = state;
    try {
      final raw = (await SharedPreferences.getInstance()).getString(_key);
      if (raw == null) return;
      final t = ActiveTrip.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      if (t.endsAt.isAfter(DateTime.now()) && await state.tripActive(t.id)) {
        active.value = t;
        await _listen();
      } else {
        await _clear();
      }
    } catch (e) {
      debugPrint('trip resume failed: $e');
    }
  }

  /// Throws [LocationUnavailable] when location is off or refused.
  static Future<ActiveTrip> start(AppState state, int hours) async {
    _state = state;
    await _ensurePermission();
    final r = await state.startTrip(hours);
    final t = ActiveTrip(id: r.id, token: r.token, endsAt: DateTime.now().add(Duration(hours: hours)));
    _trail.clear();
    active.value = t;
    await (await SharedPreferences.getInstance()).setString(_key, jsonEncode(t.toJson()));
    await _listen();
    return t;
  }

  static Future<void> stop() async {
    final t = active.value;
    await _sub?.cancel();
    _sub = null;
    _endTimer?.cancel();
    await _clear();
    if (t != null) {
      try {
        await _state?.updateTrip(t.id, {'stopped': true});
      } catch (e) {
        // It still ends on its own at endsAt.
        debugPrint('trip stop failed: $e');
      }
    }
  }

  static Future<void> _clear() async {
    active.value = null;
    _trail.clear();
    try {
      await (await SharedPreferences.getInstance()).remove(_key);
    } catch (_) {}
  }

  static Future<void> _ensurePermission() async {
    if (!await Geolocator.isLocationServiceEnabled()) throw LocationUnavailable();
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
    if (perm != LocationPermission.always && perm != LocationPermission.whileInUse) throw LocationUnavailable();
  }

  static Future<void> _listen() async {
    await _sub?.cancel();
    final t = active.value!;
    _endTimer?.cancel();
    _endTimer = Timer(t.endsAt.difference(DateTime.now()), stop);
    final LocationSettings settings = !kIsWeb && defaultTargetPlatform == TargetPlatform.android
        ? AndroidSettings(
            accuracy: LocationAccuracy.high,
            distanceFilter: 20,
            intervalDuration: const Duration(seconds: 10),
            foregroundNotificationConfig: ForegroundNotificationConfig(
              notificationTitle: tr('Sharing your trip'),
              notificationText: tr('People with your link can see where you are. Open Connect to stop.'),
              enableWakeLock: true,
              setOngoing: true,
            ),
          )
        : const LocationSettings(accuracy: LocationAccuracy.high, distanceFilter: 20);
    _sub = Geolocator.getPositionStream(locationSettings: settings).listen(_onFix, onError: (Object e) => debugPrint('trip gps: $e'));
  }

  static Future<void> _onFix(Position p) async {
    final t = active.value;
    if (t == null) return;
    final last = _trail.isEmpty ? null : _trail.last;
    if (last == null || Geolocator.distanceBetween(last[0], last[1], p.latitude, p.longitude) >= _trailStepM) {
      _trail.add([double.parse(p.latitude.toStringAsFixed(5)), double.parse(p.longitude.toStringAsFixed(5))]);
      if (_trail.length > _trailMax) _trail.removeAt(0);
    }
    active.value = t.copyWith(lastFix: p);
    if (t.sentAt != null && DateTime.now().difference(t.sentAt!) < _sendEvery) return;
    try {
      await _state?.updateTrip(t.id, {
        'lat': p.latitude,
        'lng': p.longitude,
        'accuracy_m': p.accuracy,
        'speed_mps': p.speed < 0 ? null : p.speed,
        'trail': _trail,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      });
      if (active.value?.id == t.id) active.value = active.value!.copyWith(sentAt: DateTime.now());
    } catch (e) {
      debugPrint('trip update failed: $e');
    }
  }
}

class LocationUnavailable implements Exception {}
