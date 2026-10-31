import 'package:flutter/material.dart';

/// Converted from Readdy B OKLCH; scoped to first-run, never overrides AppTheme.
abstract final class BrandColors {
  static const blue = Color(0xFF1663F9);
  static const blueTop = Color(0xFF3B81FF);
  static const background = Color(0xFFF2F6FD);
  static const surface = Color(0xFFFCFDFF);
  static const ink = Color(0xFF0E122F);
  static const secondary = Color(0xFF57627E);
  static const muted = Color(0xFF6B7794);
  static const tint = Color(0xFFDEEEFF);
  static const splash = Color(0xFF040617);
}

abstract final class BrandTypography {
  static TextStyle text(
    double size, {
    Color color = BrandColors.ink,
    FontWeight weight = FontWeight.w400,
    double height = 1.5,
    double spacing = 0,
  }) => TextStyle(
    fontFamily: 'InstrumentSans',
    fontFamilyFallback: const ['AgenoteNotoSC'],
    fontSize: size,
    color: color,
    fontWeight: weight,
    height: height,
    letterSpacing: spacing,
  );
}

abstract final class BrandSpacing {
  static const page = 28.0;
  static const gap = 12.0;
}

abstract final class BrandRadii {
  static const hero = 26.0;
  static const card = 22.0;
}

abstract final class BrandMotion {
  static const enter = Duration(milliseconds: 520);
  static const page = Duration(milliseconds: 300);
  static const curve = Cubic(.22, .61, .36, 1);
  static bool reduced(BuildContext context) =>
      MediaQuery.disableAnimationsOf(context) ||
      MediaQuery.accessibleNavigationOf(context);
}

abstract final class BrandAssets {
  static const logo = 'assets/branding/agenote_app_icon.png';
  static const device = 'assets/images/ai_voice/ai_voice_front.png';
}
