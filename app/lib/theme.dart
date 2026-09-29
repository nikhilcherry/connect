import 'package:flutter/material.dart';

/// Dispatch Periwinkle design tokens. Hex values come from the design
/// language doc; don't introduce colours outside this file.
class DL {
  // Ground & surface
  static const ground = Color(0xFFEEEDF8);
  static const card = Color(0xFFFFFFFF);
  static const line = Color(0xFFDAD7EC);
  static const lineStrong = Color(0xFFCBC7E2);

  // Ink
  static const ink = Color(0xFF171335);
  static const muted = Color(0xFF575279);
  static const onDark = Color(0xFFFFFFFF);
  static const onDarkMuted = Color(0xFFC4BFDE);

  // Brand & accent
  static const violet = Color(0xFF5A45C9);
  static const violetDeep = Color(0xFF3C2C93);
  static const violetTint = Color(0xFFE2DEF7);

  /// Urgency only, at most once per screen. Only 4.0:1 on white, so small
  /// amber text uses [Tone.warning]'s darker foreground instead.
  static const amber = Color(0xFFD9540C);

  // Status
  static const success = Color(0xFF16775B);
  static const error = Color(0xFFBD2049);

  static const skeleton = Color(0xFFE6E4F3);
  static const scrim = Color(0x47171335); // rgba(23,19,53,0.28)
  static const floatShadow = [BoxShadow(color: Color(0x14171335), offset: Offset(0, -8), blurRadius: 24)];

  // Radii
  static const rChip = 6.0;
  static const rButton = 10.0;
  static const rCard = 12.0;
  static const rSheet = 16.0;

  // Motion. One curve everywhere; things move a few pixels, never across the
  // screen, and nothing bounces. Controls answer in [fast]; content arriving
  // (a list, a new message, a changed figure) takes [medium], staggered by
  // [stagger] so a screen reads top to bottom. See widgets/motion.dart.
  static const ease = Cubic(0.2, 0, 0, 1);
  static const fast = Duration(milliseconds: 140);
  static const medium = Duration(milliseconds: 240);
  static const stagger = Duration(milliseconds: 35);
  static const rise = 10.0;
}

/// Status colours are only ever used as a text-on-tint pair.
enum Tone {
  success(DL.success, Color(0xFFE2F1EC)),
  warning(Color(0xFFA63D05), Color(0xFFFBE9DD)),
  error(DL.error, Color(0xFFF8E1E7)),
  info(DL.violetDeep, DL.violetTint),
  neutral(DL.muted, DL.ground);

  const Tone(this.fg, this.bg);
  final Color fg;
  final Color bg;

  /// The solid mark (dot, icon) for this tone.
  Color get mark => this == warning ? DL.amber : fg;
}

const _tabular = [FontFeature.tabularFigures()];

TextStyle _grotesk(double size, {FontWeight weight = FontWeight.w700, double tracking = 0, double height = 1.15, Color color = DL.ink}) =>
    TextStyle(
      fontFamily: 'SpaceGrotesk',
      fontSize: size,
      fontWeight: weight,
      letterSpacing: size * tracking,
      height: height,
      color: color,
      fontFeatures: _tabular,
    );

TextStyle _manrope(double size, {FontWeight weight = FontWeight.w400, double tracking = 0, double height = 1.4, Color color = DL.ink}) =>
    TextStyle(
      fontFamily: 'Manrope',
      fontSize: size,
      fontWeight: weight,
      letterSpacing: size * tracking,
      height: height,
      color: color,
      fontFeatures: _tabular,
    );

/// Named roles from the type scale.
class DLText {
  static final display = _grotesk(40, tracking: -0.03, height: 1.05);
  static final title = _grotesk(26, tracking: -0.02, height: 1.15);
  static final section = _manrope(17, weight: FontWeight.w600, height: 1.3);
  static final body = _manrope(15, height: 1.65);
  static final small = _manrope(13, color: DL.muted);
  static final label = _manrope(11, weight: FontWeight.w600, tracking: 0.16, height: 1, color: DL.muted);
  static final numeral = _grotesk(30, tracking: -0.01, height: 1);
  static final strong = _manrope(15, weight: FontWeight.w600, height: 1.35);
}

/// Slide 3 % + fade, finishing in 140 ms even though routes run 300 ms.
class _DispatchTransitions extends PageTransitionsBuilder {
  const _DispatchTransitions();

