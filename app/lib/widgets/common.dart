import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../l10n.dart';
import '../theme.dart';
import 'motion.dart';

/// White card, 1 px line, 12 px radius, no shadow.
class SectionCard extends StatelessWidget {
  const SectionCard({super.key, required this.child, this.padding = const EdgeInsets.all(18), this.onTap, this.selected = false});
  final Widget child;
  final EdgeInsets padding;
  final VoidCallback? onTap;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return Pressable(
      enabled: onTap != null,
      child: AnimatedContainer(
        duration: DL.fast,
        curve: DL.ease,
        decoration: BoxDecoration(
          color: selected ? DL.violetTint : DL.card,
          borderRadius: BorderRadius.circular(DL.rCard),
          border: Border.all(color: selected ? DL.violet : DL.line),
        ),
        child: Material(
          type: MaterialType.transparency,
          borderRadius: BorderRadius.circular(DL.rCard),
          clipBehavior: Clip.antiAlias,
          child: InkWell(onTap: onTap, child: Padding(padding: padding, child: child)),
        ),
      ),
    );
  }
}

/// A line icon on a flat square: muted on the ground tint by default, or a
/// status tone's text-on-tint pair.
class IconBadge extends StatelessWidget {
  const IconBadge(this.icon, {super.key, this.tone, this.size = 44});
  final IconData icon;
  final Tone? tone;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: tone?.bg ?? DL.ground, borderRadius: BorderRadius.circular(DL.rButton)),
      child: Icon(icon, color: tone?.mark ?? DL.muted, size: size * 0.5),
    );
  }
}

/// 11 px uppercase label.
class Label extends StatelessWidget {
  const Label(this.text, {super.key, this.color});
  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) => Text(text.toUpperCase(),
      style: DLText.label.copyWith(color: color, letterSpacing: tracked(text) ? null : 0), maxLines: 1, overflow: TextOverflow.ellipsis);
}

/// Wide tracking suits Latin capitals but pulls Indic conjuncts apart, so
/// labels in Hindi, Kannada or Tamil are set without it.
bool tracked(String s) => !s.runes.any((r) => r >= 0x0900 && r <= 0x0DFF);

/// Label above a form field, used instead of Material's floating label.
class FieldLabel extends StatelessWidget {
  const FieldLabel(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Padding(padding: const EdgeInsets.only(bottom: 8), child: Label(text));
}

/// Screen heading: optional label, then a Space Grotesk title.
class ScreenTitle extends StatelessWidget {
  const ScreenTitle(this.title, {super.key, this.eyebrow, this.subtitle});
  final String title;
  final String? eyebrow;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (eyebrow != null) ...[Label(eyebrow!), const SizedBox(height: 8)],
      Text(title, style: DLText.title),
      if (subtitle != null) ...[const SizedBox(height: 4), Text(subtitle!, style: DLText.small)],
    ]);
  }
}

/// Status chip: tone tint, 11 px uppercase, never wraps.
class StatusBadge extends StatelessWidget {
  const StatusBadge(this.text, {super.key, this.tone = Tone.info});
  final String text;
  final Tone tone;

  @override
  Widget build(BuildContext context) {
    // A status that changes while you watch (New -> On my way -> Sorted)
    // cross-fades rather than snapping.
    return AnimatedContainer(
      duration: DL.medium,
      curve: DL.ease,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(color: tone.bg, borderRadius: BorderRadius.circular(DL.rChip)),
      child: AnimatedSize(
        duration: DL.medium,
        curve: DL.ease,
        child: AnimatedSwitcher(
          duration: DL.fast,
          child: Text(
            text.toUpperCase(),
            key: ValueKey('$text$tone'),
            maxLines: 1,
            softWrap: false,
            style: DLText.label.copyWith(color: tone.fg, letterSpacing: tracked(text) ? 11 * 0.10 : 0),
          ),
        ),
      ),
    );
  }
}

/// Figure over a label. [live] colours the figure violet; [inverted] fills
/// the card with ink (one per row at most).
class StatCard extends StatelessWidget {
  const StatCard({super.key, required this.value, required this.label, this.live = false, this.inverted = false, this.onTap});
  final String value;
  final String label;
  final bool live;
  final bool inverted;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Pressable(
      enabled: onTap != null,
      child: Card(
      color: inverted ? DL.ink : null,
      shape: inverted ? const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(DL.rCard))) : null,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 12, 14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            AnimatedFigure(value, style: DLText.numeral.copyWith(color: inverted ? DL.onDark : (live ? DL.violet : DL.ink))),
            const SizedBox(height: 8),
            Text(label, maxLines: 2, overflow: TextOverflow.ellipsis, style: DLText.small.copyWith(color: inverted ? DL.onDarkMuted : DL.muted)),
          ]),
        ),
      ),
      ),
    );
  }
}

/// Small dot with a 1.6 s opacity pulse, for live status. Never on text.
class PulseDot extends StatefulWidget {
  const PulseDot({super.key, this.color = DL.violet, this.size = 8, this.pulse = true});
  final Color color;
  final double size;
  final bool pulse;

