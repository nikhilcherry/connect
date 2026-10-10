import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Witness mode: a phone left watching from a parked car keeps the last
/// minute of number plates it has read. When it feels a bump it freezes that
/// memory, so the owner comes back to "KA 01 AB 1234 was in front of your car
/// when it was hit" instead of an unexplained dent.
///
/// Everything here is plain logic, tested without a camera. Nothing is sent
/// anywhere: the plates stay on the phone unless the owner chooses to reach
/// one of them through Connect.

/// One reading of one plate in one camera frame.
class PlateSighting {
  const PlateSighting(this.plate, this.at, this.confidence);
  final String plate;
  final DateTime at;
  final double confidence;
}

/// A plate seen around an incident, after its frames have voted.
class PlateCandidate {
  const PlateCandidate(this.plate, this.count, this.firstSeen, this.lastSeen, this.confidence);
  final String plate;

  /// How many frames read it (including near-misses folded into it).
  final int count;
  final DateTime firstSeen, lastSeen;

  /// Mean confidence of the readings that agreed exactly.
  final double confidence;

  Map<String, dynamic> toJson() => {
        'plate': plate,
        'count': count,
        'first': firstSeen.toUtc().toIso8601String(),
        'last': lastSeen.toUtc().toIso8601String(),
        'confidence': confidence,
      };

  factory PlateCandidate.fromJson(Map<String, dynamic> j) => PlateCandidate(
        j['plate'] as String,
        j['count'] as int,
        DateTime.parse(j['first'] as String).toLocal(),
        DateTime.parse(j['last'] as String).toLocal(),
        (j['confidence'] as num).toDouble(),
      );
}

/// True when two readings differ by one character: one wrong, one missing or
/// one extra. That is what a single misread looks like.
@visibleForTesting
bool oneCharacterApart(String a, String b) {
  if (a == b) return false;
  if ((a.length - b.length).abs() > 1) return false;
  final long = a.length >= b.length ? a : b, short = a.length >= b.length ? b : a;
  var i = 0;
  while (i < short.length && long[i] == short[i]) {
    i++;
  }
  return long.length == short.length ? long.substring(i + 1) == short.substring(i + 1) : long.substring(i + 1) == short.substring(i);
}

/// The frames vote. A plate read the same way in several frames outranks one
/// read once, and a reading one character off a stronger one is counted as
/// that plate misread, not as a second car. A plate needs [minSightings]
/// readings to count, unless its one reading was near-certain.
List<PlateCandidate> rankPlates(List<PlateSighting> sightings, {int minSightings = 2}) {
  final byPlate = <String, List<PlateSighting>>{};
  for (final s in sightings) {
    (byPlate[s.plate] ??= []).add(s);
  }
  double trust(List<PlateSighting> l) => l.fold(0.0, (a, s) => a + s.confidence);
  final order = byPlate.keys.toList()
    ..sort((a, b) {
      final c = byPlate[b]!.length.compareTo(byPlate[a]!.length);
      return c != 0 ? c : trust(byPlate[b]!).compareTo(trust(byPlate[a]!));
    });
  final kept = <String>[];
  final folded = <String, List<PlateSighting>>{};
  for (final p in order) {
    final into = kept.where((k) => oneCharacterApart(k, p)).firstOrNull;
    if (into != null) {
      folded[into]!.addAll(byPlate[p]!);
    } else {
      kept.add(p);
      folded[p] = [];
    }
  }
  final out = <PlateCandidate>[];
  for (final p in kept) {
    final exact = byPlate[p]!, all = [...exact, ...folded[p]!]..sort((a, b) => a.at.compareTo(b.at));
    final confidence = trust(exact) / exact.length;
    if (all.length < minSightings && confidence < 0.9) continue;
    out.add(PlateCandidate(p, all.length, all.first.at, all.last.at, confidence));
  }
  out.sort((a, b) => b.count.compareTo(a.count));
  return out;
}

/// The last stretch of plates the camera has read.
class SightingMemory {
  SightingMemory({this.keep = const Duration(seconds: 90)});
  final Duration keep;
  final _all = <PlateSighting>[];

