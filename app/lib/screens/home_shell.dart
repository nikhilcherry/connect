import 'package:flutter/material.dart';

import '../l10n.dart';
import '../main.dart';
import '../theme.dart';
import '../widgets/motion.dart';
import 'alerts_tab.dart';
import 'garage_tab.dart';
import 'home_tab.dart';
import 'safety_tab.dart';

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  static void goTo(BuildContext context, int index) =>
      context.findAncestorStateOfType<_HomeShellState>()?.select(index);

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;

  void select(int i) => setState(() => _index = i);

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    // Mid-way through deleting the account the car is gone before the root has
    // swapped this shell out; the tabs all assume a car, so render nothing.
    if (state.vehicle == null) return const Scaffold();
    final open = state.openAlerts;
    // Outline icons at rest; the filled glyph appears only inside the active circle.
    Widget alertsIcon(IconData icon) => Badge(isLabelVisible: open > 0, label: Text('$open'), child: Icon(icon));
    return Scaffold(
      body: Column(children: [
        AnimatedSize(
          duration: DL.medium,
          curve: DL.ease,
          alignment: Alignment.topCenter,
          child: state.offline ? const _OfflineBanner() : const SizedBox(width: double.infinity),
        ),
        Expanded(
          // The banner already sits under the status bar; the tabs must not leave room for it twice.
          child: MediaQuery.removePadding(
            context: context,
            removeTop: state.offline,
            child: FadeThroughStack(index: _index, children: const [HomeTab(), AlertsTab(), SafetyTab(), GarageTab()]),
          ),
        ),
      ]),
      bottomNavigationBar: DecoratedBox(
        decoration: const BoxDecoration(color: DL.card, boxShadow: DL.floatShadow),
        child: NavigationBar(
          selectedIndex: _index,
          onDestinationSelected: select,
          animationDuration: DL.fast,
          destinations: [
            NavigationDestination(icon: const Icon(Icons.home_outlined), selectedIcon: const Icon(Icons.home), label: tr('Home')),
            NavigationDestination(icon: alertsIcon(Icons.forum_outlined), selectedIcon: alertsIcon(Icons.forum), label: tr('Alerts')),
            NavigationDestination(icon: const Icon(Icons.shield_outlined), selectedIcon: const Icon(Icons.shield), label: tr('Safety')),
            NavigationDestination(icon: const Icon(Icons.directions_car_outlined), selectedIcon: const Icon(Icons.directions_car), label: tr('Garage')),
          ],
        ),
      ),
    );
  }
}

/// Shown while the app runs from the copy saved on this phone. The app keeps
/// retrying by itself; the button retries at once.
class _OfflineBanner extends StatefulWidget {
  const _OfflineBanner();

  @override
  State<_OfflineBanner> createState() => _OfflineBannerState();
}

class _OfflineBannerState extends State<_OfflineBanner> {
  bool _trying = false;

  Future<void> _retry() async {
    setState(() => _trying = true);
    final ok = await AppScope.read(context).reload();
    if (!mounted) return;
    setState(() => _trying = false);
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('Still no connection. Everything saved on this phone keeps working.'))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final tone = Tone.warning;
    return Material(
      color: tone.bg,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 6, 8, 6),
          child: Row(children: [
            Icon(Icons.cloud_off_outlined, size: 18, color: tone.fg),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                tr('Offline. Showing what is saved on this phone.'),
                style: DLText.small.copyWith(color: tone.fg, fontWeight: FontWeight.w600),
              ),
            ),
            TextButton(
              style: TextButton.styleFrom(foregroundColor: tone.fg, minimumSize: const Size(64, 40)),
              onPressed: _trying ? null : _retry,
              child: _trying
                  ? SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: tone.fg))
                  : Text(tr('Retry')),
            ),
          ]),
        ),
      ),
    );
  }
}
