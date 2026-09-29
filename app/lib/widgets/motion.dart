import 'package:flutter/material.dart';

import '../theme.dart';

/// Motion primitives for Dispatch Periwinkle. Every one of them collapses to
/// an instant change when the system asks for reduced motion.
bool reduceMotion(BuildContext context) => MediaQuery.maybeDisableAnimationsOf(context) ?? false;

/// Fades content in while it rises [DL.rise] px, once, when first built.
/// [index] staggers siblings so a screen assembles top to bottom; the stagger
/// is capped so a long list never keeps someone waiting.
class Reveal extends StatelessWidget {
  const Reveal({super.key, required this.child, this.index = 0});
  final Widget child;
  final int index;

  @override
  Widget build(BuildContext context) {
    if (reduceMotion(context)) return child;
    final delay = DL.stagger * index.clamp(0, 8);
    final total = DL.medium + delay;
    final start = delay.inMicroseconds / total.inMicroseconds;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: total,
      curve: Interval(start, 1, curve: DL.ease),
      child: child,
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: Transform.translate(offset: Offset(0, (1 - t) * DL.rise), child: child),
      ),
    );
  }
}

/// Wraps each child of a column or list in a [Reveal] with a rising index.
/// Spacers pass through untouched and don't use up a stagger step.
List<Widget> revealAll(List<Widget> children) {
  var i = 0;
  return [for (final c in children) c is SizedBox && c.child == null ? c : Reveal(index: i++, child: c)];
}

/// Presses in to 98 % while held, the way a card gives under a thumb.
class Pressable extends StatefulWidget {
  const Pressable({super.key, required this.child, this.enabled = true, this.scale = 0.98});
  final Widget child;
  final bool enabled;
  final double scale;

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> {
  bool _down = false;

  void _set(bool v) {
    if (_down != v && mounted) setState(() => _down = v);
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled || reduceMotion(context)) return widget.child;
    return Listener(
      onPointerDown: (_) => _set(true),
      onPointerUp: (_) => _set(false),
      onPointerCancel: (_) => _set(false),
      child: AnimatedScale(scale: _down ? widget.scale : 1, duration: DL.fast, curve: DL.ease, child: widget.child),
    );
  }
}

/// A figure that counts to its new value instead of jumping. Non-numeric
/// values (a dash) cross-fade.
class AnimatedFigure extends StatelessWidget {
  const AnimatedFigure(this.value, {super.key, required this.style});
  final String value;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    final n = int.tryParse(value);
    if (n == null || reduceMotion(context)) {
      return AnimatedSwitcher(
        duration: DL.medium,
        switchInCurve: DL.ease,
        switchOutCurve: DL.ease,
        child: Text(value, key: ValueKey(value), maxLines: 1, style: style),
      );
    }
    return TweenAnimationBuilder<double>(
      tween: Tween(end: n.toDouble()),
      duration: const Duration(milliseconds: 420),
      curve: DL.ease,
      builder: (_, v, _) => Text('${v.round()}', maxLines: 1, style: style),
    );
  }
}

/// Cross-fade with a short rise, for a card or row whose state flips
/// (away / back, saved / empty). Give each state's child a distinct key.
class Swap extends StatelessWidget {
  const Swap({super.key, required this.child, this.alignment = Alignment.topCenter});
  final Widget child;
  final Alignment alignment;

  @override
  Widget build(BuildContext context) {
    if (reduceMotion(context)) return child;
    return AnimatedSize(
      duration: DL.medium,
      curve: DL.ease,
      alignment: alignment,
      child: AnimatedSwitcher(
        duration: DL.medium,
        switchInCurve: DL.ease,
        switchOutCurve: const Interval(0, 0.5, curve: DL.ease),
        layoutBuilder: (current, previous) => Stack(alignment: alignment, children: [...previous, ?current]),
        transitionBuilder: (child, a) => FadeTransition(
          opacity: a,
          child: SlideTransition(position: Tween(begin: const Offset(0, 0.04), end: Offset.zero).animate(a), child: child),
        ),
        child: child,
      ),
    );
  }
}

/// An [IndexedStack] that fades the incoming page through with a small rise,
/// keeping every page's scroll position and state.
class FadeThroughStack extends StatefulWidget {
  const FadeThroughStack({super.key, required this.index, required this.children});
  final int index;
  final List<Widget> children;

  @override
  State<FadeThroughStack> createState() => _FadeThroughStackState();
}

class _FadeThroughStackState extends State<FadeThroughStack> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: DL.medium, value: 1);
  late final _curve = CurvedAnimation(parent: _c, curve: DL.ease);

  @override
  void didUpdateWidget(FadeThroughStack old) {
    super.didUpdateWidget(old);
    if (old.index != widget.index) _c.forward(from: 0);
  }

  @override
  void dispose() {
    _curve.dispose();
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final stack = IndexedStack(index: widget.index, children: widget.children);
    if (reduceMotion(context)) return stack;
    return AnimatedBuilder(
      animation: _curve,
      builder: (_, child) => Opacity(
        opacity: _curve.value,
        child: Transform.translate(offset: Offset(0, (1 - _curve.value) * 6), child: child),
      ),
      child: stack,
    );
  }
}

/// Placeholder block for loading states, in the skeleton token, with a slow
/// sheen travelling across it.
class Skeleton extends StatefulWidget {
  const Skeleton({super.key, this.width, this.height = 16, this.radius = DL.rChip});
  final double? width;
  final double height;
  final double radius;

  @override
  State<Skeleton> createState() => _SkeletonState();
}

class _SkeletonState extends State<Skeleton> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400))..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final box = BoxDecoration(color: DL.skeleton, borderRadius: BorderRadius.circular(widget.radius));
    if (reduceMotion(context)) return Container(width: widget.width, height: widget.height, decoration: box);
    return AnimatedBuilder(
      animation: _c,
      builder: (_, _) => Container(
        width: widget.width,
        height: widget.height,
        decoration: box.copyWith(
          gradient: LinearGradient(
            begin: Alignment(-3 + _c.value * 4, 0),
            end: Alignment(-1 + _c.value * 4, 0),
            colors: const [DL.skeleton, DL.ground, DL.skeleton],
            stops: const [0.2, 0.5, 0.8],
          ),
        ),
      ),
    );
  }
}

/// A check mark that draws itself in, for "done" moments (saved, joined).
class DrawCheck extends StatelessWidget {
  const DrawCheck({super.key, this.size = 56, this.tone = Tone.success});
  final double size;
  final Tone tone;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: reduceMotion(context) ? 1 : 0, end: 1),
      duration: const Duration(milliseconds: 520),
      curve: DL.ease,
      builder: (_, t, _) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(color: tone.bg, borderRadius: BorderRadius.circular(DL.rButton)),
        child: CustomPaint(painter: _CheckPainter(t, tone.mark)),
      ),
    );
  }
}

class _CheckPainter extends CustomPainter {
  _CheckPainter(this.t, this.color);
  final double t;
  final Color color;

  @override
  void paint(Canvas canvas, Size s) {
    final path = Path()
      ..moveTo(s.width * 0.3, s.height * 0.52)
      ..lineTo(s.width * 0.44, s.height * 0.66)
      ..lineTo(s.width * 0.72, s.height * 0.36);
    final metric = path.computeMetrics().first;
    canvas.drawPath(
      metric.extractPath(0, metric.length * t),
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = s.width * 0.07
        ..strokeCap = StrokeCap.square,
    );
  }

  @override
  bool shouldRepaint(_CheckPainter old) => old.t != t || old.color != color;
}
