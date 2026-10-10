// Build-time configuration. Local defaults target `supabase start`; release
// builds pass real values:
//   flutter build apk --dart-define=SUPABASE_URL=https://xyz.supabase.co \
//     --dart-define=SUPABASE_ANON_KEY=...
import 'package:flutter/foundation.dart';

class Config {
  static const supabaseUrl = String.fromEnvironment(
    'SUPABASE_URL',
    defaultValue: 'https://pbysiqjwfptmyfbjhhao.supabase.co',
  );
  static const supabaseAnonKey = String.fromEnvironment(
    'SUPABASE_ANON_KEY',
    defaultValue: 'sb_publishable_c-iJBGAcj_oEXNWc1z9Atw_OhlNpPVx',
  );

  /// The name supabase_flutter files the signed-in session under: it is taken
  /// from the server's address (see main.dart, carrySessionOver).
  static String sessionKey(String url) => 'sb-${Uri.parse(url).host.split('.').first}-auth-token';

  /// Where the QR on a tag points. Printed stickers can't be changed, so this
  /// defaults to the production domain in every build; local testing overrides
  /// it with --dart-define=SCAN_BASE_URL=http://127.0.0.1:8093.
  static const scanBaseUrl = String.fromEnvironment(
    'SCAN_BASE_URL',
    defaultValue: 'https://connect.premortem.tech',
  );

  /// e.g. https://connect.premortem.tech/t/EE5WRD6P. The short path keeps the
  /// QR sparse enough to scan through a windshield; the host rewrites /t/* to
  /// the scan page (web/vercel.json, web/serve.py).
  static String tagUrl(String code) => '$scanBaseUrl/t/$code';

  /// Live trip link. The secret rides in the fragment, which browsers never
  /// send to the server, so it stays out of hosting logs.
  static String tripUrl(String token) => '$scanBaseUrl/trip#$token';

  /// Firebase Cloud Messaging, for alerts that reach a closed app. Values come
  /// from the Firebase console (Project settings > Your apps > Android); with
  /// none set the app runs as before, on realtime only.
  ///   --dart-define=FIREBASE_API_KEY=... --dart-define=FIREBASE_APP_ID=...
  ///   --dart-define=FIREBASE_SENDER_ID=... --dart-define=FIREBASE_PROJECT_ID=...
  /// Where an authorised traffic-violation report goes (a webhook that accepts a multipart POST).
  /// Empty means this build offers no reporting. Keep the real address out of the repository:
  ///   --dart-define=VIOLATION_WEBHOOK_URL=https://...
  static const violationWebhookUrl = String.fromEnvironment('VIOLATION_WEBHOOK_URL');

  static const firebaseApiKey = String.fromEnvironment('FIREBASE_API_KEY');
  static const firebaseAppId = String.fromEnvironment('FIREBASE_APP_ID');
  static const firebaseSenderId = String.fromEnvironment('FIREBASE_SENDER_ID');
  static const firebaseProjectId = String.fromEnvironment('FIREBASE_PROJECT_ID');

  static bool get pushConfigured =>
      !kIsWeb && firebaseApiKey.isNotEmpty && firebaseAppId.isNotEmpty && firebaseSenderId.isNotEmpty && firebaseProjectId.isNotEmpty;

  /// Where "Protect a friend's car" sends people.
  static const appUrl = String.fromEnvironment('APP_URL', defaultValue: 'https://connect.premortem.tech/get');
}
