// Lab for Drive Mode's road scan. Never shipped: it is its own entrypoint, built under another
// application id so it installs beside the real app, and it needs no backend. It opens the real
// Safety tab with a made-up car and emergency contact, so Start Drive Mode behaves as in the app.
//
//   CONNECT_ID_SUFFIX=.rg flutter build apk --debug --target-platform android-arm64 -t tool/drive_lab.dart
//   adb install -r build/app/outputs/flutter-apk/app-debug.apk
//   adb shell am start -n app.connectcar.connect.rg/app.connectcar.connect.MainActivity
import 'dart:io';

import 'package:connect/data/app_state.dart';
import 'package:connect/data/models.dart';
import 'package:connect/l10n.dart';
import 'package:connect/main.dart' show AppScope;
import 'package:connect/screens/safety_tab.dart';
import 'package:connect/services/roadguard.dart';
import 'package:connect/theme.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Future.wait([L10n.load(), RoadGuard.load()]);
  // Replay clips instead of using the camera (see docs/road-scan.md, "Lab").
  RoadGuard.demoDir = const String.fromEnvironment('DEMO_DIR');
  if (RoadGuard.demoDir!.isEmpty) RoadGuard.demoDir = null;
  // AI second opinion: switched on when an `ai.flag` file sits in the app's files folder, so a test can
  // turn it on without tapping. Otherwise the saved choice from the Safety tab switch is used.
  final dir = await getExternalStorageDirectory();
  if (dir != null && File('${dir.path}/ai.flag').existsSync()) await RoadGuard.setAiEnabled(true);
  // A client that is never used: nothing here talks to a server.
  final state = AppState(SupabaseClient('http://127.0.0.1:1', 'lab'))
    ..loading = false
    ..vehicle = Vehicle(id: 'lab', owner: 'lab', regNumber: 'KA01AB1234', make: 'Maruti', model: 'Swift')
    ..contacts = [EmergencyContact(id: '1', name: 'Lab contact', phone: '9999999999')];
  runApp(AppScope(
    state: state,
    child: MaterialApp(debugShowCheckedModeBanner: false, theme: buildTheme(), home: const Scaffold(body: SafetyTab())),
  ));
}