  void add(PlateSighting s) {
    _all.add(s);
    final cutoff = s.at.subtract(keep);
    while (_all.isNotEmpty && _all.first.at.isBefore(cutoff)) {
      _all.removeAt(0);
    }
  }

  List<PlateSighting> between(DateTime from, DateTime to) =>
      _all.where((s) => !s.at.isBefore(from) && !s.at.isAfter(to)).toList();

  /// The plates in view over the last [window], most seen first.
  List<PlateCandidate> recent(DateTime now, Duration window) => rankPlates(between(now.subtract(window), now));
}

/// How hard a knock has to be before it counts. A parked car that is nudged
/// moves the dashboard far less than a crash does, so these sit well under
/// Drive Mode's 4 g.
enum BumpLevel {
  light(0.3, /*t*/'A light knock'),
  firm(0.8, /*t*/'A firm bump'),
  hard(1.8, /*t*/'A hard hit');

  const BumpLevel(this.g, this.label);
  final double g;
  final String label;
}

/// Picks bumps out of the accelerometer: a reading at or over the threshold,
/// then a quiet spell so one knock (which rings for a moment) is one bump.
class BumpDetector {
  BumpDetector({required this.level, this.quiet = const Duration(seconds: 8)});
  BumpLevel level;
  final Duration quiet;
  DateTime _quietUntil = DateTime.fromMillisecondsSinceEpoch(0);

  /// [g] is acceleration with gravity removed, in g. True when it is a new bump.
  bool feed(double g, DateTime now) {
    if (g < level.g || now.isBefore(_quietUntil)) return false;
    _quietUntil = now.add(quiet);
    return true;
  }
}

/// What the phone recorded around one bump.
class Incident {
  Incident({required this.at, required this.peakG, required this.plates, this.photos = const [], this.manual = false});
  final DateTime at;
  final double peakG;
  final List<PlateCandidate> plates;

  /// Frames saved on this phone: the moment of the bump, then a few seconds after.
  final List<String> photos;

  /// Marked by hand rather than felt.
  final bool manual;

  /// How long before the bump the plates are taken from, and how long after:
  /// a car is in view before it hits, and shows its other plate as it leaves.
  static const before = Duration(seconds: 12), after = Duration(seconds: 3);

  Map<String, dynamic> toJson() => {
        'at': at.toUtc().toIso8601String(),
        'g': peakG,
        'plates': [for (final p in plates) p.toJson()],
        'photos': photos,
        'manual': manual,
      };

  factory Incident.fromJson(Map<String, dynamic> j) => Incident(
        at: DateTime.parse(j['at'] as String).toLocal(),
        peakG: (j['g'] as num).toDouble(),
        plates: [for (final p in j['plates'] as List) PlateCandidate.fromJson(p as Map<String, dynamic>)],
        photos: (j['photos'] as List).cast<String>(),
        manual: j['manual'] as bool? ?? false,
      );
}

/// Incidents kept on this phone, newest first.
class WitnessLog {
  static final incidents = ValueNotifier<List<Incident>>(const []);
  static const _key = 'witness_incidents';
  static const _keep = 12;

  static Future<void> load() async {
    try {
      final raw = (await SharedPreferences.getInstance()).getString(_key);
      if (raw != null) incidents.value = [for (final j in jsonDecode(raw) as List) Incident.fromJson(j as Map<String, dynamic>)];
    } catch (e) {
      debugPrint('witness log unreadable: $e');
    }
  }

  static Future<void> _save() async {
    try {
      await (await SharedPreferences.getInstance()).setString(_key, jsonEncode([for (final i in incidents.value) i.toJson()]));
    } catch (e) {
      debugPrint('witness log not saved: $e');
    }
  }

  static Future<void> add(Incident i) async {
    incidents.value = [i, ...incidents.value].take(_keep).toList();
    await _save();
  }

  static Future<void> remove(Incident i) async {
    incidents.value = incidents.value.where((x) => x != i).toList();
    await _save();
  }

  @visibleForTesting
  static void reset() => incidents.value = const [];
}
