import 'package:flutter/material.dart';

import '../data/models.dart';
import '../l10n.dart';
import '../main.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/motion.dart';
import 'alert_thread.dart';

class AlertsTab extends StatelessWidget {
  const AlertsTab({super.key});

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final visible = s.alerts.where((a) => !a.blocked).toList();

    return SafeArea(
      child: RefreshIndicator(
        onRefresh: s.refresh,
        child: ListView(padding: const EdgeInsets.fromLTRB(20, 20, 20, 32), children: [
          Reveal(child: ScreenTitle(tr('Alerts'), eyebrow: tr('{n} open', {'n': s.openAlerts}))),
          const SizedBox(height: 24),
          Swap(
            child: visible.isEmpty
                ? Reveal(
                    key: const ValueKey('empty'),
                    index: 1,
                    child: EmptyState(
                      icon: Icons.notifications_none_outlined,
                      title: tr('No alerts yet'),
                      body: tr('When someone scans your tag, say because your car is blocking theirs, their message lands here and you can chat without sharing numbers.'),
                    ),
                  )
                : Reveal(
                    key: const ValueKey('list'),
                    index: 1,
                    child: Card(
                      clipBehavior: Clip.antiAlias,
                      child: AnimatedSize(
                        duration: DL.medium,
                        curve: DL.ease,
                        alignment: Alignment.topCenter,
                        child: Column(children: [
                          for (var i = 0; i < visible.length; i++) ...[
                            if (i > 0) const Divider(),
                            _AlertRow(key: ValueKey(visible[i].id), alert: visible[i]),
                          ],
                        ]),
                      ),
                    ),
                  ),
          ),
        ]),
      ),
    );
  }
}

class _AlertRow extends StatelessWidget {
  const _AlertRow({super.key, required this.alert});
  final CarAlert alert;

  @override
  Widget build(BuildContext context) {
    final (tone, label) = switch (alert.status) {
      AlertStatus.open => (alert.kind.urgent ? Tone.error : Tone.info, alert.kind.urgent ? tr('Urgent') : tr('New')),
      AlertStatus.onMyWay => (Tone.neutral, tr('On my way')),
      AlertStatus.resolved => (Tone.success, tr('Sorted')),
    };
    return InkWell(
      onTap: () => push(context, AlertThreadScreen(alertId: alert.id)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        child: Row(children: [
          IconBadge(alert.kind.icon, size: 40, tone: alert.status == AlertStatus.open ? tone : null),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Flexible(child: Text(tr(alert.kind.label), style: DLText.strong, overflow: TextOverflow.ellipsis)),
                if (alert.photoPath != null) ...[const SizedBox(width: 6), const Icon(Icons.photo_outlined, size: 16, color: DL.muted)],
              ]),
              if (alert.note?.isNotEmpty == true)
                Text(alert.note!, maxLines: 1, overflow: TextOverflow.ellipsis, style: DLText.small.copyWith(color: DL.ink)),
              const SizedBox(height: 2),
              Text(timeAgo(alert.updatedAt), style: DLText.small),
            ]),
          ),
          const SizedBox(width: 8),
          StatusBadge(label, tone: tone),
        ]),
      ),
    );
  }
}
