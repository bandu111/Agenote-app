import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../models/schedule_item.dart';
import 'home_style.dart';

class StackedScheduleWidget extends StatefulWidget {
  const StackedScheduleWidget({
    super.key,
    required this.entries,
    required this.expanded,
    required this.onOpen,
  });
  final List<ScheduleEntry> entries;
  final bool expanded;
  final ValueChanged<ScheduleEntry> onOpen;
  @override
  State<StackedScheduleWidget> createState() => _StackedScheduleWidgetState();
}

class _StackedScheduleWidgetState extends State<StackedScheduleWidget> {
  Timer? _unlockTimer;
  bool _moving = false;
  Duration get _duration => MediaQuery.disableAnimationsOf(context)
      ? Duration.zero
      : const Duration(milliseconds: 380);
  String _order(StackedScheduleWidget widget) =>
      '${widget.expanded}:${widget.entries.map((entry) => entry.item.id).join(',')}';
  @override
  void didUpdateWidget(StackedScheduleWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_order(widget) != _order(oldWidget)) {
      _unlockTimer?.cancel();
      _moving = _duration != Duration.zero;
      if (_moving) {
        _unlockTimer = Timer(_duration, () {
          if (mounted) setState(() => _moving = false);
        });
      }
    }
  }

  @override
  void dispose() {
    _unlockTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.entries.isEmpty) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(24),
        decoration: HomeStyle.card(context: context),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('今天还没有安排', style: HomeStyle.text(16, bold: true)),
            const SizedBox(height: 6),
            Text(
              '留一些空间，按自己的节奏开始。',
              style: HomeStyle.text(14, color: HomeStyle.secondary(context)),
            ),
          ],
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) =>
          _buildDeck(context, constraints.maxWidth),
    );
  }

  Widget _buildDeck(BuildContext context, double width) {
    final scaler = MediaQuery.textScalerOf(context);
    final height = scaler.scale(14) > 20
        ? 40 +
              scaler.scale(14) * 1.45 +
              scaler.scale(15) * 2.9 +
              scaler.scale(12) * 1.45
        : widget.entries.fold<double>(72, (current, entry) {
            final time = TextPainter(
              text: TextSpan(
                text: entry.timeLabel,
                style: HomeStyle.text(14, bold: true),
              ),
              textDirection: Directionality.of(context),
              textScaler: scaler,
            )..layout();
            final title = TextPainter(
              text: TextSpan(
                text: entry.item.title,
                style: HomeStyle.text(15, bold: true),
              ),
              textDirection: Directionality.of(context),
              textScaler: scaler,
              maxLines: 2,
            )..layout(maxWidth: math.max(20, width - time.width - 122));
            return math.max(
              current,
              title.height + scaler.scale(12) * 1.45 + 28,
            );
          });
    final peek = math.max(36.0, scaler.scale(14) * 1.8);
    final count = widget.entries.length;
    final total = widget.expanded
        ? count * (height + 10) - 10
        : height + (math.min(count, 3) - 1) * peek;
    return IgnorePointer(
      ignoring: _moving,
      child: AnimatedContainer(
        key: const ValueKey('schedule-deck'),
        duration: _duration,
        curve: Curves.easeInOutCubic,
        height: total + 20,
        clipBehavior: Clip.hardEdge,
        decoration: const BoxDecoration(),
        child: Stack(
          children: [
            // Stable item keys retain each implicit animation when ranks change.
            for (var index = count - 1; index >= 0; index--)
              AnimatedPositioned(
                key: ValueKey(
                  'schedule-position-${widget.entries[index].item.id}',
                ),
                duration: _duration,
                curve: Curves.easeInOutCubic,
                top:
                    6 +
                    (widget.expanded
                        ? index * (height + 10)
                        : math.min(index, 2) * peek),
                left: 4 + (widget.expanded ? 0 : math.min(index, 2) * 10),
                right: 4 + (widget.expanded ? 0 : math.min(index, 2) * 10),
                height: height,
                child: ExcludeSemantics(
                  excluding: !widget.expanded && index >= 3,
                  child: IgnorePointer(
                    ignoring: !widget.expanded && index >= 3,
                    child: AnimatedOpacity(
                      duration: _duration,
                      opacity: !widget.expanded && index >= 3 ? 0 : 1,
                      child: _ScheduleCard(
                        entry: widget.entries[index],
                        preview: !widget.expanded && index > 0,
                        onTap: () => widget.onOpen(widget.entries[index]),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ScheduleCard extends StatelessWidget {
  const _ScheduleCard({
    required this.entry,
    required this.preview,
    required this.onTap,
  });
  final ScheduleEntry entry;
  final bool preview;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final task = entry.item.kind == ScheduleKind.task;
    final color = entry.isPast
        ? HomeStyle.secondary(context)
        : task
        ? HomeStyle.teal
        : HomeStyle.blue;
    final icon = task
        ? Icons.check_box_outlined
        : entry.item.id == 'meeting-review'
        ? Icons.videocam_outlined
        : Icons.calendar_today_outlined;
    return Semantics(
      button: true,
      onTap: onTap,
      label: '${entry.timeLabel} ${entry.item.title} ${entry.statusLabel}',
      excludeSemantics: true,
      child: Container(
        decoration: HomeStyle.card(context: context),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            key: ValueKey('schedule-card-${entry.item.id}'),
            borderRadius: BorderRadius.circular(20),
            onTap: onTap,
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                14,
                preview ? 0 : 12,
                10,
                preview ? 9 : 12,
              ),
              child: Align(
                alignment: preview ? Alignment.bottomCenter : Alignment.center,
                child:
                    !preview && MediaQuery.textScalerOf(context).scale(14) > 20
                    ? Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(icon, color: color, size: 22),
                              const SizedBox(width: 10),
                              Text(
                                entry.timeLabel,
                                style: HomeStyle.text(14, bold: true),
                              ),
                              const Spacer(),
                              Icon(
                                Icons.chevron_right,
                                size: 20,
                                color: HomeStyle.secondary(context),
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Text(
                            entry.item.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: HomeStyle.text(15, bold: true),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '${task ? '待办' : '会议'} · ${entry.statusLabel}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: HomeStyle.text(12, color: color),
                          ),
                        ],
                      )
                    : Row(
                        children: [
                          Container(
                            width: preview ? 30 : 36,
                            height: preview ? 30 : 36,
                            decoration: BoxDecoration(
                              color: color.withValues(alpha: .07),
                              shape: BoxShape.circle,
                            ),
                            child: Icon(
                              icon,
                              size: preview ? 18 : 20,
                              color: color,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Text(
                            entry.timeLabel,
                            style: HomeStyle.text(
                              preview ? 13 : 14,
                              bold: true,
                              color: entry.isPast
                                  ? HomeStyle.secondary(context)
                                  : HomeStyle.foreground(context),
                            ),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  entry.item.title,
                                  maxLines: preview ? 1 : 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: HomeStyle.text(
                                    preview ? 13 : 15,
                                    bold: true,
                                    color: entry.isPast
                                        ? HomeStyle.secondary(context)
                                        : HomeStyle.foreground(context),
                                  ),
                                ),
                                if (!preview) ...[
                                  const SizedBox(height: 4),
                                  Text(
                                    '${task ? '待办' : '会议'} · ${entry.statusLabel}',
                                    style: HomeStyle.text(12, color: color),
                                  ),
                                ],
                              ],
                            ),
                          ),
                          Icon(
                            Icons.chevron_right,
                            size: 20,
                            color: HomeStyle.secondary(context),
                          ),
                        ],
                      ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
