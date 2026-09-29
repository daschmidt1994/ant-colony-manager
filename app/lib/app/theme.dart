import 'package:flutter/material.dart';

import '../domain/due.dart';

/// Design tokens from docs/11-ux-grundlagen.md.
@immutable
class AppColors extends ThemeExtension<AppColors> {
  const AppColors({
    required this.overdue,
    required this.soon,
    required this.ok,
    required this.winter,
    required this.protein,
    required this.carbs,
    required this.muted,
    required this.surface2,
    required this.border,
  });

  final Color overdue, soon, ok, winter, protein, carbs, muted, surface2, border;

  static const dark = AppColors(
    overdue: Color(0xFFE5655B),
    soon: Color(0xFFE2B340),
    ok: Color(0xFF5DB36A),
    winter: Color(0xFF7FB4D9),
    protein: Color(0xFFC9785B),
    carbs: Color(0xFFD8A94A),
    muted: Color(0xFF9CA39D),
    surface2: Color(0xFF23272B),
    border: Color(0xFF2F3439),
  );

  static const light = AppColors(
    overdue: Color(0xFFC62828),
    soon: Color(0xFF9A6B00),
    ok: Color(0xFF2E7D32),
    winter: Color(0xFF2F6F9E),
    protein: Color(0xFFA0522D),
    carbs: Color(0xFF8C6414),
    muted: Color(0xFF5D645F),
    surface2: Color(0xFFECECE6),
    border: Color(0xFFD9DAD3),
  );

  Color due(DueStatus s) => switch (s) {
    DueStatus.overdue => overdue,
    DueStatus.soon => soon,
    DueStatus.ok => ok,
    DueStatus.paused => winter,
  };

  @override
  AppColors copyWith() => this;

  @override
  AppColors lerp(ThemeExtension<AppColors>? other, double t) => other is AppColors && t > .5 ? other : this;
}

extension AppColorsX on BuildContext {
  AppColors get colors => Theme.of(this).extension<AppColors>()!;
}

ThemeData buildTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final c = dark ? AppColors.dark : AppColors.light;
  final scheme = ColorScheme(
    brightness: brightness,
    primary: dark ? const Color(0xFF7DB36F) : const Color(0xFF3E7536),
    onPrimary: dark ? const Color(0xFF0E1A0B) : Colors.white,
    primaryContainer: dark ? const Color(0xFF2A3F25) : const Color(0xFFD6EBCF),
    onPrimaryContainer: dark ? const Color(0xFFD6EBCF) : const Color(0xFF12250E),
    secondary: dark ? const Color(0xFFD8A94A) : const Color(0xFF8C6414),
    onSecondary: dark ? const Color(0xFF231800) : Colors.white,
    error: c.overdue,
    onError: Colors.white,
    surface: dark ? const Color(0xFF1A1D20) : Colors.white,
    onSurface: dark ? const Color(0xFFE9EBE6) : const Color(0xFF1B1E1C),
    onSurfaceVariant: c.muted,
    surfaceContainerLowest: dark ? const Color(0xFF111315) : const Color(0xFFF5F5F1),
    surfaceContainerLow: dark ? const Color(0xFF16191B) : const Color(0xFFF8F8F5),
    surfaceContainer: dark ? const Color(0xFF1A1D20) : Colors.white,
    surfaceContainerHigh: c.surface2,
    surfaceContainerHighest: dark ? const Color(0xFF2A2F33) : const Color(0xFFE2E3DC),
    outline: c.border,
    outlineVariant: c.border,
  );
  final base = ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    brightness: brightness,
    fontFamily: 'Inter',
    scaffoldBackgroundColor: dark ? const Color(0xFF111315) : const Color(0xFFF5F5F1),
    extensions: [c],
  );
  return base.copyWith(
    appBarTheme: AppBarTheme(
      backgroundColor: base.scaffoldBackgroundColor,
      surfaceTintColor: Colors.transparent,
      centerTitle: false,
      titleTextStyle: base.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700, fontFamily: 'Inter'),
    ),
    cardTheme: CardThemeData(
      color: scheme.surface,
      elevation: dark ? 0 : 1,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(64, 52),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        textStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16, fontFamily: 'Inter'),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(64, 48),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
    ),
    chipTheme: ChipThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      // Explicit label color per state: without it the label had no color and
      // the web app drew it black on the dark surface (Artenkatalog filters).
      // Chips read the color from a WidgetStateColor inside the style.
      labelStyle: TextStyle(
        fontWeight: FontWeight.w500,
        fontSize: 14,
        fontFamily: 'Inter',
        color: WidgetStateColor.resolveWith(
          (states) => states.contains(WidgetState.disabled)
              ? scheme.onSurface.withValues(alpha: .38)
              : states.contains(WidgetState.selected)
              ? scheme.onSecondaryContainer
              : scheme.onSurface,
        ),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: c.surface2,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: scheme.surface,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
    ),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
    // Material 3 uses secondaryContainer (honey) for the active destination –
    // the design wants the moss accent.
    navigationBarTheme: NavigationBarThemeData(indicatorColor: scheme.primaryContainer),
    navigationRailTheme: NavigationRailThemeData(indicatorColor: scheme.primaryContainer),
    dividerTheme: DividerThemeData(color: c.border, space: 1),
  );
}
