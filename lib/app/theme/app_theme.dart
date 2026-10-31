import 'package:flutter/material.dart';

abstract final class AppTheme {
  static const ink = Color(0xFF101846);
  static const blue = Color(0xFF065CFF);
  static const background = Color(0xFFF3F6FE);
  static ThemeData dark() {
    final base = light();
    final colors = ColorScheme.fromSeed(
      seedColor: blue,
      brightness: Brightness.dark,
      surface: const Color(0xFF101727),
      primary: const Color(0xFF91B1FF),
      onSurface: const Color(0xFFE7EDFC),
      onSurfaceVariant: const Color(0xFFA4B2CD),
    ).copyWith(surfaceContainerLowest: const Color(0xFF182237));
    return base.copyWith(
      brightness: Brightness.dark,
      colorScheme: colors,
      scaffoldBackgroundColor: colors.surface,
      textTheme: base.textTheme.apply(
        bodyColor: colors.onSurface,
        displayColor: colors.onSurface,
      ),
      appBarTheme: base.appBarTheme.copyWith(
        backgroundColor: colors.surface,
        foregroundColor: colors.onSurface,
      ),
      bottomSheetTheme: base.bottomSheetTheme.copyWith(
        backgroundColor: colors.surfaceContainerLowest,
      ),
      dividerTheme: base.dividerTheme.copyWith(
        color: colors.outlineVariant.withValues(alpha: .4),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: base.filledButtonTheme.style?.copyWith(
          backgroundColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.disabled)
                ? colors.onSurface.withValues(alpha: .12)
                : blue,
          ),
          foregroundColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.disabled)
                ? colors.onSurface.withValues(alpha: .38)
                : Colors.white,
          ),
        ),
      ),
      navigationBarTheme: base.navigationBarTheme.copyWith(
        backgroundColor: colors.surfaceContainerLowest,
        iconTheme: WidgetStateProperty.resolveWith(
          (states) => IconThemeData(
            color: states.contains(WidgetState.selected)
                ? colors.primary
                : colors.onSurfaceVariant,
          ),
        ),
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => TextStyle(
            fontSize: 12,
            color: states.contains(WidgetState.selected)
                ? colors.primary
                : colors.onSurfaceVariant,
            fontWeight: states.contains(WidgetState.selected)
                ? FontWeight.w600
                : FontWeight.w400,
          ),
        ),
      ),
    );
  }

  static ThemeData light() => ThemeData(
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(
      seedColor: blue,
      surface: background,
      primary: blue,
      onSurface: ink,
      onSurfaceVariant: const Color(0xFF67759D),
    ).copyWith(surfaceContainerLowest: Colors.white),
    scaffoldBackgroundColor: background,
    textTheme: const TextTheme(
      headlineLarge: TextStyle(
        fontSize: 32,
        height: 1.35,
        fontWeight: FontWeight.w500,
        color: ink,
      ),
      headlineMedium: TextStyle(
        fontSize: 26,
        height: 1.4,
        fontWeight: FontWeight.w500,
        color: ink,
      ),
      titleLarge: TextStyle(
        fontSize: 20,
        height: 1.4,
        fontWeight: FontWeight.w600,
        color: ink,
      ),
      titleMedium: TextStyle(
        fontSize: 16,
        height: 1.5,
        fontWeight: FontWeight.w600,
        color: ink,
      ),
      bodyLarge: TextStyle(fontSize: 16, height: 1.6, color: ink),
      bodyMedium: TextStyle(fontSize: 14, height: 1.6, color: ink),
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: background,
      foregroundColor: ink,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: Colors.white,
      indicatorColor: Colors.transparent,
      elevation: 0,
      iconTheme: WidgetStateProperty.resolveWith(
        (states) => IconThemeData(
          color: states.contains(WidgetState.selected)
              ? blue
              : const Color(0xFF67759D),
        ),
      ),
      labelTextStyle: WidgetStateProperty.resolveWith(
        (states) => TextStyle(
          fontSize: 12,
          color: states.contains(WidgetState.selected)
              ? blue
              : const Color(0xFF67759D),
          fontWeight: states.contains(WidgetState.selected)
              ? FontWeight.w600
              : FontWeight.w400,
        ),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(48, 52),
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(minimumSize: const Size(48, 48)),
    ),
    dividerTheme: const DividerThemeData(
      color: Color(0xFFE2E5E6),
      thickness: 1,
      space: 1,
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: background,
      showDragHandle: true,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
    ),
  );
}
