import 'package:flutter/material.dart';
import 'plate_scan_screen.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/models.dart';
import '../l10n.dart';
import '../main.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/motion.dart';
import 'family_screen.dart';
import 'fit_check.dart';
import 'garage_log_screen.dart';
import 'onboarding.dart';
import 'parking_screen.dart';
import 'society_screen.dart';
import 'tag_screen.dart';
import 'wallet_screen.dart';

class GarageTab extends StatelessWidget {
  const GarageTab({super.key});

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final v = s.vehicle!;
    String m(int? x) => x == null ? '—' : (x / 1000).toStringAsFixed(2);

    return SafeArea(
      child: ListView(padding: const EdgeInsets.fromLTRB(20, 20, 20, 32), children: revealAll([
        ScreenTitle(tr('Garage'), eyebrow: tr('Your car')),
        const SizedBox(height: 24),
        SectionCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const IconBadge(Icons.directions_car_outlined),
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(v.title, style: DLText.section),
                  Text('${v.make} ${v.model} · ${v.prettyReg}', style: DLText.small),
                ]),
              ),
              TextButton(onPressed: () => push(context, VehicleFormScreen(existing: v)), child: Text(tr('Edit'))),
            ]),
            const SizedBox(height: 16),
            const Divider(),
            const SizedBox(height: 16),
            Row(children: [
              _Dim(tr('Length'), m(v.lengthMm)),
              _Dim(tr('Width'), m(v.widthMm)),
              _Dim(tr('Height'), m(v.heightMm)),
            ]),
            if (v.lengthMm != null) ...[
              const SizedBox(height: 12),
              Text(tr('Typical figures for this model. Check your owner\'s manual for your variant.'), style: DLText.small),
            ],
          ]),
        ),
        const SizedBox(height: 32),
        Label(tr('Running the car')),
        const SizedBox(height: 12),
        Card(
          clipBehavior: Clip.antiAlias,
          child: Column(children: [
            _Row(
              icon: Icons.local_gas_station_outlined,
              title: tr('Fuel and expenses'),
              subtitle: tr('Mileage, monthly spend, tolls and parking'),
              onTap: () => push(context, const GarageLogScreen()),
            ),
            const Divider(),
            _Row(
              icon: Icons.build_outlined,
              title: tr('Service history'),
              subtitle: tr('Every visit in one place, shareable as a PDF when you sell'),
              onTap: () => push(context, const GarageLogScreen(filter: LogFilter.service)),
            ),
            const Divider(),
            _Row(
              icon: Icons.folder_copy_outlined,
              title: tr('Documents'),
              subtitle: tr('Photos of RC, insurance, PUC and licence, on this phone only'),
              onTap: () => push(context, const WalletScreen()),
            ),
            const Divider(),
            _Row(
              icon: Icons.event_note_outlined,
              title: tr('Renewals and reminders'),
              subtitle: tr('PUC, insurance and service dates'),
              onTap: () => push(context, const RenewalsScreen()),
            ),
            const Divider(),
            _Row(
              icon: Icons.document_scanner_outlined,
              title: tr('Reach a car by its plate'),
              subtitle: tr('Point the camera at any number plate; the reading happens on this phone'),
              onTap: () => push(context, const PlateScanScreen()),
            ),
            const Divider(),
            _Row(
              icon: Icons.receipt_long_outlined,
              title: tr('Check challans'),
              subtitle: tr('Opens the official Parivahan e-challan site'),
              trailing: const Icon(Icons.open_in_new, size: 20, color: DL.muted),
              onTap: () => _openChallan(context, v.regNumber),
            ),
          ]),
        ),
        const SizedBox(height: 32),
        Label(tr('People and places')),
        const SizedBox(height: 12),
        Card(
          clipBehavior: Clip.antiAlias,
          child: Column(children: [
            _Row(
              icon: Icons.group_outlined,
              title: tr('Family'),
              subtitle: s.isOwner
                  ? (s.family.isEmpty ? tr('Share alerts with people who also drive this car') : tr('Shared with {n}', {'n': s.family.length}))
                  : tr('Shared with you · see who else gets alerts'),
              onTap: () => push(context, const FamilyScreen()),
            ),
            const Divider(),
            _Row(
              icon: Icons.apartment_outlined,
              title: tr('Society'),
              subtitle: s.societies.isEmpty
                  ? tr('Get parking notices from your apartment or office')
                  : s.societies.map((x) => x.name).join(', '),
              onTap: () => push(context, const SocietiesScreen()),
            ),
            const Divider(),
            _Row(
              icon: Icons.local_parking_outlined,
              title: tr('Where did I park'),
              subtitle: tr('Save your spot, walk back, get a reminder before parking runs out'),
              onTap: () => push(context, const ParkingScreen()),
            ),
            const Divider(),
            _Row(
              icon: Icons.straighten_outlined,
              title: tr('Fit Check'),
              subtitle: tr('Will a car fit your parking spot or garage?'),
              onTap: () => push(context, const FitCheckScreen()),
            ),
          ]),
        ),
        const SizedBox(height: 32),
        Label(tr('Tag and app')),
        const SizedBox(height: 12),
        Card(
          clipBehavior: Clip.antiAlias,
          child: Column(children: [
            _Row(
              icon: Icons.qr_code_2_outlined,
              title: tr('Tag settings'),
              subtitle: s.isOwner ? tr('Pause, replace or share your tag') : tr('Show or share the tag'),
              onTap: () => push(context, const TagScreen()),
            ),
            const Divider(),
            _Row(
              icon: Icons.translate_outlined,
              title: tr('Language'),
              subtitle: L10n.lang.value.native,
              onTap: () => showLanguageSheet(context),
            ),
          ]),
        ),
        const SizedBox(height: 32),
        Label(tr('Your privacy')),
        const SizedBox(height: 10),
        Text(
          tr('People who scan your tag see only your car\'s colour, make and model. Messages go through Connect, so no one sees a phone number. Your account lives on this phone: if you reinstall the app you\'ll need to set up your car again.'),
          style: DLText.body.copyWith(color: DL.muted),
        ),
      ])),
    );
  }
}

