import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'notifications.dart';

/// Where the car was left. Lives only on this phone: nothing here is sent to
/// Connect.
class ParkingSpot {
  ParkingSpot({required this.savedAt, this.lat, this.lng, this.accuracyM, this.note, this.photoPath, this.meterEndsAt});

  final DateTime savedAt;
  final double? lat;
  final double? lng;
  final double? accuracyM;
  final String? note;
  final String? photoPath;
  final DateTime? meterEndsAt;

  bool get hasLocation => lat != null && lng != null;

  /// Walking directions in whatever maps app the phone has. A plain link, so
  /// no Maps SDK or API key is involved.
  Uri get directionsUrl => Uri.parse(
      'https://www.google.com/maps/dir/?api=1&destination=${lat!.toStringAsFixed(6)},${lng!.toStringAsFixed(6)}&travelmode=walking');

  Map<String, dynamic> toJson() => {
        'savedAt': savedAt.toIso8601String(),
        'lat': lat,
        'lng': lng,
        'accuracyM': accuracyM,
        'note': note,
        'photoPath': photoPath,
        'meterEndsAt': meterEndsAt?.toIso8601String(),
      };

  factory ParkingSpot.fromJson(Map<String, dynamic> j) => ParkingSpot(
        savedAt: DateTime.parse(j['savedAt'] as String),
        lat: (j['lat'] as num?)?.toDouble(),
        lng: (j['lng'] as num?)?.toDouble(),
        accuracyM: (j['accuracyM'] as num?)?.toDouble(),
        note: j['note'] as String?,
        photoPath: j['photoPath'] as String?,
        meterEndsAt: j['meterEndsAt'] == null ? null : DateTime.parse(j['meterEndsAt'] as String),
      );
}

class ParkingStore {
  static const _key = 'parking_spot_v1';
  static final spot = ValueNotifier<ParkingSpot?>(null);

  static Future<void> load() async {
    try {
      final raw = (await SharedPreferences.getInstance()).getString(_key);
      spot.value = raw == null ? null : ParkingSpot.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (e) {
      debugPrint('parking load failed: $e');
    }
  }

  static Future<void> save(ParkingSpot s) async {
    final old = spot.value;
    await (await SharedPreferences.getInstance()).setString(_key, jsonEncode(s.toJson()));
    if (old?.photoPath != null && old!.photoPath != s.photoPath) _deletePhoto(old.photoPath!);
    spot.value = s;
    await Notifications.scheduleParkingReminder(s.meterEndsAt);
  }

  static Future<void> clear() async {
    final old = spot.value;
    await (await SharedPreferences.getInstance()).remove(_key);
    if (old?.photoPath != null) _deletePhoto(old!.photoPath!);
    spot.value = null;
    await Notifications.scheduleParkingReminder(null);
  }

  /// Current position, or null if location is off, permission was refused,
  /// or nothing came back within 20 s (an ignored permission prompt never
  /// answers, and saving the note and photo matters more than the fix).
  static Future<Position?> locate() => _locate().timeout(const Duration(seconds: 20), onTimeout: () => null);

  static Future<Position?> _locate() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return null;
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
      if (perm != LocationPermission.always && perm != LocationPermission.whileInUse) return null;
      return await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, timeLimit: Duration(seconds: 12)),
      );
    } catch (e) {
      debugPrint('locate failed: $e');
      return null;
    }
  }

  /// Takes a photo and copies it out of the picker's cache, which Android may
  /// clear. Not offered on web, where there's no app folder to keep it in.
  static Future<String?> takePhoto() async {
    if (kIsWeb) return null;
    final shot = await ImagePicker().pickImage(source: ImageSource.camera, maxWidth: 1280, imageQuality: 70);
    if (shot == null) return null;
    final dir = await getApplicationDocumentsDirectory();
    final dest = '${dir.path}/parking_${DateTime.now().millisecondsSinceEpoch}.jpg';
    await File(shot.path).copy(dest);
    return dest;
  }

  static void _deletePhoto(String path) {
    if (kIsWeb) return;
    File(path).delete().then((_) {}, onError: (_) {});
  }
}
