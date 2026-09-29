import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'config.dart';
import 'data/app_state.dart';
import 'l10n.dart';
import 'screens/alert_thread.dart';
import 'screens/home_shell.dart';
import 'screens/onboarding.dart';
import 'screens/society_screen.dart';
import 'services/garage_log.dart';
import 'services/notifications.dart';
import 'services/parking.dart';
import 'services/push.dart';
import 'services/trip_share.dart';
import 'services/wallet.dart';
import 'theme.dart';
import 'widgets/common.dart';
import 'widgets/motion.dart';

final navigatorKey = GlobalKey<NavigatorState>();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Supabase.initialize(url: Config.supabaseUrl, publishableKey: Config.supabaseAnonKey);
  await Future.wait([L10n.load(), Notifications.init(), ParkingStore.load(), GarageLog.load(), Wallet.load()]);
  final state = AppState(Supabase.instance.client)..bootstrap();
  unawaited(Push.init(state));
  unawaited(TripShare.resume(state));
  runApp(AppScope(state: state, child: const ConnectApp()));
}

/// Exposes [AppState] to the tree and rebuilds dependents when it changes.
class AppScope extends InheritedNotifier<AppState> {
  const AppScope({super.key, required AppState state, required super.child}) : super(notifier: state);

  static AppState of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppScope>()!.notifier!;

  static AppState read(BuildContext context) =>
      context.getInheritedWidgetOfExactType<AppScope>()!.notifier!;
}

class ConnectApp extends StatefulWidget {
  const ConnectApp({super.key});

  @override
  State<ConnectApp> createState() => _ConnectAppState();
}

class _ConnectAppState extends State<ConnectApp> {
  late final AppLifecycleListener _life;
  StreamSubscription<Map<String, dynamic>>? _opened;

  @override
  void initState() {
    super.initState();
    final s = AppScope.read(context);
    _life = AppLifecycleListener(onResume: s.onForeground, onPause: s.onBackground);
    _opened = Push.opened.stream.listen(_open);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final launched = Notifications.launchAlertId;
      Notifications.launchAlertId = null;
      final initial = Push.takeInitial() ?? (launched == null ? null : {'alert_id': launched});
      if (initial != null) _open(initial);
    });
  }

  @override
  void dispose() {
    _life.dispose();
    _opened?.cancel();
    super.dispose();
  }

  /// Opens what a tapped notification was about, once the car has loaded.
  Future<void> _open(Map<String, dynamic> data) async {
    final s = AppScope.read(context);
    for (var i = 0; i < 40 && (s.loading || s.vehicle == null); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    final nav = navigatorKey.currentState;
    if (nav == null || s.vehicle == null) return;
    final alertId = data['alert_id'] as String?;
    final societyId = data['society_id'] as String?;
    if (alertId != null) {
      if (!s.alerts.any((a) => a.id == alertId)) await s.refresh();
      nav.push(MaterialPageRoute(builder: (_) => AlertThreadScreen(alertId: alertId)));
    } else if (societyId != null) {
      await s.refresh();
      if (s.societies.any((x) => x.id == societyId)) {
        nav.push(MaterialPageRoute(builder: (_) => SocietyScreen(societyId: societyId)));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<AppLang>(
      valueListenable: L10n.lang,
      builder: (context, lang, _) => MaterialApp(
        title: 'Connect',
        navigatorKey: navigatorKey,
        debugShowCheckedModeBanner: false,
        // Dispatch Periwinkle is light-only until the dark "Dispatch Blend" tokens exist.
        theme: buildTheme(),
        themeMode: ThemeMode.light,
        locale: lang.locale,
        supportedLocales: [for (final l in AppLang.values) l.locale],
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: const _Root(),
      ),
    );
  }
}

class _Root extends StatelessWidget {
  const _Root();

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final Widget page;
    if (s.loading && s.vehicle == null) {
      page = const _LoadingSkeleton(key: ValueKey('loading'));
    } else if (s.loadError != null) {
      page = Scaffold(
        key: const ValueKey('error'),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(mainAxisSize: MainAxisSize.min, children: revealAll([
              IconBadge(s.loadErrorIsNetwork ? Icons.wifi_off_outlined : Icons.cloud_off_outlined, tone: Tone.error, size: 56),
              const SizedBox(height: 16),
              Text(s.loadErrorIsNetwork ? tr('Offline') : tr('Something went wrong'), style: DLText.title),
              const SizedBox(height: 8),
              Text(s.loadError!, textAlign: TextAlign.center, style: DLText.body.copyWith(color: DL.muted)),
              const SizedBox(height: 24),
              FilledButton(onPressed: s.bootstrap, child: Text(tr('Try again'))),
            ])),
          ),
        ),
      );
    } else {
      page = s.vehicle == null ? const WelcomeScreen(key: ValueKey('welcome')) : const HomeShell(key: ValueKey('home'));
    }
    return AnimatedSwitcher(duration: DL.medium, switchInCurve: DL.ease, switchOutCurve: DL.ease, child: page);
  }
}

/// The home screen's outline while the first load runs, so the app opens
/// into its own shape instead of a spinner.
class _LoadingSkeleton extends StatelessWidget {
  const _LoadingSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    Widget card(double h) => Container(
          height: h,
          decoration: BoxDecoration(color: DL.card, borderRadius: BorderRadius.circular(DL.rCard), border: Border.all(color: DL.line)),
          padding: const EdgeInsets.all(18),
          alignment: Alignment.topLeft,
          // Fractions, not pixels: the stat cards are only ~100 px wide on a phone.
          child: const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            FractionallySizedBox(widthFactor: 0.5, child: Skeleton(height: 14)),
            SizedBox(height: 12),
            FractionallySizedBox(widthFactor: 0.8, child: Skeleton(height: 12)),
          ]),
        );
    return Scaffold(
      body: SafeArea(
        child: Semantics(
          label: tr('Loading…'),
          child: ListView(physics: const NeverScrollableScrollPhysics(), padding: const EdgeInsets.fromLTRB(20, 20, 20, 32), children: [
            // ListView stretches its children; Align keeps the header bars short.
            const Align(alignment: Alignment.centerLeft, child: Skeleton(width: 110, height: 11)),
            const SizedBox(height: 12),
            const Align(alignment: Alignment.centerLeft, child: Skeleton(width: 220, height: 28)),
            const SizedBox(height: 8),
            const Align(alignment: Alignment.centerLeft, child: Skeleton(width: 150, height: 13)),
            const SizedBox(height: 28),
            Row(children: [
              for (var i = 0; i < 3; i++) ...[
                if (i > 0) const SizedBox(width: 12),
                Expanded(child: card(96)),
              ],
            ]),
            const SizedBox(height: 12),
            card(128),
            const SizedBox(height: 32),
            card(76),
            const SizedBox(height: 12),
            card(76),
          ]),
        ),
      ),
    );
  }
}
