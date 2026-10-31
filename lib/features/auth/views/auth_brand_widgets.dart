import 'package:flutter/material.dart';
import '../../first_run/brand_tokens.dart';

/// Readdy B visual language, scoped to authentication; business app theme stays intact.
class AuthAppearance extends StatelessWidget {
  const AuthAppearance({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context),
        dark = Theme.of(context).brightness == Brightness.dark;
    final surface = dark ? const Color(0xFF101629) : BrandColors.surface;
    final background = dark ? const Color(0xFF151B2C) : BrandColors.background;
    final colors = theme.colorScheme.copyWith(
      primary: dark ? const Color(0xFF91B1FF) : BrandColors.blue,
      surface: surface,
      onSurface: dark ? const Color(0xFFF2F4FA) : BrandColors.ink,
      onSurfaceVariant: dark ? const Color(0xFFB0BCD5) : BrandColors.secondary,
    );
    return Theme(
      data: theme.copyWith(
        colorScheme: colors,
        scaffoldBackgroundColor: Colors.transparent,
        textTheme: theme.textTheme.apply(
          fontFamily: 'InstrumentSans',
          fontFamilyFallback: const ['AgenoteNotoSC'],
        ),
        textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(
            foregroundColor: colors.primary,
            minimumSize: const Size(48, 48),
          ),
        ),
      ),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: background,
          gradient: RadialGradient(
            center: const Alignment(-1, -1),
            radius: 1.4,
            colors: [
              dark ? const Color(0xFF1C2B50) : const Color(0xFFDDEAFF),
              background,
            ],
            stops: const [0, .8],
          ),
        ),
        child: TweenAnimationBuilder<double>(
          tween: Tween(begin: BrandMotion.reduced(context) ? 1 : 0, end: 1),
          duration: BrandMotion.reduced(context)
              ? Duration.zero
              : BrandMotion.enter,
          curve: BrandMotion.curve,
          builder: (_, t, child) => Opacity(
            opacity: t,
            child: Transform.translate(
              offset: Offset(0, 8 * (1 - t)),
              child: child,
            ),
          ),
          child: child,
        ),
      ),
    );
  }
}

class AuthFormSurface extends StatelessWidget {
  const AuthFormSurface({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: colors.surface.withValues(alpha: .92),
        borderRadius: BorderRadius.circular(30),
        border: Border.all(
          color: Theme.of(context).brightness == Brightness.dark
              ? Colors.white10
              : Colors.white.withValues(alpha: .8),
        ),
        boxShadow: [
          BoxShadow(
            color: BrandColors.ink.withValues(alpha: .025),
            blurRadius: 24,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: child,
    );
  }
}

class AuthButtonSurface extends StatelessWidget {
  const AuthButtonSurface({
    super.key,
    required this.child,
    required this.disabled,
  });
  final Widget child;
  final bool disabled;
  @override
  Widget build(BuildContext context) => AnimatedOpacity(
    opacity: disabled ? .5 : 1,
    duration: BrandMotion.reduced(context)
        ? Duration.zero
        : const Duration(milliseconds: 160),
    child: DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(99),
        gradient: const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [BrandColors.blueTop, BrandColors.blue],
        ),
      ),
      child: child,
    ),
  );
}
