import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/app_state.dart';
import '../data/models.dart';
import '../l10n.dart';
import '../main.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/motion.dart';
import 'alert_thread.dart';
import 'away_status.dart';
import 'family_screen.dart';
import 'garage_tab.dart';
import 'home_shell.dart';
import 'parking_screen.dart';
import 'safety_tab.dart' show TripBanner, sendSos;
import 'society_screen.dart';
import 'tag_screen.dart';

class HomeTab extends StatelessWidget {
  const HomeTab({super.key});

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final v = s.vehicle!;
    final active = s.alerts.where((a) => a.status != AlertStatus.resolved && !a.blocked).toList();
    final nextDays = [v.pucExpiry, v.insuranceExpiry, v.serviceDue]
        .map(DueBadge.daysLeft)
        .whereType<int>()
        .fold<int?>(null, (m, d) => m == null || d < m ? d : m);
    final notice = s.notices.where((n) => DateTime.now().difference(n.createdAt).inDays < 7).firstOrNull;

    return SafeArea(
      child: RefreshIndicator(
        onRefresh: s.reload,
        child: ListView(padding: const EdgeInsets.fromLTRB(20, 20, 20, 32), children: revealAll([
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: ScreenTitle(
                  v.title,
                  eyebrow: s.isOwner ? 'Connect' : tr('Shared with you'),
                  subtitle: [v.prettyReg, if (v.colour != null) tr(v.colour!)].join(' · '),
                ),
              ),
              const SizedBox(width: 12),
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: _SosButton(onTap: () => _showEmergencySheet(context, s)),
              ),
            ],
          ),
          const SizedBox(height: 24),

          // New alerts slide in at the top; sorted ones fold away.
          Swap(
            child: active.isEmpty
                ? const SizedBox(key: ValueKey('calm'), width: double.infinity)
                : Column(key: const ValueKey('needs-you'), crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Label(tr('Needs you')),
                    const SizedBox(height: 12),
                    for (final a in active) ...[_LiveAlertCard(key: ValueKey(a.id), alert: a), const SizedBox(height: 12)],
                    const SizedBox(height: 20),
                  ]),
          ),

          const TripBanner(),

          IntrinsicHeight(
            child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Expanded(
                child: StatCard(
                  value: '${active.length}',
                  label: tr('Open alerts'),
                  live: active.isNotEmpty,
                  onTap: () => HomeShell.goTo(context, 1),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: StatCard(
                  value: nextDays == null ? '—' : (nextDays < 0 ? '0' : '$nextDays'),
                  label: nextDays == null ? tr('Add renewal dates') : (nextDays < 0 ? tr('Renewal overdue') : tr('Days to next renewal')),
                  onTap: () => push(context, const RenewalsScreen()),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: StatCard(
                  value: '${s.family.length + 1}',
                  label: s.family.isEmpty ? tr('Getting alerts') : tr('In the family'),
                  onTap: () => push(context, const FamilyScreen()),
                ),
              ),
            ]),
          ),
          const SizedBox(height: 12),

          SectionCard(
            onTap: () => push(context, const TagScreen()),
            child: Row(children: [
              if (s.tag != null) TagSticker(code: s.tag!.code, active: s.tag!.active, compact: true),
              const SizedBox(width: 18),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  s.tag?.active == true
                      ? StatusBadge(tr('Tag active'), tone: Tone.success)
                      : StatusBadge(tr('Tag paused'), tone: Tone.neutral),
                  const SizedBox(height: 10),
                  Text(tr('People near your car message you by scanning this.'), style: DLText.body.copyWith(height: 1.5)),
                  const SizedBox(height: 10),
                  Text(tr('View, share or print'), style: DLText.strong.copyWith(color: DL.violet)),
                ]),
              ),
            ]),
          ),

          if (notice != null) ...[
            const SizedBox(height: 32),
            Label(s.societies.where((x) => x.id == notice.societyId).firstOrNull?.name ?? tr('Society')),
            const SizedBox(height: 12),
            InfoRow(
              icon: Icons.campaign_outlined,
              tone: Tone.info,
              title: notice.body,
              subtitle: timeAgo(notice.createdAt),
              onTap: () => push(context, SocietyScreen(societyId: notice.societyId)),
            ),
          ],
          const SizedBox(height: 32),

          Label(tr('Around the car')),
          const SizedBox(height: 12),
          const AwayCard(),
          const SizedBox(height: 12),
          const ParkingCard(),
          const SizedBox(height: 32),

          Label(tr('Paperwork and safety')),
          const SizedBox(height: 12),
          _RenewalsCard(vehicle: v),
          const SizedBox(height: 12),
          InfoRow(
            icon: Icons.health_and_safety_outlined,
            tone: s.contacts.isEmpty ? null : Tone.success,
            title: s.contacts.isEmpty ? tr('Add an emergency contact') : tr('Emergency contacts: {n}', {'n': s.contacts.length}),
            subtitle: s.contacts.isEmpty ? tr('So Drive Mode knows who to alert after a crash.') : tr('Turn on Drive Mode before long trips.'),
            onTap: () => HomeShell.goTo(context, 2),
          ),
        ])),
      ),
    );
  }
}

