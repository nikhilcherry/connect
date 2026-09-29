import 'dart:async';
import 'dart:math';

import 'package:sensors_plus/sensors_plus.dart';

/// Heuristic crash detection from the phone's accelerometer while Drive Mode
/// is on. A crash shows up as a very short, very large spike in acceleration
/// with gravity removed; a dropped phone produces similar spikes, which is why
/// every trigger goes through a cancellable countdown before anyone is told.
class CrashDetector {
  CrashDetector({this.thresholdG = 4.0, required this.onSuspectedCrash});

  /// Peak user acceleration (g) that counts as a suspected crash. Hard
  /// braking is ~1g; phone drops onto a floor often exceed 4g, so the
  /// countdown is the real safeguard.
  final double thresholdG;
  final void Function(double peakG) onSuspectedCrash;

  StreamSubscription<UserAccelerometerEvent>? _sub;
  DateTime _cooldownUntil = DateTime.fromMillisecondsSinceEpoch(0);
  double peakG = 0;

  bool get running => _sub != null;

  void start() {
    _sub ??= userAccelerometerEventStream(samplingPeriod: SensorInterval.gameInterval).listen((e) {
      final g = sqrt(e.x * e.x + e.y * e.y + e.z * e.z) / 9.81;
      if (g > peakG) peakG = g;
      final now = DateTime.now();
      if (g >= thresholdG && now.isAfter(_cooldownUntil)) {
        _cooldownUntil = now.add(const Duration(seconds: 30));
        onSuspectedCrash(g);
      }
    });
  }

  void stop() {
    _sub?.cancel();
    _sub = null;
  }
}