  @override
  State<PulseDot> createState() => _PulseDotState();
}

class _PulseDotState extends State<PulseDot> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 800));

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(PulseDot old) {
    super.didUpdateWidget(old);
    _sync();
  }

  void _sync() {
    if (widget.pulse) {
      if (!_c.isAnimating) _c.repeat(reverse: true);
    } else {
      _c.stop();
      _c.value = 0;
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dot = Container(
      width: widget.size,
      height: widget.size,
      decoration: BoxDecoration(color: widget.color, shape: BoxShape.circle),
    );
    if (MediaQuery.disableAnimationsOf(context)) return dot;
    return FadeTransition(opacity: Tween(begin: 1.0, end: 0.35).animate(_c), child: dot);
  }
}

/// A tappable card row: leading icon, title, subtitle, trailing.
class InfoRow extends StatelessWidget {
  const InfoRow({super.key, required this.title, this.subtitle, this.icon, this.tone, this.trailing, this.onTap});
  final String title;
  final String? subtitle;
  final IconData? icon;
  final Tone? tone;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      onTap: onTap,
      child: Row(children: [
        if (icon != null) ...[IconBadge(icon!, tone: tone, size: 40), const SizedBox(width: 14)],
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: DLText.strong),
            if (subtitle != null) ...[
              const SizedBox(height: 2),
              Text(subtitle!, style: DLText.small, maxLines: 2, overflow: TextOverflow.ellipsis),
            ],
          ]),
        ),
        if (trailing != null) ...[const SizedBox(width: 8), trailing!] else if (onTap != null) const Icon(Icons.chevron_right, color: DL.muted),
      ]),
    );
  }
}

/// Renewal due date as a badge. Pass [urgent] to the single most pressing one
/// on a screen: it's the only one allowed to use amber.
class DueBadge extends StatelessWidget {
  const DueBadge({super.key, required this.date, this.urgent = false});
  final DateTime? date;
  final bool urgent;

  static int? daysLeft(DateTime? date) => date?.difference(DateUtils.dateOnly(DateTime.now())).inDays;

  /// Index of the unexpired date due soonest within 30 days, if any.
  static int? mostUrgent(List<DateTime?> dates) {
    int? best;
    for (var i = 0; i < dates.length; i++) {
      final d = daysLeft(dates[i]);
      if (d == null || d < 0 || d > 30) continue;
      if (best == null || d < daysLeft(dates[best])!) best = i;
    }
    return best;
  }

  @override
  Widget build(BuildContext context) {
    final days = daysLeft(date);
    if (days == null) return StatusBadge(tr('Add date'), tone: Tone.neutral);
    if (days < 0) return StatusBadge(tr('Expired'), tone: Tone.error);
    if (days <= 30) return StatusBadge(days == 0 ? tr('Today') : tr('In {n} days', {'n': days}), tone: urgent ? Tone.warning : Tone.neutral);
    return StatusBadge(DateFormat('d MMM yyyy').format(date!), tone: Tone.success);
  }
}

void showError(BuildContext context, Object e) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(tr('Something went wrong. Check your internet and try again.'))),
  );
  debugPrint('$e');
}

String timeAgo(DateTime t) {
  final d = DateTime.now().difference(t);
  if (d.inMinutes < 1) return tr('just now');
  if (d.inMinutes < 60) return tr('{n} min ago', {'n': d.inMinutes});
  if (d.inHours < 24) return tr('{n} h ago', {'n': d.inHours});
  return tr('{n} d ago', {'n': d.inDays});
}

/// A plain full-width note with an icon, e.g. a privacy line under a form.
class FootNote extends StatelessWidget {
  const FootNote(this.text, {super.key, this.icon = Icons.lock_outline});
  final String text;
  final IconData icon;

  @override
  Widget build(BuildContext context) => Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(padding: const EdgeInsets.only(top: 1), child: Icon(icon, size: 16, color: DL.muted)),
        const SizedBox(width: 8),
        Expanded(child: Text(text, style: DLText.small)),
      ]);
}

/// An empty state: badge, heading, one line of explanation, optional action.
class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.icon, required this.title, required this.body, this.action});
  final IconData icon;
  final String title;
  final String body;
  final Widget? action;

  @override
  Widget build(BuildContext context) => SectionCard(
        padding: const EdgeInsets.fromLTRB(24, 32, 24, 28),
        child: Column(children: [
          IconBadge(icon, size: 56),
          const SizedBox(height: 16),
          Text(title, style: DLText.section, textAlign: TextAlign.center),
          const SizedBox(height: 8),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Text(body, textAlign: TextAlign.center, style: DLText.body.copyWith(color: DL.muted)),
          ),
          if (action != null) ...[const SizedBox(height: 20), action!],
        ]),
      );
}

/// Route with the app's page transition, for one-liners like `push(context, X())`.
Future<T?> push<T>(BuildContext context, Widget page) => Navigator.of(context).push<T>(MaterialPageRoute(builder: (_) => page));