class _LiveAlertCard extends StatelessWidget {
  const _LiveAlertCard({super.key, required this.alert});
  final CarAlert alert;

  @override
  Widget build(BuildContext context) {
    void open() => push(context, AlertThreadScreen(alertId: alert.id));
    return SectionCard(
      onTap: open,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          IconBadge(alert.kind.icon, tone: alert.kind.urgent ? Tone.error : Tone.info),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(tr(alert.kind.label), style: DLText.section),
              const SizedBox(height: 4),
              Row(children: [
                PulseDot(color: alert.kind.urgent ? DL.error : DL.violet, pulse: alert.status == AlertStatus.open),
                const SizedBox(width: 8),
                Flexible(child: Text('${tr(alert.status.label)} · ${timeAgo(alert.createdAt)}', style: DLText.small)),
                if (alert.photoPath != null) ...[
                  const SizedBox(width: 8),
                  const Icon(Icons.photo_outlined, size: 16, color: DL.muted),
                ],
              ]),
            ]),
          ),
          if (alert.kind.urgent) StatusBadge(tr('Urgent'), tone: Tone.error),
        ]),
        if (alert.note?.isNotEmpty == true) ...[
          const SizedBox(height: 12),
          Text('“${alert.note}”', maxLines: 2, overflow: TextOverflow.ellipsis, style: DLText.body.copyWith(height: 1.5)),
        ],
        const SizedBox(height: 14),
        SizedBox(width: double.infinity, child: FilledButton(onPressed: open, child: Text(tr('Reply')))),
      ]),
    );
  }
}

class _RenewalsCard extends StatelessWidget {
  const _RenewalsCard({required this.vehicle});
  final Vehicle vehicle;

  @override
  Widget build(BuildContext context) {
    final rows = [
      (tr('PUC'), Icons.eco_outlined, vehicle.pucExpiry),
      (tr('Insurance'), Icons.verified_user_outlined, vehicle.insuranceExpiry),
      (tr('Service'), Icons.build_outlined, vehicle.serviceDue),
    ];
    final urgent = DueBadge.mostUrgent(rows.map((r) => r.$3).toList());
    return SectionCard(
      padding: const EdgeInsets.fromLTRB(18, 6, 18, 6),
      onTap: () => push(context, const RenewalsScreen()),
      child: Column(children: [
        for (var i = 0; i < rows.length; i++) ...[
          if (i > 0) const Divider(),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Row(children: [
              Icon(rows[i].$2, size: 22, color: DL.muted),
              const SizedBox(width: 12),
              Expanded(child: Text(rows[i].$1, style: DLText.strong)),
              DueBadge(date: rows[i].$3, urgent: i == urgent),
            ]),
          ),
        ],
      ]),
    );
  }
}

class _SosButton extends StatelessWidget {
  const _SosButton({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'SOS',
      child: Pressable(
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: onTap,
            customBorder: const CircleBorder(),
            child: Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: DL.error,
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: Text(
                'SOS',
                style: DLText.label.copyWith(
                  color: DL.onDark,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.2,
                  fontSize: 13,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

void _showEmergencySheet(BuildContext context, AppState s) {
  HapticFeedback.mediumImpact();
  showModalBottomSheet<void>(
    context: context,
    backgroundColor: DL.card,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(DL.rSheet)),
    ),
    builder: (sheetContext) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: 20),
                decoration: BoxDecoration(
                  color: DL.lineStrong,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Row(
              children: [
                const IconBadge(Icons.call_outlined, tone: Tone.error, size: 40),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(tr('Emergency contacts'), style: DLText.section),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            SectionCard(
              onTap: () {
                Navigator.of(sheetContext).pop();
                launchUrl(Uri.parse('tel:112'));
              },
              child: Row(
                children: [
                  const IconBadge(Icons.call_outlined, tone: Tone.error, size: 44),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(tr('Call 112'), style: DLText.strong.copyWith(color: DL.error)),
                        const SizedBox(height: 2),
                        Text(
                          tr('Police, fire, ambulance'),
                          style: DLText.small,
                        ),
                      ],
                    ),
                  ),
                  const Icon(Icons.arrow_forward_ios, size: 14, color: DL.muted),
                ],
              ),
            ),
            const SizedBox(height: 12),
            SectionCard(
              onTap: () {
                Navigator.of(sheetContext).pop();
                if (s.contacts.isEmpty) {
                  HomeShell.goTo(context, 2);
                } else {
                  sendSos(context, s.contacts);
                }
              },
              child: Row(
                children: [
                  IconBadge(
                    Icons.sms_outlined,
                    tone: s.contacts.isNotEmpty ? Tone.warning : Tone.neutral,
                    size: 44,
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(tr('Send SOS'), style: DLText.strong),
                        const SizedBox(height: 2),
                        Text(
                          s.contacts.isEmpty
                              ? tr('Add a contact first')
                              : tr('Text your location'),
                          style: DLText.small,
                        ),
                      ],
                    ),
                  ),
                  const Icon(Icons.arrow_forward_ios, size: 14, color: DL.muted),
                ],
              ),
            ),
            const SizedBox(height: 16),
            OutlinedButton(
              onPressed: () => Navigator.of(sheetContext).pop(),
              child: Text(tr('Cancel')),
            ),
          ],
        ),
      ),
    ),
  );
}
