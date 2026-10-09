import 'package:flutter/material.dart';

import '../l10n.dart';
import '../main.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'damage_report_screen.dart';
import 'fit_check.dart';
import 'garage_log_screen.dart';
import 'parking_screen.dart';
import 'wallet_screen.dart';
import 'whisper_screen.dart';

/// What still works with no connection: everything that runs on the phone.
/// Opened from the Offline screen; "Try again" returns to the normal app.
class OfflineHubScreen extends StatelessWidget {
  const OfflineHubScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    Widget row(IconData icon, String title, String subtitle, Widget page) => ListTile(
          leading: IconBadge(icon),
          title: Text(title, style: DLText.body),
          subtitle: Text(subtitle, style: DLText.body.copyWith(color: DL.muted)),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => push(context, page),
        );
    return Scaffold(
      appBar: AppBar(title: Text(tr('Offline mode'))),
      body: ListView(padding: const EdgeInsets.symmetric(vertical: 8), children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
          child: Text(
            tr('No connection to Connect. These tools run on this phone and need no internet. Alerts and chat come back when you are online.'),
            style: DLText.body.copyWith(color: DL.muted),
          ),
        ),
        row(Icons.graphic_eq, tr('Say it with sound'), tr('No signal in the basement? Pass the message on by sound, phone to phone'), const WhisperScreen()),
        row(Icons.car_crash_outlined, tr('Check damage and cost'), tr('Photograph damage; the phone marks it and estimates a repair cost'), const DamageReportScreen()),
        row(Icons.local_gas_station_outlined, tr('Fuel and expenses'), tr('Mileage, monthly spend, tolls and parking'), const GarageLogScreen()),
        row(Icons.folder_copy_outlined, tr('Documents'), tr('Photos of RC, insurance, PUC and licence, on this phone only'), const WalletScreen()),
        row(Icons.local_parking_outlined, tr('Where did I park'), tr('Save your spot, walk back, get a reminder before parking runs out'), const ParkingScreen()),
        row(Icons.straighten_outlined, tr('Fit Check'), tr('Will a car fit your parking spot or garage?'), const FitCheckScreen()),
        Padding(
          padding: const EdgeInsets.all(20),
          child: FilledButton(
            onPressed: () {
              Navigator.of(context).pop();
              s.bootstrap();
            },
            child: Text(tr('Try again')),
          ),
        ),
      ]),
    );
  }
}
