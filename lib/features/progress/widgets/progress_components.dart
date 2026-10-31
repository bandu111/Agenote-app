import 'package:flutter/material.dart';
import '../../home/views/home_style.dart';

/// Reuse the established home palette, type, shadows and card shape.
class ProgressCard extends StatelessWidget {
  const ProgressCard({
    super.key,
    required this.child,
    this.padding = 12,
    this.clipBehavior = Clip.antiAlias,
    this.onTap,
  });
  final Widget child;
  final double padding;
  final Clip clipBehavior;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: EdgeInsets.all(padding),
    decoration: HomeStyle.card(context: context, radius: 16),
    child: Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: clipBehavior,
      child: InkWell(onTap: onTap, child: child),
    ),
  );
}

class ProgressTag extends StatelessWidget {
  const ProgressTag(
    this.label, {
    super.key,
    this.color = HomeStyle.blue,
    this.icon,
    this.fontSize = 12,
  });
  final String label;
  final Color color;
  final IconData? icon;
  final double fontSize;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
    decoration: BoxDecoration(
      color: color.withValues(alpha: .08),
      borderRadius: BorderRadius.circular(24),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null) ...[
          Icon(icon, size: 9, color: color),
          const SizedBox(width: 4),
        ],
        Flexible(
          child: Text(
            label,
            style: HomeStyle.text(fontSize, bold: true, color: color),
          ),
        ),
      ],
    ),
  );
}

class ProgressPills extends StatelessWidget {
  const ProgressPills({
    super.key,
    required this.labels,
    required this.counts,
    required this.selected,
    required this.onSelected,
    this.solid = true,
    this.scrollable = false,
    this.keyPrefix = 'pill',
    this.dense = false,
  });
  final List<String> labels;
  final List<int> counts;
  final int selected;
  final ValueChanged<int> onSelected;
  final bool solid, scrollable, dense;
  final String keyPrefix;
  @override
  Widget build(BuildContext context) {
    final large = MediaQuery.textScalerOf(context).scale(14) > 20;
    final children = List.generate(labels.length, (index) {
      final active = selected == index;
      return Semantics(
        selected: active,
        button: true,
        child: InkWell(
          key: ValueKey('$keyPrefix-$index'),
          borderRadius: BorderRadius.circular(28),
          onTap: () => onSelected(index),
          child: AnimatedContainer(
            duration: MediaQuery.disableAnimationsOf(context)
                ? Duration.zero
                : const Duration(milliseconds: 220),
            constraints: const BoxConstraints(minHeight: 32),
            margin: const EdgeInsets.symmetric(vertical: 8, horizontal: 3),
            padding: EdgeInsets.symmetric(
              horizontal: dense ? 6 : 8,
              vertical: 4,
            ),
            decoration: BoxDecoration(
              color: active
                  ? (solid ? HomeStyle.blue : HomeStyle.surface(context))
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(28),
              boxShadow: active && !solid
                  ? const [BoxShadow(color: Color(0x146B7DBA), blurRadius: 8)]
                  : null,
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(
                    labels[index],
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.ellipsis,
                    style: HomeStyle.text(
                      dense ? 12 : 13,
                      bold: active,
                      color: active && solid
                          ? Colors.white
                          : active
                          ? HomeStyle.blue
                          : HomeStyle.foreground(context),
                    ),
                  ),
                ),
                SizedBox(width: 5),
                Container(
                  padding: EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                  decoration: BoxDecoration(
                    color: active && solid
                        ? Colors.white.withValues(alpha: .2)
                        : HomeStyle.tintColor(context, const Color(0xFFE7EDFF)),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Text(
                    '${counts[index]}',
                    style: HomeStyle.text(
                      11,
                      color: active && solid ? Colors.white : HomeStyle.blue,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    });
    final row = scrollable || large
        ? SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: children
                  .map(
                    (c) => SizedBox(
                      width: large
                          ? 200
                          : labels.length == 2
                          ? 180
                          : 136,
                      child: c,
                    ),
                  )
                  .toList(),
            ),
          )
        : Row(children: children.map((c) => Expanded(child: c)).toList());
    return Stack(
      alignment: Alignment.center,
      children: [
        Positioned(
          left: 0,
          right: 0,
          top: 6,
          bottom: 6,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: HomeStyle.tintColor(context, const Color(0xFFEAF0FF)),
              borderRadius: BorderRadius.circular(24),
            ),
          ),
        ),
        row,
      ],
    );
  }
}

class ProgressAction extends StatelessWidget {
  const ProgressAction(
    this.label, {
    super.key,
    required this.onPressed,
    this.icon = Icons.arrow_forward,
    this.filled = false,
  });
  final String label;
  final VoidCallback? onPressed;
  final IconData icon;
  final bool filled;
  @override
  Widget build(BuildContext context) => TextButton.icon(
    onPressed: onPressed,
    style: TextButton.styleFrom(
      foregroundColor: HomeStyle.blue,
      backgroundColor: filled
          ? HomeStyle.tintColor(context, const Color(0xFFEFF3FF))
          : null,
      minimumSize: const Size(48, 32),
      tapTargetSize: MaterialTapTargetSize.padded,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    iconAlignment: IconAlignment.end,
    icon: Icon(icon, size: 20),
    label: Text(
      label,
      style: HomeStyle.text(14, bold: true, color: HomeStyle.blue),
    ),
  );
}

class ProgressEmpty extends StatelessWidget {
  const ProgressEmpty(this.text, {super.key});
  final String text;
  @override
  Widget build(BuildContext context) => ProgressCard(
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 18),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: HomeStyle.text(14, color: HomeStyle.secondary(context)),
      ),
    ),
  );
}

class ProgressField extends StatelessWidget {
  const ProgressField(
    this.label,
    this.value, {
    super.key,
    this.icon,
    this.compact = false,
  });
  final String label, value;
  final IconData? icon;
  final bool compact;
  @override
  Widget build(BuildContext context) => Container(
    padding: EdgeInsets.all(compact ? 8 : 12),
    decoration: BoxDecoration(
      color: HomeStyle.tintColor(context, const Color(0xFFF1F4FE)),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (icon != null) ...[
          Icon(icon, size: 20, color: HomeStyle.blue),
          const SizedBox(width: 10),
        ],
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: HomeStyle.text(12, color: HomeStyle.secondary(context)),
              ),
              const SizedBox(height: 3),
              Text(
                value,
                maxLines: compact ? 1 : null,
                overflow: compact ? TextOverflow.ellipsis : null,
                style: HomeStyle.text(compact ? 13 : 14),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}
