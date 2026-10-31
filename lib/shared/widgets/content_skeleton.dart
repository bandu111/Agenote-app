import 'package:flutter/material.dart';

enum SkeletonLayout { list, detail, document, transcript, device, home }

/// Content placeholders only. Save, permission, BLE and playback operations keep
/// their own real status indicators rather than looking like missing content.
class ContentSkeleton extends StatefulWidget {
  const ContentSkeleton({
    super.key,
    this.layout = SkeletonLayout.list,
    this.rows = 3,
    this.label = '正在加载内容',
    this.scrollable = true,
    this.padding = const EdgeInsets.all(16),
  });
  final SkeletonLayout layout;
  final int rows;
  final String label;
  final bool scrollable;
  final EdgeInsetsGeometry padding;

  @override
  State<ContentSkeleton> createState() => _ContentSkeletonState();
}

class _ContentSkeletonState extends State<ContentSkeleton>
    with SingleTickerProviderStateMixin {
  late final _motion = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  );
  bool _animate = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _animate =
        !MediaQuery.disableAnimationsOf(context) &&
        !MediaQuery.accessibleNavigationOf(context) &&
        TickerMode.valuesOf(context).enabled;
    if (_animate) {
      if (!_motion.isAnimating) _motion.repeat();
    } else {
      _motion.stop();
    }
  }

  @override
  void dispose() {
    _motion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final base = dark ? const Color(0xFF28364C) : const Color(0xFFE7EDFA);
    final highlight = dark ? const Color(0xFF3A4962) : const Color(0xFFF8FAFF);
    Widget bar({double height = 12, double fraction = 1}) => Align(
      alignment: AlignmentDirectional.centerStart,
      child: FractionallySizedBox(
        widthFactor: fraction,
        child: Container(
          height: height,
          decoration: BoxDecoration(
            color: base,
            borderRadius: BorderRadius.circular(height > 40 ? 16 : 6),
          ),
        ),
      ),
    );
    Widget row(int index) => Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: base.withValues(alpha: .7)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(
                    color: base,
                    borderRadius: BorderRadius.circular(
                      widget.layout == SkeletonLayout.transcript ? 15 : 9,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(child: bar(height: 14, fraction: .62)),
              ],
            ),
            const SizedBox(height: 16),
            bar(fraction: index.isEven ? .95 : .84),
            const SizedBox(height: 10),
            bar(fraction: .56),
            if (widget.layout == SkeletonLayout.transcript) ...[
              const SizedBox(height: 18),
              bar(height: 40),
            ],
          ],
        ),
      ),
    );
    Widget homeCard(List<Widget> children) => Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: base.withValues(alpha: .7)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: children,
      ),
    );
    final home = <Widget>[
      Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                bar(height: 10, fraction: .4),
                const SizedBox(height: 10),
                bar(height: 24, fraction: .65),
              ],
            ),
          ),
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(color: base, shape: BoxShape.circle),
          ),
        ],
      ),
      const SizedBox(height: 24),
      bar(height: 12, fraction: .22),
      const SizedBox(height: 10),
      homeCard([
        Row(
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: base,
                borderRadius: BorderRadius.circular(14),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                children: [
                  bar(height: 14, fraction: .65),
                  const SizedBox(height: 10),
                  bar(height: 10, fraction: .9),
                  const SizedBox(height: 8),
                  bar(height: 10, fraction: .5),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 22),
        Row(
          children: [
            Expanded(child: bar(height: 6)),
            const SizedBox(width: 16),
            Expanded(child: bar(height: 6)),
          ],
        ),
        const SizedBox(height: 22),
        Row(
          children: [
            Expanded(child: bar(height: 40)),
            const SizedBox(width: 8),
            SizedBox(width: 76, child: bar(height: 40)),
          ],
        ),
      ]),
      const SizedBox(height: 24),
      bar(height: 12, fraction: .22),
      const SizedBox(height: 10),
      homeCard([
        bar(height: 24, fraction: .15),
        const SizedBox(height: 10),
        bar(height: 10, fraction: .45),
        const SizedBox(height: 24),
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            for (final height in [48.0, 24.0, 68.0, 36.0, 56.0, 28.0, 44.0])
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: bar(height: height, fraction: .7),
                ),
              ),
          ],
        ),
      ]),
      const SizedBox(height: 24),
      bar(height: 18, fraction: .35),
      const SizedBox(height: 10),
      homeCard([
        Row(
          children: [
            for (var i = 0; i < 7; i++)
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 5),
                  child: bar(height: 48),
                ),
              ),
          ],
        ),
        const SizedBox(height: 24),
        bar(height: 14, fraction: .3),
        for (var i = 0; i < 3; i++) ...[
          const SizedBox(height: 22),
          bar(height: 14, fraction: .8),
          const SizedBox(height: 10),
          bar(height: 10, fraction: .45),
        ],
      ]),
    ];
    final body = Padding(
      padding: widget.padding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: widget.layout == SkeletonLayout.home
            ? home
            : [
                if (widget.layout != SkeletonLayout.list &&
                    widget.layout != SkeletonLayout.transcript) ...[
                  if (widget.layout == SkeletonLayout.device) ...[
                    bar(height: 120, fraction: .7),
                    const SizedBox(height: 22),
                  ],
                  bar(height: 24, fraction: .65),
                  const SizedBox(height: 14),
                  bar(fraction: .82),
                  const SizedBox(height: 24),
                  if (widget.layout == SkeletonLayout.document) ...[
                    bar(height: 180),
                    const SizedBox(height: 24),
                  ],
                ],
                for (var i = 0; i < widget.rows; i++) row(i),
              ],
      ),
    );
    final content = Align(
      alignment: widget.layout == SkeletonLayout.home
          ? Alignment.topCenter
          : Alignment.center,
      heightFactor: widget.scrollable ? null : 1,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: widget.scrollable ? SingleChildScrollView(child: body) : body,
      ),
    );
    return Semantics(
      label: widget.label,
      liveRegion: true,
      child: ExcludeSemantics(
        child: IgnorePointer(
          child: RepaintBoundary(
            child: !_animate
                ? content
                : AnimatedBuilder(
                    animation: _motion,
                    child: content,
                    builder: (_, child) => ShaderMask(
                      blendMode: BlendMode.srcATop,
                      shaderCallback: (bounds) => LinearGradient(
                        begin: Alignment(-3 + _motion.value * 6, -.2),
                        end: Alignment(-1 + _motion.value * 6, .2),
                        colors: [base, highlight, base],
                        stops: const [0, .5, 1],
                      ).createShader(bounds),
                      child: child,
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}
