import 'package:flutter/material.dart';

abstract final class HomeStyle {
  static const blue = Color(0xFF065CFF);
  static const ink = Color(0xFF101846);
  static const muted = Color(0xFF67759D);
  static const background = Color(0xFFF3F6FE);
  static const teal = Color(0xFF00AE9E);
  static Color foreground(BuildContext context) =>
      Theme.of(context).colorScheme.onSurface;
  static Color secondary(BuildContext context) =>
      Theme.of(context).colorScheme.onSurfaceVariant;
  static Color canvas(BuildContext context) =>
      Theme.of(context).scaffoldBackgroundColor;
  static Color surface(BuildContext context) =>
      Theme.of(context).colorScheme.surfaceContainerLowest;
  static Color tint(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
      ? const Color(0xFF202E48)
      : const Color(0xFFF1F5FD);
  static Color tintColor(BuildContext context, Color color) {
    if (Theme.of(context).brightness != Brightness.dark) return color;
    final tone = HSLColor.fromColor(color).withLightness(.65).toColor();
    return Color.alphaBlend(tone.withValues(alpha: .14), surface(context));
  }

  static BoxDecoration card({double radius = 20, BuildContext? context}) =>
      BoxDecoration(
        color: context == null ? Colors.white : surface(context),
        borderRadius: BorderRadius.circular(radius),
        boxShadow: const [
          BoxShadow(
            color: Color(0x12577CB8),
            blurRadius: 18,
            offset: Offset(0, 5),
          ),
        ],
      );
  static TextStyle text(double size, {bool bold = false, Color? color}) =>
      TextStyle(
        fontSize: size,
        height: size >= 18 ? 1.25 : 1.45,
        color: color,
        fontWeight: bold ? FontWeight.w600 : FontWeight.w400,
      );
}

/// 三个首页板块共用较小的灰色标题，保持视觉层级一致。
class HomeSectionTitle extends StatelessWidget {
  const HomeSectionTitle(this.label, {super.key});
  final String label;

  @override
  Widget build(BuildContext context) => Text(
    label,
    style: HomeStyle.text(16, bold: true, color: HomeStyle.secondary(context)),
  );
}