  @override
  Widget buildTransitions<T>(PageRoute<T> route, BuildContext context, Animation<double> animation,
      Animation<double> secondaryAnimation, Widget child) {
    final curved = CurvedAnimation(parent: animation, curve: const Interval(0, 140 / 300, curve: DL.ease));
    return FadeTransition(
      opacity: curved,
      child: SlideTransition(
        position: Tween(begin: const Offset(0.03, 0), end: Offset.zero).animate(curved),
        child: child,
      ),
    );
  }
}

/// Focused inputs get a 1 px border plus a 3 px violet-tint ring.
class _RingBorder extends OutlineInputBorder {
  const _RingBorder({super.borderSide, super.borderRadius});

  @override
  _RingBorder copyWith({BorderSide? borderSide, BorderRadius? borderRadius, double? gapPadding}) =>
      _RingBorder(borderSide: borderSide ?? this.borderSide, borderRadius: borderRadius ?? this.borderRadius);

  @override
  void paint(Canvas canvas, Rect rect,
      {double? gapStart, double gapExtent = 0.0, double gapPercentage = 0.0, TextDirection? textDirection}) {
    final ring = borderRadius.resolve(textDirection).toRRect(rect).inflate(2);
    canvas.drawRRect(
      ring,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..color = DL.violetTint,
    );
    super.paint(canvas, rect, gapStart: gapStart, gapExtent: gapExtent, gapPercentage: gapPercentage, textDirection: textDirection);
  }
}

