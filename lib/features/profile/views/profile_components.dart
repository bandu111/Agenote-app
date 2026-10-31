import 'dart:convert';
import 'package:flutter/material.dart';
import '../../../app/l10n/app_strings.dart';

class ProfileSurface extends StatelessWidget {
  const ProfileSurface({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surfaceContainerLowest,
      borderRadius: BorderRadius.circular(20),
      border: Border.all(
        color: Theme.of(
          context,
        ).colorScheme.outlineVariant.withValues(alpha: .25),
      ),
    ),
    clipBehavior: Clip.antiAlias,
    child: Material(color: Colors.transparent, child: child),
  );
}

class ProfileSettingRow extends StatelessWidget {
  const ProfileSettingRow({
    super.key,
    required this.icon,
    required this.title,
    required this.control,
    this.subtitle,
    this.stackControl = false,
  });
  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget control;
  final bool stackControl;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title.tr(context),
          style: TextStyle(fontSize: 14, height: 1.35, color: colors.onSurface),
        ),
        if (subtitle != null) ...[
          const SizedBox(height: 4),
          Text(
            subtitle!.tr(context),
            style: TextStyle(
              fontSize: 11,
              height: 1.45,
              color: colors.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final stacked =
            stackControl &&
            (constraints.maxWidth < 280 ||
                MediaQuery.textScalerOf(context).scale(12) > 18);
        return ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Row(
            crossAxisAlignment: subtitle == null
                ? CrossAxisAlignment.center
                : CrossAxisAlignment.start,
            children: [
              Container(
                width: 32,
                height: 34,
                decoration: BoxDecoration(
                  color: colors.primary.withValues(alpha: .065),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, size: 18, color: colors.onSurfaceVariant),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: stacked
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [text, const SizedBox(height: 10), control],
                      )
                    : Row(
                        children: [
                          Expanded(child: text),
                          const SizedBox(width: 10),
                          control,
                        ],
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class ProfileAvatar extends StatelessWidget {
  const ProfileAvatar({super.key, this.data, this.size = 60});
  final String? data;
  final double size;
  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme;
    final placeholder = Icon(
      Icons.person_rounded,
      size: size * .56,
      color: color.primary,
    );
    Widget image = placeholder;
    if (data != null) {
      try {
        image = Image.memory(
          base64Decode(data!),
          width: size,
          height: size,
          fit: BoxFit.cover,
          gaplessPlayback: true,
          errorBuilder: (_, _, _) => placeholder,
        );
      } catch (_) {
        image = placeholder;
      }
    }
    return ClipOval(
      child: Container(
        width: size,
        height: size,
        color: color.primary.withValues(alpha: .09),
        alignment: Alignment.center,
        child: image,
      ),
    );
  }
}

void profileFeedback(BuildContext context, String text) => ScaffoldMessenger.of(
  context,
).showSnackBar(SnackBar(content: Text(text.tr(context))));
