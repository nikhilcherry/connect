import 'package:flutter/material.dart';
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
import 'car_photo_screen.dart';
import 'onboarding.dart';
import 'parking_screen.dart';
import 'damage_report_screen.dart';
import 'plate_scan_screen.dart';
import 'society_screen.dart';
import 'tag_screen.dart';
import 'wallet_screen.dart';
import 'whisper_screen.dart';

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
        if (s.vehicles.length > 1) ...[
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final c in s.vehicles)
              ChoiceChip(
                label: Text(c.title),
                selected: c.id == v.id,
                onSelected: (_) => s.selectVehicle(c.id).catchError((Object e) {
                  if (context.mounted) showError(context, e);
                }),
              ),
          ]),
          const SizedBox(height: 16),
        ],
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
        if (s.isOwner)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => push(context, const CarPhotoScreen(addAnother: true)),
              icon: const Icon(Icons.add),
              label: Text(tr('Add another car')),
            ),
          ),
        const SizedBox(height: 16),
        Label(tr('Running the car')),
        const SizedBox(height: 12),
        GridView.count(
          crossAxisCount: 3,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          crossAxisSpacing: 10,
          mainAxisSpacing: 10,
          childAspectRatio: 0.95,
          children: [
            _GridTile(
              icon: Icons.local_gas_station_outlined,
              title: tr('Fuel and expenses'),
              onTap: () => push(context, const GarageLogScreen()),
            ),
            _GridTile(
              icon: Icons.build_outlined,
              title: tr('Service history'),
              onTap: () => push(context, const GarageLogScreen(filter: LogFilter.service)),
            ),
            _GridTile(
              icon: Icons.folder_copy_outlined,
              title: tr('Documents'),
              onTap: () => push(context, const WalletScreen()),
            ),
            _GridTile(
              icon: Icons.event_note_outlined,
              title: tr('Renewals and reminders'),
              onTap: () => push(context, const RenewalsScreen()),
            ),
            _GridTile(
              icon: Icons.document_scanner_outlined,
              title: tr('Plate scan'),
              onTap: () => push(context, const PlateScanScreen()),
            ),
            _GridTile(
              icon: Icons.graphic_eq,
              title: tr('Sound alert'),
              onTap: () => push(context, const WhisperScreen()),
            ),
            _GridTile(
              icon: Icons.car_crash_outlined,
              title: tr('Check damage and cost'),
              onTap: () => push(context, const DamageReportScreen()),
            ),
            _GridTile(
              icon: Icons.receipt_long_outlined,
              title: tr('Check challans'),
              trailing: const Icon(Icons.open_in_new, size: 14, color: DL.muted),
              onTap: () => _openChallan(context, v.regNumber),
            ),
          ],
        ),
        const SizedBox(height: 28),
        Label(tr('People and places')),
        const SizedBox(height: 12),
        GridView.count(
          crossAxisCount: 3,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          crossAxisSpacing: 10,
          mainAxisSpacing: 10,
          childAspectRatio: 0.95,
          children: [
            _GridTile(
              icon: Icons.group_outlined,
              title: tr('Family'),
              onTap: () => push(context, const FamilyScreen()),
            ),
            _GridTile(
              icon: Icons.apartment_outlined,
              title: tr('Society'),
              onTap: () => push(context, const SocietiesScreen()),
            ),
            _GridTile(
              icon: Icons.local_parking_outlined,
              title: tr('Where did I park'),
              onTap: () => push(context, const ParkingScreen()),
            ),
            _GridTile(
              icon: Icons.straighten_outlined,
              title: tr('Fit Check'),
              onTap: () => push(context, const FitCheckScreen()),
            ),
          ],
        ),
        const SizedBox(height: 28),
        Label(tr('Tag and app')),
        const SizedBox(height: 12),
        GridView.count(
          crossAxisCount: 3,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          crossAxisSpacing: 10,
          mainAxisSpacing: 10,
          childAspectRatio: 0.95,
          children: [
            _GridTile(
              icon: Icons.qr_code_2_outlined,
              title: tr('Tag settings'),
              onTap: () => push(context, const TagScreen()),
            ),
            _GridTile(
              icon: Icons.translate_outlined,
              title: tr('Language'),
              onTap: () => showLanguageSheet(context),
            ),
          ],
        ),
        const SizedBox(height: 32),
        Label(tr('Your privacy')),
        const SizedBox(height: 10),
        Text(
          tr('People who scan your tag see only your car\'s colour, make and model. Messages go through Connect, so no one sees a phone number. Your account lives on this phone: if you reinstall the app you\'ll need to set up your car again.'),
          style: DLText.body.copyWith(color: DL.muted),
        ),
        const SizedBox(height: 12),
        TextButton.icon(
          style: TextButton.styleFrom(foregroundColor: DL.error),
          onPressed: () => _confirmDelete(context),
          icon: const Icon(Icons.delete_outline),
          label: Text(tr('Delete my account')),
        ),
      ])),
    );
  }
}

Future<void> _confirmDelete(BuildContext context) async {
  final s = AppScope.read(context);
  final ok = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(tr('Delete your account?')),
      content: Text(tr('This removes your car, tag, alerts, family links and everything saved on this phone. Printed stickers will stop working. It can\'t be undone.')),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: Text(tr('Cancel'))),
        TextButton(style: TextButton.styleFrom(foregroundColor: DL.error), onPressed: () => Navigator.pop(c, true), child: Text(tr('Delete everything'))),
      ],
    ),
  );
  if (ok != true || !context.mounted) return;
  final nav = Navigator.of(context);
  try {
    await s.deleteAccount();
    // Start a clean route stack at the app root rather than morphing the tabs
    // in place; the in-place swap left a blank screen.
    nav.pushAndRemoveUntil(MaterialPageRoute(builder: (_) => const AppRoot()), (r) => false);
  } catch (e) {
    if (context.mounted) showError(context, e);
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

class _GridTile extends StatelessWidget {
  const _GridTile({
    required this.icon,
    required this.title,
    required this.onTap,
    this.trailing,
  });

  final IconData icon;
  final String title;
  final VoidCallback onTap;
  final Widget? trailing;

  /// Toggle between white card boxes (true) and borderless icons (false).
  static const bool showBox = true;

  @override
  Widget build(BuildContext context) {
    final content = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Stack(
            alignment: Alignment.topRight,
            clipBehavior: Clip.none,
            children: [
              Icon(icon, size: 26, color: DL.ink),
              if (trailing != null)
                Positioned(
                  right: -8,
                  top: -4,
                  child: trailing!,
                ),
            ],
          ),
          const SizedBox(height: 6),
          Flexible(
            child: Text(
              title,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: DLText.small.copyWith(
                fontWeight: FontWeight.w600,
                color: DL.ink,
                fontSize: 11.5,
                height: 1.2,
              ),
            ),
          ),
        ],
      ),
    );

    if (showBox) {
      return Pressable(
        child: Card(
          margin: EdgeInsets.zero,
          clipBehavior: Clip.antiAlias,
          child: InkWell(onTap: onTap, child: content),
        ),
      );
    }

    return Pressable(
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(DL.rButton),
          onTap: onTap,
          child: content,
        ),
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