ThemeData buildTheme() {
  const scheme = ColorScheme(
    brightness: Brightness.light,
    primary: DL.violet,
    onPrimary: DL.onDark,
    primaryContainer: DL.violetTint,
    onPrimaryContainer: DL.violetDeep,
    secondary: DL.violet,
    onSecondary: DL.onDark,
    secondaryContainer: DL.violetTint,
    onSecondaryContainer: DL.violetDeep,
    tertiary: DL.violetDeep,
    onTertiary: DL.onDark,
    error: DL.error,
    onError: DL.onDark,
    surface: DL.card,
    onSurface: DL.ink,
    onSurfaceVariant: DL.muted,
    surfaceContainerLowest: DL.card,
    surfaceContainerLow: DL.card,
    surfaceContainer: DL.card,
    surfaceContainerHigh: DL.card,
    surfaceContainerHighest: DL.ground,
    outline: DL.lineStrong,
    outlineVariant: DL.line,
    inverseSurface: DL.ink,
    onInverseSurface: DL.onDark,
    inversePrimary: DL.violetTint,
    shadow: DL.ink,
    scrim: DL.ink,
    surfaceTint: Colors.transparent,
  );

  final text = TextTheme(
    displayLarge: DLText.display.copyWith(fontSize: 44),
    displayMedium: DLText.display,
    displaySmall: _grotesk(34, tracking: -0.03, height: 1.05),
    headlineLarge: DLText.title,
    headlineMedium: DLText.title,
    headlineSmall: DLText.title,
    titleLarge: DLText.section,
    titleMedium: DLText.section,
    titleSmall: DLText.strong,
    bodyLarge: DLText.body,
    bodyMedium: _manrope(15, height: 1.5, color: DL.muted),
    bodySmall: DLText.small,
    labelLarge: _manrope(15, weight: FontWeight.w600, height: 1.2),
    labelMedium: _manrope(13, weight: FontWeight.w600, height: 1.2),
    labelSmall: DLText.label,
  );

  final buttonText = _manrope(15, weight: FontWeight.w700, height: 1.2);
  const buttonShape = RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(DL.rButton)));
  const buttonPadding = EdgeInsets.symmetric(vertical: 16, horizontal: 28);
  final inputRadius = BorderRadius.circular(DL.rChip);
  const transitions = _DispatchTransitions();

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    fontFamily: 'Manrope',
    textTheme: text,
    scaffoldBackgroundColor: DL.ground,
    canvasColor: DL.ground,
    dividerColor: DL.line,
    highlightColor: DL.violetTint.withValues(alpha: 0.5),
    splashColor: DL.violetTint.withValues(alpha: 0.6),
    pageTransitionsTheme: const PageTransitionsTheme(builders: {
      TargetPlatform.android: transitions,
      TargetPlatform.iOS: transitions,
      TargetPlatform.linux: transitions,
      TargetPlatform.macOS: transitions,
      TargetPlatform.windows: transitions,
      TargetPlatform.fuchsia: transitions,
    }),
    iconTheme: const IconThemeData(color: DL.muted, size: 24),
    appBarTheme: AppBarTheme(
      backgroundColor: DL.ground,
      surfaceTintColor: Colors.transparent,
      scrolledUnderElevation: 0,
      elevation: 0,
      centerTitle: false,
      foregroundColor: DL.ink,
      iconTheme: const IconThemeData(color: DL.ink),
      actionsIconTheme: const IconThemeData(color: DL.muted),
      titleTextStyle: DLText.section,
    ),
    cardTheme: const CardThemeData(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: DL.card,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(DL.rCard)),
        side: BorderSide(color: DL.line),
      ),
    ),
    dividerTheme: const DividerThemeData(color: DL.line, thickness: 1, space: 1),
    filledButtonTheme: FilledButtonThemeData(
      style: ButtonStyle(
        minimumSize: const WidgetStatePropertyAll(Size(44, 52)),
        padding: const WidgetStatePropertyAll(buttonPadding),
        shape: const WidgetStatePropertyAll(buttonShape),
        elevation: const WidgetStatePropertyAll(0),
        textStyle: WidgetStatePropertyAll(buttonText),
        backgroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.disabled)
            ? DL.violetTint
            : s.contains(WidgetState.pressed)
                ? DL.violetDeep
                : DL.violet),
        foregroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.disabled) ? DL.muted : DL.onDark),
        iconColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.disabled) ? DL.muted : DL.onDark),
        overlayColor: const WidgetStatePropertyAll(Colors.transparent),
        animationDuration: DL.fast,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: ButtonStyle(
        minimumSize: const WidgetStatePropertyAll(Size(44, 52)),
        padding: const WidgetStatePropertyAll(buttonPadding),
        shape: const WidgetStatePropertyAll(buttonShape),
        textStyle: WidgetStatePropertyAll(buttonText.copyWith(fontWeight: FontWeight.w600)),
        backgroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.pressed) ? DL.ground : DL.card),
        foregroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.disabled) ? DL.muted : DL.ink),
        iconColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.disabled) ? DL.muted : DL.violet),
        side: const WidgetStatePropertyAll(BorderSide(color: DL.line)),
        overlayColor: const WidgetStatePropertyAll(Colors.transparent),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: ButtonStyle(
        minimumSize: const WidgetStatePropertyAll(Size(44, 44)),
        padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 12)),
        shape: const WidgetStatePropertyAll(buttonShape),
        textStyle: WidgetStatePropertyAll(buttonText.copyWith(fontWeight: FontWeight.w600)),
        foregroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.disabled)
            ? DL.muted
            : s.contains(WidgetState.pressed)
                ? DL.violetDeep
                : DL.violet),
        iconColor: const WidgetStatePropertyAll(DL.violet),
        overlayColor: const WidgetStatePropertyAll(DL.violetTint),
      ),
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: DL.violet,
      foregroundColor: DL.onDark,
      elevation: 0,
      focusElevation: 0,
      hoverElevation: 0,
      highlightElevation: 0,
      splashColor: DL.violetDeep,
      extendedTextStyle: buttonText,
      shape: buttonShape,
    ),
    iconButtonTheme: const IconButtonThemeData(
      style: ButtonStyle(
        minimumSize: WidgetStatePropertyAll(Size(44, 44)),
        overlayColor: WidgetStatePropertyAll(DL.violetTint),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: DL.card,
      hintStyle: _manrope(15, color: DL.muted),
      helperStyle: DLText.small,
      helperMaxLines: 2,
      errorStyle: _manrope(13, color: DL.error),
      counterStyle: DLText.small,
      prefixStyle: _manrope(15, color: DL.ink),
      suffixStyle: _manrope(15, color: DL.muted),
      prefixIconColor: DL.muted,
      floatingLabelBehavior: FloatingLabelBehavior.never,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      border: OutlineInputBorder(borderRadius: inputRadius, borderSide: const BorderSide(color: DL.line)),
      enabledBorder: OutlineInputBorder(borderRadius: inputRadius, borderSide: const BorderSide(color: DL.line)),
      disabledBorder: OutlineInputBorder(borderRadius: inputRadius, borderSide: const BorderSide(color: DL.line)),
      focusedBorder: _RingBorder(borderRadius: inputRadius, borderSide: const BorderSide(color: DL.violet)),
      errorBorder: OutlineInputBorder(borderRadius: inputRadius, borderSide: const BorderSide(color: DL.error)),
      focusedErrorBorder: _RingBorder(borderRadius: inputRadius, borderSide: const BorderSide(color: DL.error)),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: DL.card,
      selectedColor: DL.violetTint,
      disabledColor: DL.ground,
      side: WidgetStateBorderSide.resolveWith((s) => BorderSide(color: s.contains(WidgetState.selected) ? DL.violet : DL.line)),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(DL.rChip))),
      labelStyle: _manrope(13, weight: FontWeight.w600, color: DL.violet),
      secondaryLabelStyle: _manrope(13, weight: FontWeight.w600, color: DL.violetDeep),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
      showCheckmark: false,
      iconTheme: const IconThemeData(color: DL.violet, size: 18),
      elevation: 0,
      pressElevation: 0,
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        minimumSize: const WidgetStatePropertyAll(Size(44, 44)),
        shape: const WidgetStatePropertyAll(buttonShape),
        side: const WidgetStatePropertyAll(BorderSide(color: DL.line)),
        textStyle: WidgetStatePropertyAll(_manrope(15, weight: FontWeight.w600)),
        backgroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? DL.violetTint : DL.card),
        foregroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? DL.violetDeep : DL.violet),
      ),
      selectedIcon: const Icon(Icons.check, size: 18),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: DL.card,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      height: 72,
      indicatorColor: DL.violetTint,
      indicatorShape: const CircleBorder(),
      iconTheme: WidgetStateProperty.resolveWith(
          (s) => IconThemeData(color: s.contains(WidgetState.selected) ? DL.violet : DL.muted, size: 24)),
      labelTextStyle: WidgetStateProperty.resolveWith((s) =>
          _manrope(12, weight: FontWeight.w600, height: 1, color: s.contains(WidgetState.selected) ? DL.violet : DL.muted)),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: DL.card,
      surfaceTintColor: Colors.transparent,
      modalBackgroundColor: DL.card,
      modalBarrierColor: DL.scrim,
      elevation: 0,
      modalElevation: 0,
      dragHandleColor: DL.lineStrong,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(DL.rSheet))),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: DL.card,
      surfaceTintColor: Colors.transparent,
      barrierColor: DL.scrim,
      elevation: 0,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(DL.rSheet))),
      titleTextStyle: _grotesk(22, tracking: -0.02),
      contentTextStyle: _manrope(15, height: 1.5, color: DL.muted),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: DL.ink,
      contentTextStyle: _manrope(15, color: DL.onDark),
      actionTextColor: DL.violetTint,
      behavior: SnackBarBehavior.floating,
      elevation: 0,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(DL.rButton))),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: DL.card,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      textStyle: _manrope(15),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(DL.rCard)),
        side: BorderSide(color: DL.line),
      ),
    ),
    listTileTheme: ListTileThemeData(
      iconColor: DL.muted,
      titleTextStyle: _manrope(15, weight: FontWeight.w600),
      subtitleTextStyle: DLText.small,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
      minVerticalPadding: 16,
    ),
    switchTheme: SwitchThemeData(
      thumbColor: const WidgetStatePropertyAll(DL.card),
      trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? DL.violet : DL.lineStrong),
      trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
    ),
    checkboxTheme: CheckboxThemeData(
      fillColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? DL.violet : DL.card),
      checkColor: const WidgetStatePropertyAll(DL.onDark),
      side: const BorderSide(color: DL.lineStrong, width: 1.5),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(4))),
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(color: DL.violet, linearTrackColor: DL.skeleton),
    badgeTheme: BadgeThemeData(backgroundColor: DL.violet, textColor: DL.onDark, textStyle: _manrope(11, weight: FontWeight.w700)),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(color: DL.ink, borderRadius: BorderRadius.circular(DL.rChip)),
      textStyle: _manrope(13, color: DL.onDark),
    ),
    timePickerTheme: const TimePickerThemeData(backgroundColor: DL.card, elevation: 0),
    datePickerTheme: const DatePickerThemeData(backgroundColor: DL.card, surfaceTintColor: Colors.transparent, elevation: 0),
  );
}