/// The e-challan site takes the plate on its own form; we can't prefill it
/// without scraping, so copy it to the clipboard on the way out.
Future<void> _openChallan(BuildContext context, String reg) async {
  await Clipboard.setData(ClipboardData(text: reg));
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('Number plate copied. Paste it on the Parivahan page.'))));
  }
  await launchUrl(Uri.parse('https://echallan.parivahan.gov.in/index/accused-challan'), mode: LaunchMode.externalApplication);
}

Future<void> showLanguageSheet(BuildContext context) => showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(tr('Language'), style: DLText.title),
            const SizedBox(height: 16),
            for (final l in AppLang.values) ...[
              SectionCard(
                selected: L10n.lang.value == l,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                onTap: () async {
                  Navigator.pop(c);
                  await L10n.set(l);
                },
                child: Row(children: [
                  Expanded(child: Text(l.native, style: DLText.strong)),
                  if (L10n.lang.value == l) const Icon(Icons.check, color: DL.violet),
                ]),
              ),
              const SizedBox(height: 8),
            ],
            Text(tr('The scan page strangers see has its own language switch.'), style: DLText.small),
          ]),
        ),
      ),
    );

class _Dim extends StatelessWidget {
  const _Dim(this.label, this.value);
  final String label;
  final String value;
  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Label(label),
        const SizedBox(height: 8),
        Text.rich(TextSpan(children: [
          TextSpan(text: value, style: DLText.numeral.copyWith(fontSize: 24)),
          if (value != '—') TextSpan(text: ' m', style: DLText.small),
        ])),
      ]),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.icon, required this.title, required this.subtitle, required this.onTap, this.trailing});
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        child: Row(children: [
          IconBadge(icon, size: 40),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: DLText.strong),
              const SizedBox(height: 2),
              Text(subtitle, style: DLText.small),
            ]),
          ),
          trailing ?? const Icon(Icons.chevron_right, color: DL.muted),
        ]),
      ),
    );
  }
}

class RenewalsScreen extends StatefulWidget {
  const RenewalsScreen({super.key});

  @override
  State<RenewalsScreen> createState() => _RenewalsScreenState();
}

class _RenewalsScreenState extends State<RenewalsScreen> {
  late final Vehicle _v = AppScope.read(context).vehicle!;
  late DateTime? _puc = _v.pucExpiry;
  late DateTime? _ins = _v.insuranceExpiry;
  late DateTime? _svc = _v.serviceDue;
  bool _saving = false;

  Future<DateTime?> _pick(DateTime? current) {
    final now = DateTime.now();
    return showDatePicker(
      context: context,
      initialDate: current ?? now,
      firstDate: DateTime(now.year - 2),
      lastDate: DateTime(now.year + 5),
      helpText: tr('Expiry or due date'),
    );
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    String? d(DateTime? x) => x == null ? null : DateFormat('yyyy-MM-dd').format(x);
    try {
      await AppScope.read(context).saveVehicle({'puc_expiry': d(_puc), 'insurance_expiry': d(_ins), 'service_due': d(_svc)});
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        showError(context, e);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final urgent = DueBadge.mostUrgent([_puc, _ins, _svc]);
    Widget row(int i, IconData icon, String label, String help, DateTime? value, ValueChanged<DateTime?> set) => InkWell(
          onTap: () async {
            final picked = await _pick(value);
            if (picked != null) setState(() => set(picked));
          },
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 8, 14),
            child: Row(children: [
              IconBadge(icon, size: 40),
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(label, style: DLText.strong),
                  const SizedBox(height: 2),
                  Text(value == null ? help : DateFormat('d MMM yyyy').format(value), style: DLText.small),
                ]),
              ),
              DueBadge(date: value, urgent: i == urgent),
              if (value != null)
                IconButton(tooltip: tr('Clear'), icon: const Icon(Icons.close, size: 18), onPressed: () => setState(() => set(null)))
              else
                const SizedBox(width: 8),
            ]),
          ),
        );

    return Scaffold(
      appBar: AppBar(title: Text(tr('Renewals'))),
      body: SafeArea(
        child: ListView(padding: const EdgeInsets.fromLTRB(20, 8, 20, 32), children: [
          ScreenTitle(tr('Renewals and reminders')),
          const SizedBox(height: 8),
          Text(tr('We\'ll remind you 30 days and 7 days before, and on the day.'), style: DLText.body.copyWith(color: DL.muted)),
          const SizedBox(height: 24),
          Card(
            clipBehavior: Clip.antiAlias,
            child: Column(children: [
              row(0, Icons.eco_outlined, tr('PUC certificate'), tr('Printed on your PUC slip'), _puc, (d) => _puc = d),
              const Divider(),
              row(1, Icons.verified_user_outlined, tr('Insurance'), tr('Policy end date on your insurance'), _ins, (d) => _ins = d),
              const Divider(),
              row(2, Icons.build_outlined, tr('Next service'), tr('From your service booklet or last invoice'), _svc, (d) => _svc = d),
            ]),
          ),
          const SizedBox(height: 16),
          Text(tr('Driving with an expired PUC can mean a fine of ₹1,000 or more, and insurers usually ask for a valid PUC to renew.'),
              style: DLText.small),
          const SizedBox(height: 32),
          FilledButton(onPressed: _saving ? null : _save, child: Text(tr('Save'))),
        ]),
      ),
    );
  }
}
