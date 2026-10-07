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
      body: FadeThroughStack(index: _index, children: const [HomeTab(), AlertsTab(), SafetyTab(), GarageTab()]),
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
