import '../../../shared/widgets/content_skeleton.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:go_router/go_router.dart';
import '../models/schedule_item.dart';
import '../viewmodels/schedule_view_model.dart';
import '../viewmodels/home_view_model.dart';
import 'home_style.dart';
import 'task_checklist_widget.dart';

class ScheduleSection extends StatelessWidget {
  const ScheduleSection({super.key});
  @override
  Widget build(BuildContext context) => Consumer<ScheduleViewModel>(
    builder: (context, model, _) {
      final selected = model.selectedEntries;
      final tasks = selected
          .where((e) => e.item.kind == ScheduleKind.task)
          .toList();
      final meetings = selected
          .where((e) => e.item.kind == ScheduleKind.meeting)
          .toList();
      final date = model.selectedDate;
      final today = model.clock.toLocal(model.clock.now);
      Future<void> open(ScheduleEntry entry) async {
        final route = entry.item.sourceRoute;
        if (route != null &&
            (route.startsWith('/meetings/') || route == '/notifications')) {
          await context.push(route);
          if (context.mounted) await model.refresh();
          if (context.mounted) await context.read<HomeViewModel?>()?.refresh();
        } else {
          await _showDetail(context, entry);
        }
      }

      Widget dot(Color color) => Container(
        width: 4,
        height: 4,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      );
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text('任务与会议', style: HomeStyle.text(19, bold: true)),
              ),
              TextButton(
                key: const ValueKey('timeline-pending-count'),
                onPressed: model.pendingTaskCount == 0
                    ? null
                    : () => _showPendingTasks(context, model, open),
                style: TextButton.styleFrom(
                  foregroundColor: HomeStyle.secondary(context),
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  textStyle: HomeStyle.text(11),
                ),
                child: Text('${model.pendingTaskCount}项待完成'),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (model.loading && selected.isEmpty)
            const ContentSkeleton(
              rows: 2,
              scrollable: false,
              label: '正在加载任务与会议',
            )
          else
            Container(
              decoration: BoxDecoration(
                color: HomeStyle.surface(context),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: Theme.of(
                    context,
                  ).colorScheme.outlineVariant.withValues(alpha: .35),
                ),
              ),
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 10),
              child: Column(
                children: [
                  _TimelineWeeks(
                    today: today,
                    selected: date,
                    onSelect: model.selectDate,
                    builder: (week) => Row(
                      children: [
                        for (var index = 0; index < 7; index++)
                          Expanded(
                            child: Builder(
                              builder: (context) {
                                final day = DateTime(
                                  week.year,
                                  week.month,
                                  week.day + index,
                                );
                                final rows = model.entriesOn(day);
                                final active =
                                    day.year == date.year &&
                                    day.month == date.month &&
                                    day.day == date.day;
                                final isToday =
                                    day.year == today.year &&
                                    day.month == today.month &&
                                    day.day == today.day;
                                final mc = rows
                                    .where(
                                      (e) =>
                                          e.item.kind == ScheduleKind.meeting,
                                    )
                                    .length;
                                final tc = rows
                                    .where(
                                      (e) => e.item.kind == ScheduleKind.task,
                                    )
                                    .length;
                                return Semantics(
                                  label:
                                      '${day.month}月${day.day}日，$tc项任务，$mc场会议',
                                  selected: active,
                                  child: InkWell(
                                    key: ValueKey(
                                      'timeline-day-${day.year}-${day.month}-${day.day}',
                                    ),
                                    onTap: () => model.selectDate(day),
                                    borderRadius: BorderRadius.circular(12),
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(
                                        vertical: 8,
                                      ),
                                      decoration: BoxDecoration(
                                        color: active
                                            ? HomeStyle.tint(context)
                                            : null,
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                      child: FittedBox(
                                        fit: BoxFit.scaleDown,
                                        child: Column(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Text(
                                              isToday
                                                  ? '今天'
                                                  : [
                                                      '周一',
                                                      '周二',
                                                      '周三',
                                                      '周四',
                                                      '周五',
                                                      '周六',
                                                      '周日',
                                                    ][index],
                                              style: HomeStyle.text(
                                                10,
                                                color: isToday
                                                    ? HomeStyle.blue
                                                    : HomeStyle.secondary(
                                                        context,
                                                      ),
                                              ),
                                            ),
                                            const SizedBox(height: 8),
                                            Container(
                                              width: 10,
                                              height: 10,
                                              decoration: BoxDecoration(
                                                shape: BoxShape.circle,
                                                color: active
                                                    ? HomeStyle.blue
                                                    : HomeStyle.surface(
                                                        context,
                                                      ),
                                                border: Border.all(
                                                  color: active
                                                      ? HomeStyle.blue
                                                      : HomeStyle.muted
                                                            .withValues(
                                                              alpha: .3,
                                                            ),
                                                  width: 1.5,
                                                ),
                                              ),
                                            ),
                                            const SizedBox(height: 6),
                                            Text(
                                              '${day.day}',
                                              style: HomeStyle.text(
                                                13,
                                                bold: active,
                                              ),
                                            ),
                                            const SizedBox(height: 5),
                                            SizedBox(
                                              height: 8,
                                              child: Row(
                                                mainAxisAlignment:
                                                    MainAxisAlignment.center,
                                                children: [
                                                  if (mc > 0)
                                                    dot(HomeStyle.blue),
                                                  if (mc > 0 && tc > 0)
                                                    const SizedBox(width: 3),
                                                  if (tc > 0)
                                                    KeyedSubtree(
                                                      key: ValueKey(
                                                        'timeline-task-dot-${day.year}-${day.month}-${day.day}',
                                                      ),
                                                      child: dot(
                                                        HomeStyle.muted,
                                                      ),
                                                    ),
                                                ],
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                );
                              },
                            ),
                          ),
                      ],
                    ),
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      dot(HomeStyle.blue),
                      const SizedBox(width: 4),
                      Text(
                        '会议',
                        style: HomeStyle.text(
                          9,
                          color: HomeStyle.secondary(context),
                        ),
                      ),
                      const SizedBox(width: 12),
                      dot(HomeStyle.muted),
                      const SizedBox(width: 4),
                      Text(
                        '任务',
                        style: HomeStyle.text(
                          9,
                          color: HomeStyle.secondary(context),
                        ),
                      ),
                    ],
                  ),
                  const Divider(height: 22),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            '${date.month}月${date.day}日',
                            style: HomeStyle.text(12, bold: true),
                          ),
                        ),
                        Text(
                          '${tasks.length}项任务 · ${meetings.length}场会议',
                          style: HomeStyle.text(
                            10,
                            color: HomeStyle.secondary(context),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (tasks.isNotEmpty)
                    TaskChecklistWidget(
                      entries: tasks,
                      inline: true,
                      expanded: true,
                      savingId: model.savingId,
                      onComplete: (id) async {
                        final saved = await model.complete(id);
                        if (saved && context.mounted) {
                          await context.read<HomeViewModel?>()?.refresh();
                        }
                        return saved;
                      },
                      onDismissed: model.dismissCompleted,
                      onOpen: open,
                    ),
                  if (meetings.isNotEmpty) ...[
                    const Divider(height: 18),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Padding(
                        padding: const EdgeInsets.only(left: 8),
                        child: Text(
                          '当天会议',
                          style: HomeStyle.text(
                            10,
                            color: HomeStyle.secondary(context),
                          ),
                        ),
                      ),
                    ),
                    for (final entry in meetings) ...[
                      Material(
                        color: Colors.transparent,
                        child: ListTile(
                          key: ValueKey('timeline-meeting-${entry.item.id}'),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 8,
                          ),
                          leading: Container(
                            padding: const EdgeInsets.all(7),
                            decoration: BoxDecoration(
                              color: HomeStyle.tint(context),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: const Icon(Icons.mic_none_rounded, size: 17),
                          ),
                          title: Text(
                            entry.item.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: HomeStyle.text(13),
                          ),
                          subtitle: Text(
                            '${entry.timeLabel}${entry.item.endsAt == null ? '' : ' — ${TimeOfDay.fromDateTime(model.clock.toLocal(entry.item.endsAt!)).format(context)}'}',
                            style: HomeStyle.text(
                              11,
                              color: HomeStyle.secondary(context),
                            ),
                          ),
                          trailing: Text(
                            entry.isPast
                                ? '已过期'
                                : entry.item.reviewPending
                                ? '待确认'
                                : entry.statusLabel,
                            style: HomeStyle.text(
                              10,
                              color: entry.isPast
                                  ? HomeStyle.secondary(context)
                                  : HomeStyle.blue,
                            ),
                          ),
                        ),
                      ),
                      if (_hasPreparation(entry))
                        _PreparationSummary(entry: entry),
                    ],
                  ],
                  if (tasks.isEmpty && meetings.isEmpty)
                    Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        children: [
                          Text(
                            '当天没有任务或会议',
                            style: HomeStyle.text(
                              12,
                              color: HomeStyle.secondary(context),
                            ),
                          ),
                          if (model.pendingTaskCount > 0) ...[
                            const SizedBox(height: 8),
                            Text(
                              '还有${model.pendingTaskCount}项待办在其他日期',
                              style: HomeStyle.text(
                                11,
                                color: HomeStyle.secondary(context),
                              ),
                            ),
                            TextButton(
                              key: const ValueKey('timeline-view-all-pending'),
                              onPressed: () =>
                                  _showPendingTasks(context, model, open),
                              child: const Text('查看全部待办'),
                            ),
                          ],
                        ],
                      ),
                    ),
                ],
              ),
            ),
          if (model.error != null)
            Row(
              children: [
                Expanded(child: Text(model.error!, style: HomeStyle.text(12))),
                TextButton(onPressed: model.refresh, child: const Text('重试')),
              ],
            ),
        ],
      );
    },
  );

  Future<void> _showPendingTasks(
    BuildContext hostContext,
    ScheduleViewModel model,
    Future<void> Function(ScheduleEntry) open,
  ) async {
    final visibleIds = model.pendingTaskEntries
        .map((entry) => entry.item.id)
        .toSet();
    await showModalBottomSheet<void>(
      context: hostContext,
      useRootNavigator: true,
      useSafeArea: true,
      isScrollControlled: true,
      backgroundColor: HomeStyle.canvas(hostContext),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (sheetContext) => ChangeNotifierProvider.value(
        value: model,
        child: DraggableScrollableSheet(
          expand: false,
          initialChildSize: .72,
          minChildSize: .4,
          maxChildSize: .92,
          builder: (_, controller) => Consumer<ScheduleViewModel>(
            builder: (context, current, _) {
              final groups = <DateTime?, List<ScheduleEntry>>{};
              for (final entry in current.allTaskEntries.where(
                (entry) => visibleIds.contains(entry.item.id),
              )) {
                groups
                    .putIfAbsent(current.calendarDateFor(entry.item), () => [])
                    .add(entry);
              }
              return ListView(
                key: const ValueKey('timeline-pending-overview'),
                controller: controller,
                padding: const EdgeInsets.fromLTRB(20, 10, 20, 24),
                children: [
                  Center(
                    child: Container(
                      width: 36,
                      height: 4,
                      decoration: BoxDecoration(
                        color: HomeStyle.muted.withValues(alpha: .3),
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '待完成任务',
                          style: HomeStyle.text(18, bold: true),
                        ),
                      ),
                      IconButton(
                        tooltip: '关闭',
                        onPressed: () => Navigator.pop(sheetContext),
                        icon: const Icon(Icons.close_rounded, size: 20),
                      ),
                    ],
                  ),
                  Text(
                    '全部日期 · ${current.pendingTaskCount}项待完成',
                    style: HomeStyle.text(
                      11,
                      color: HomeStyle.secondary(context),
                    ),
                  ),
                  const SizedBox(height: 16),
                  if (groups.isEmpty)
                    Text(
                      '暂无待办任务',
                      style: HomeStyle.text(
                        13,
                        color: HomeStyle.secondary(context),
                      ),
                    ),
                  for (final group in groups.entries) ...[
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            group.key == null
                                ? '日期待明确'
                                : '${group.key!.year}年${group.key!.month}月${group.key!.day}日',
                            style: HomeStyle.text(12, bold: true),
                          ),
                        ),
                        if (group.key != null)
                          TextButton(
                            key: ValueKey(
                              'timeline-locate-${group.key!.year}-${group.key!.month}-${group.key!.day}',
                            ),
                            onPressed: () {
                              current.selectDate(group.key!);
                              Navigator.pop(sheetContext);
                            },
                            child: const Text('在日历中查看'),
                          ),
                      ],
                    ),
                    Container(
                      decoration: HomeStyle.card(context: context),
                      child: TaskChecklistWidget(
                        entries: group.value,
                        inline: true,
                        expanded: true,
                        savingId: current.savingId,
                        onComplete: (id) async {
                          final saved = await current.complete(id);
                          if (saved && hostContext.mounted) {
                            await hostContext.read<HomeViewModel?>()?.refresh();
                          }
                          return saved;
                        },
                        onDismissed: current.dismissCompleted,
                        onOpen: (entry) async {
                          Navigator.pop(sheetContext);
                          await open(entry);
                        },
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],
                  if (current.error != null)
                    Text(
                      current.error!,
                      style: HomeStyle.text(
                        12,
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  bool _hasPreparation(ScheduleEntry entry) =>
      entry.status == ScheduleStatus.upcoming &&
      entry.item.authority == 'authenticated_device_receipt_fields_matched' &&
      (entry.item.preparationStatus != null ||
          entry.item.preparationSummary != null ||
          entry.item.preparationRoute != null);

  Future<void> _showDetail(BuildContext context, ScheduleEntry entry) =>
      showModalBottomSheet<void>(
        context: context,
        useSafeArea: true,
        useRootNavigator: true,
        isScrollControlled: true,
        builder: (sheetContext) => SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(entry.item.title, style: HomeStyle.text(22, bold: true)),
              const SizedBox(height: 12),
              Text(
                taskDeadlineLabel(entry),
                style: HomeStyle.text(14, color: HomeStyle.secondary(context)),
              ),
              const SizedBox(height: 12),
              Text(
                entry.item.sourceLabel,
                style: HomeStyle.text(12, color: HomeStyle.secondary(context)),
              ),
              if (entry.item.notes.isNotEmpty) ...[
                const SizedBox(height: 16),
                SelectableText(entry.item.notes, style: HomeStyle.text(14)),
              ],
              if (entry.item.sourceRoute != null) ...[
                const SizedBox(height: 16),
                TextButton.icon(
                  onPressed: () {
                    Navigator.pop(sheetContext);
                    context.push(entry.item.sourceRoute!);
                  },
                  icon: const Icon(Icons.open_in_new, size: 16),
                  label: const Text('查看来源'),
                ),
              ],
            ],
          ),
        ),
      );
}

class _PreparationSummary extends StatelessWidget {
  const _PreparationSummary({required this.entry});
  final ScheduleEntry entry;

  String? get statusLabel => switch (entry.item.preparationStatus) {
    'queued' => '会前准备已排队',
    'running' => '会前准备分析中',
    'retryable' => '会前准备等待重试',
    'succeeded' => '会前准备已生成',
    'failed' => '会前准备生成失败',
    'skipped' => '本次未生成会前准备',
    'expired' => '会前准备已失效',
    'stale' => '会前准备依据已变化',
    'cancelled' => '会前准备已取消',
    _ => null,
  };

  @override
  Widget build(BuildContext context) {
    final summary = entry.item.preparationStatus == 'succeeded'
        ? entry.item.preparationSummary
        : null;
    final route = validatedPreparationRoute(
      entry.item.preparationRoute,
      preparationId: entry.item.preparationId,
    );
    return Container(
      key: ValueKey('timeline-preparation-${entry.item.id}'),
      margin: const EdgeInsets.fromLTRB(8, 0, 8, 8),
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 8),
      decoration: BoxDecoration(
        color: HomeStyle.tint(context),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            Icons.auto_awesome_outlined,
            size: 16,
            color: HomeStyle.blue,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (statusLabel != null)
                  Text(
                    statusLabel!,
                    style: HomeStyle.text(
                      11,
                      bold: true,
                      color: HomeStyle.blue,
                    ),
                  ),
                if (summary != null) ...[
                  const SizedBox(height: 3),
                  Text(
                    summary,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: HomeStyle.text(
                      11,
                      color: HomeStyle.secondary(context),
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (route != null)
            TextButton(
              key: ValueKey('open-preparation-${entry.item.id}'),
              onPressed: () => context.push(route),
              child: const Text('查看会前准备'),
            ),
        ],
      ),
    );
  }
}

class _TimelineWeeks extends StatefulWidget {
  const _TimelineWeeks({
    required this.today,
    required this.selected,
    required this.onSelect,
    required this.builder,
  });
  final DateTime today, selected;
  final ValueChanged<DateTime> onSelect;
  final Widget Function(DateTime) builder;
  @override
  State<_TimelineWeeks> createState() => _TimelineWeeksState();
}

class _TimelineWeeksState extends State<_TimelineWeeks> {
  late final PageController _controller;
  late final DateTime _anchor;
  static const center = 1000;
  @override
  void initState() {
    super.initState();
    _anchor = DateTime(
      widget.today.year,
      widget.today.month,
      widget.today.day - (widget.today.weekday - 1),
    );
    final initial = DateTime(
      widget.selected.year,
      widget.selected.month,
      widget.selected.day - (widget.selected.weekday - 1),
    );
    final weeks =
        DateTime.utc(initial.year, initial.month, initial.day)
            .difference(DateTime.utc(_anchor.year, _anchor.month, _anchor.day))
            .inDays ~/
        7;
    // The home scroll view has its own PageStorageKey. A PageView without a
    // dedicated storage identity can restore that vertical pixel offset as a
    // week index (e.g. 966 instead of 1000), unexpectedly jumping months back.
    // selectedDate is the sole source of truth, including after a refresh.
    _controller = PageController(initialPage: center + weeks, keepPage: false);
  }

  @override
  void didUpdateWidget(covariant _TimelineWeeks oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selected == widget.selected) return;
    final selectedMonday = DateTime.utc(
      widget.selected.year,
      widget.selected.month,
      widget.selected.day - widget.selected.weekday + 1,
    );
    final target =
        center +
        selectedMonday
                .difference(
                  DateTime.utc(_anchor.year, _anchor.month, _anchor.day),
                )
                .inDays ~/
            7;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          !_controller.hasClients ||
          _controller.position.isScrollingNotifier.value) {
        return;
      }
      if ((_controller.page ?? _controller.initialPage.toDouble()).round() !=
          target) {
        _controller.jumpToPage(target);
      }
    });
  }

  DateTime week(int page) =>
      DateTime(_anchor.year, _anchor.month, _anchor.day + (page - center) * 7);
  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    height:
        88 + (MediaQuery.textScalerOf(context).scale(13) - 13).clamp(0, 50) * 2,
    child: PageView.builder(
      key: const ValueKey('timeline-weeks'),
      controller: _controller,
      itemCount: 2001,
      onPageChanged: (page) {
        final start = week(page);
        widget.onSelect(
          DateTime(
            start.year,
            start.month,
            start.day + widget.selected.weekday - 1,
          ),
        );
      },
      itemBuilder: (_, page) => widget.builder(week(page)),
    ),
  );
}
