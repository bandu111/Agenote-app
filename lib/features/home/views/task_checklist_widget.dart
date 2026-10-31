import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../models/schedule_item.dart';
import 'home_style.dart';

String taskDeadlineLabel(ScheduleEntry entry) {
  if (!entry.item.hasDeadline) return '交期待明确';
  final date = entry.localStart;
  return '${date.month}月${date.day}日${entry.item.deadlineHasTime ? ' ${entry.timeLabel}' : ''}${entry.status == ScheduleStatus.overdue ? ' · 已过期' : ''}';
}

/// 保留三层折叠卡片；完成以服务器确认成功为动画起点。
class TaskChecklistWidget extends StatelessWidget {
  const TaskChecklistWidget({
    super.key,
    required this.entries,
    required this.expanded,
    required this.savingId,
    required this.onComplete,
    required this.onDismissed,
    required this.onOpen,
    this.inline = false,
  });
  final bool inline;
  final List<ScheduleEntry> entries;
  final bool expanded;
  final String? savingId;
  final Future<bool> Function(String) onComplete;
  final ValueChanged<String> onDismissed;
  final ValueChanged<ScheduleEntry> onOpen;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 10),
    child: _content(context),
  );

  Widget _content(BuildContext context) {
    if (entries.isEmpty) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(24),
        decoration: HomeStyle.card(context: context),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('暂无待办任务', style: HomeStyle.text(16, bold: true)),
            const SizedBox(height: 6),
            Text(
              '会议纪要中的后续行动会整理到这里。',
              style: HomeStyle.text(13, color: HomeStyle.secondary(context)),
            ),
          ],
        ),
      );
    }
    final reduced = MediaQuery.disableAnimationsOf(context);
    final duration = reduced
        ? Duration.zero
        : const Duration(milliseconds: 320);
    Widget tile(ScheduleEntry entry, {bool preview = false}) => _TaskTile(
      key: ValueKey('task-tile-${entry.item.id}'),
      entry: entry,
      preview: preview,
      flat: inline,
      enabled: savingId == null,
      busy: savingId == entry.item.id,
      onComplete: () => onComplete(entry.item.id),
      onDismissed: () => onDismissed(entry.item.id),
      onOpen: () => onOpen(entry),
    );
    if (inline) {
      return Column(children: [for (final entry in entries) tile(entry)]);
    }
    return _OptionalSizeAnimation(
      duration: duration,
      alignment: Alignment.topCenter,
      curve: Curves.easeOutCubic,
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (expanded) {
            return Column(
              children: [
                for (final entry in entries)
                  Padding(
                    key: ValueKey(entry.item.id),
                    padding: const EdgeInsets.only(bottom: 10),
                    child: tile(entry),
                  ),
              ],
            );
          }
          // 动态测量标题，避免把大字号文字挤进固定高度。
          final scaler = MediaQuery.textScalerOf(context);
          double measure(String text, TextStyle style, int lines) {
            final painter = TextPainter(
              text: TextSpan(text: text, style: style),
              textDirection: Directionality.of(context),
              textScaler: scaler,
              maxLines: lines,
            )..layout(maxWidth: math.max(24, constraints.maxWidth - 100));
            return painter.height;
          }

          final height = entries
              .take(3)
              .fold<double>(
                84,
                (height, entry) => math.max(
                  height,
                  measure(entry.item.title, HomeStyle.text(14, bold: true), 3) +
                      measure(taskDeadlineLabel(entry), HomeStyle.text(12), 2) +
                      measure(entry.item.sourceLabel, HomeStyle.text(11), 1) +
                      28,
                ),
              );
          final count = math.min(3, entries.length);
          return SizedBox(
            key: const ValueKey('task-checklist-deck'),
            height: height + (count - 1) * 36 + 8,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                for (var index = count - 1; index >= 0; index--)
                  Positioned(
                    key: ValueKey(entries[index].item.id),
                    top: index * 36.0,
                    left: index * 8.0,
                    right: index * 8.0,
                    height: height,
                    child: tile(entries[index], preview: index > 0),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _TaskTile extends StatefulWidget {
  const _TaskTile({
    super.key,
    required this.entry,
    required this.preview,
    this.flat = false,
    required this.enabled,
    required this.busy,
    required this.onComplete,
    required this.onDismissed,
    required this.onOpen,
  });
  final ScheduleEntry entry;
  final bool flat;
  final bool preview, enabled, busy;
  final Future<bool> Function() onComplete;
  final VoidCallback onDismissed, onOpen;
  @override
  State<_TaskTile> createState() => _TaskTileState();
}

class _TaskTileState extends State<_TaskTile> {
  bool _submitting = false;
  Future<void> _complete() async {
    if (_submitting) return;
    setState(() => _submitting = true);
    try {
      await widget.onComplete();
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final done = widget.entry.item.completed;
    final secondary = HomeStyle.secondary(context);
    final reduced = MediaQuery.disableAnimationsOf(context);
    final duration = reduced
        ? Duration.zero
        : const Duration(milliseconds: 320);
    final entry = widget.entry;
    return _OptionalSizeAnimation(
      duration: duration,
      alignment: Alignment.topCenter,
      child: AnimatedOpacity(
        duration: duration,
        opacity: 1,
        child: AnimatedSlide(
          duration: duration,
          offset: Offset.zero,
          child: Align(
            heightFactor: 1,
            alignment: Alignment.topCenter,
            child: Container(
              decoration: widget.flat ? null : HomeStyle.card(context: context),
              child: Material(
                color: Colors.transparent,
                borderRadius: BorderRadius.circular(20),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  key: ValueKey('task-card-${entry.item.id}'),
                  onTap: widget.onOpen,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(6, 10, 12, 10),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (widget.busy || _submitting && !done)
                          const SizedBox(
                            width: 48,
                            height: 48,
                            child: Padding(
                              padding: EdgeInsets.all(14),
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          )
                        else
                          SizedBox(
                            width: 48,
                            height: 48,
                            child: Checkbox(
                              key: ValueKey('complete-task-${entry.item.id}'),
                              value: done,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(6),
                              ),
                              onChanged:
                                  widget.enabled &&
                                      !entry.item.reviewPending &&
                                      (done ||
                                          entry.status !=
                                              ScheduleStatus.overdue)
                                  ? (_) => _complete()
                                  : null,
                              semanticLabel:
                                  '${done ? '撤销完成' : '完成任务'}：${entry.item.title}',
                            ),
                          ),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                entry.item.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style:
                                    HomeStyle.text(
                                      14,
                                      bold: true,
                                      color: done ? secondary : null,
                                    ).copyWith(
                                      decoration: done
                                          ? TextDecoration.lineThrough
                                          : TextDecoration.none,
                                    ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                done
                                    ? '已完成'
                                    : entry.item.reviewPending
                                    ? 'AI 核对中'
                                    : taskDeadlineLabel(entry),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: HomeStyle.text(
                                  12,
                                  color: done ? HomeStyle.teal : secondary,
                                ),
                              ),
                              if (!widget.preview) ...[
                                const SizedBox(height: 3),
                                Text(
                                  entry.item.sourceLabel,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: HomeStyle.text(11, color: secondary),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _OptionalSizeAnimation extends StatelessWidget {
  const _OptionalSizeAnimation({
    required this.duration,
    required this.child,
    this.alignment = Alignment.center,
    this.curve = Curves.linear,
  });
  final Duration duration;
  final Widget child;
  final AlignmentGeometry alignment;
  final Curve curve;
  @override
  Widget build(BuildContext context) => duration == Duration.zero
      ? child
      : AnimatedSize(
          duration: duration,
          alignment: alignment,
          curve: curve,
          child: child,
        );
}
