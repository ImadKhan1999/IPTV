import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

/// ImadLabs design tokens (from the ImadLabs Graphics repo, brand/colors/tokens.json).
abstract final class Brand {
  static const electricCobalt = Color(0xFF0066FF);
  static const cyberMint = Color(0xFF00F5A0);
  static const quantumDot = Color(0xFF00FFC2);
  static const sky = Color(0xFF38BDF8);

  static const deepVoid = Color(0xFF070B14);
  static const slateObsidian = Color(0xFF0B0F19);
  static const surfaceCard = Color(0xFF111827);
  static const surfaceHover = Color(0xFF162032);
  static const border = Color(0xFF1E293B);
  static const focusRing = Color(0xFF38BDF8);

  static const textPrimary = Color(0xFFF8FAFC);
  static const textSecondary = Color(0xFF94A3B8);
  static const textMuted = Color(0xFF64748B);

  static const success = Color(0xFF10B981);
  static const warning = Color(0xFFF59E0B);
  static const error = Color(0xFFEF4444);

  static const brandGradient = LinearGradient(
    colors: [Color(0xFF00F5D4), electricCobalt],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static const progressGradient = LinearGradient(colors: [Color(0xFF00F5D4), electricCobalt]);

  static const headingFont = 'PlusJakartaSans';
  static const bodyFont = 'Inter';
}

ThemeData buildTheme() {
  const scheme = ColorScheme.dark(
    primary: Brand.cyberMint,
    onPrimary: Brand.deepVoid,
    secondary: Brand.electricCobalt,
    onSecondary: Colors.white,
    tertiary: Brand.sky,
    surface: Brand.slateObsidian,
    onSurface: Brand.textPrimary,
    surfaceContainerLowest: Brand.deepVoid,
    surfaceContainerLow: Brand.slateObsidian,
    surfaceContainer: Brand.surfaceCard,
    surfaceContainerHigh: Brand.surfaceHover,
    surfaceContainerHighest: Brand.border,
    onSurfaceVariant: Brand.textSecondary,
    outline: Brand.border,
    outlineVariant: Brand.border,
    error: Brand.error,
  );

  final base = ThemeData(useMaterial3: true, colorScheme: scheme, fontFamily: Brand.bodyFont);
  TextStyle? heading(TextStyle? s, FontWeight w) => s?.copyWith(fontFamily: Brand.headingFont, fontWeight: w);

  return base.copyWith(
    scaffoldBackgroundColor: Brand.deepVoid,
    canvasColor: Brand.deepVoid,
    dividerColor: Brand.border,
    focusColor: Brand.cyberMint.withValues(alpha: 0.16),
    hoverColor: Brand.surfaceHover,
    splashFactory: InkSparkle.splashFactory,
    textTheme: base.textTheme.copyWith(
      displaySmall: heading(base.textTheme.displaySmall, FontWeight.w800),
      headlineLarge: heading(base.textTheme.headlineLarge, FontWeight.w800),
      headlineMedium: heading(base.textTheme.headlineMedium, FontWeight.w700),
      headlineSmall: heading(base.textTheme.headlineSmall, FontWeight.w700),
      titleLarge: heading(base.textTheme.titleLarge, FontWeight.w700),
      titleMedium: base.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: Brand.deepVoid,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      systemOverlayStyle: SystemUiOverlayStyle.light,
    ),
    cardTheme: CardThemeData(
      color: Brand.surfaceCard,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: Colors.white.withValues(alpha: 0.06)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Brand.surfaceCard,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: Brand.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: Brand.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: Brand.focusRing, width: 2),
      ),
      labelStyle: const TextStyle(color: Brand.textSecondary),
      hintStyle: const TextStyle(color: Brand.textMuted),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style:
          FilledButton.styleFrom(
            backgroundColor: Brand.cyberMint,
            foregroundColor: Brand.deepVoid,
            textStyle: const TextStyle(fontWeight: FontWeight.w700, fontFamily: Brand.bodyFont),
            padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 16),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ).copyWith(
            side: WidgetStateProperty.resolveWith(
              (s) => s.contains(WidgetState.focused) ? const BorderSide(color: Colors.white, width: 3) : null,
            ),
          ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style:
          OutlinedButton.styleFrom(
            foregroundColor: Brand.textPrimary,
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ).copyWith(
            side: WidgetStateProperty.resolveWith(
              (s) => BorderSide(
                color: s.contains(WidgetState.focused) ? Brand.focusRing : Brand.border,
                width: s.contains(WidgetState.focused) ? 2.5 : 1,
              ),
            ),
          ),
    ),
    chipTheme: base.chipTheme.copyWith(
      backgroundColor: Brand.surfaceCard,
      selectedColor: Brand.cyberMint.withValues(alpha: 0.18),
      side: const BorderSide(color: Brand.border),
      labelStyle: const TextStyle(color: Brand.textPrimary, fontFamily: Brand.bodyFont),
    ),
    listTileTheme: const ListTileThemeData(iconColor: Brand.textSecondary),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? Brand.deepVoid : Brand.textSecondary,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? Brand.cyberMint : Brand.border,
      ),
    ),
    snackBarTheme: const SnackBarThemeData(
      backgroundColor: Brand.surfaceHover,
      contentTextStyle: TextStyle(color: Brand.textPrimary),
      behavior: SnackBarBehavior.floating,
    ),
    dialogTheme: const DialogThemeData(backgroundColor: Brand.slateObsidian),
    progressIndicatorTheme: const ProgressIndicatorThemeData(color: Brand.cyberMint, linearTrackColor: Brand.border),
    sliderTheme: const SliderThemeData(
      activeTrackColor: Brand.cyberMint,
      inactiveTrackColor: Brand.border,
      thumbColor: Brand.cyberMint,
    ),
  );
}
