import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../../../shared/widgets/content_skeleton.dart';
import '../viewmodels/home_view_model.dart';
import 'home_style.dart';

class WeeklyRhythmCard extends StatefulWidget {
  const WeeklyRhythmCard({super.key});
  @override
  State<WeeklyRhythmCard> createState() => _WeeklyRhythmCardState();
}

class _WeeklyRhythmCardState extends State<WeeklyRhythmCard> {
  String? _selected;
  String? _owner;
  @override
  Widget build(BuildContext context) {
    final home = context.watch<HomeViewModel>();
    final owner = home.repository?.accountId;
    if (_owner != owner) {
      _owner = owner;
      _selected = null;
    }
    final raw = home.data['weeklyRhythm'];
    final data = raw is Map ? raw : const {};
    final days = [
      for (final item in data['days'] as List? ?? [])
        if (item is Map) Map<String, dynamic>.from(item),
    ];
    int count(Map item, String key) => (item[key] as num?)?.toInt() ?? 0;
    final selected = days.where((d) => d['date'] == _selected).firstOrNull;
    final peak = days.fold<int>(
      1,
      (n, d) => math.max(n, count(d, 'meetings') + count(d, 'decisions')),
    );
    final colors = Theme.of(context).colorScheme;
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 260);
    Widget legend(String label, Color color) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 5,
          height: 5,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 4),
        Text(
          label,
          style: HomeStyle.text(10, color: HomeStyle.secondary(context)),
        ),
      ],
    );
    Widget stat(String label, int value) => Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('$value', style: HomeStyle.text(17)),
        const SizedBox(height: 4),
        Text(
          label,
          style: HomeStyle.text(10, color: HomeStyle.secondary(context)),
        ),
      ],
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                '本周节奏',
                style: HomeStyle.text(12, color: HomeStyle.secondary(context)),
              ),
            ),
            TextButton(
              key: const ValueKey('weekly-goal-progress'),
              onPressed: () => context.go(
                '/affairs?section=goals&focus=${DateTime.now().microsecondsSinceEpoch}',
              ),
              style: TextButton.styleFrom(
                minimumSize: const Size(0, 28),
                padding: const EdgeInsets.symmetric(horizontal: 8),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: const Text('目标进展', style: TextStyle(fontSize: 11)),
            ),
          ],
        ),
        const SizedBox(height: 10),
        if (home.loading && raw == null)
          const ContentSkeleton(rows: 2, scrollable: false, label: '正在加载本周节奏')
        else
          Container(
            key: const ValueKey('weekly-rhythm-card'),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: HomeStyle.surface(context),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: colors.outlineVariant.withValues(alpha: .3),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${selected == null ? count(data, 'meetings') : count(selected, 'meetings')}',
                            key: const ValueKey('weekly-meeting-count'),
                            style: HomeStyle.text(24),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            selected == null
                                ? '近7天会议已完成转写'
                                : '${DateTime.tryParse(selected['date'] ?? '')?.month ?? ''}月${DateTime.tryParse(selected['date'] ?? '')?.day ?? ''}日会议已完成转写',
                            style: HomeStyle.text(
                              10,
                              color: HomeStyle.secondary(context),
                            ),
                          ),
                        ],
                      ),
                    ),
                    legend('会议', HomeStyle.blue),
                    const SizedBox(width: 10),
                    legend('决策', const Color(0xFF5B619D)),
                  ],
                ),
                const SizedBox(height: 16),
                if (days.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 20),
                    child: Text(
                      home.error ?? '暂无本周统计',
                      style: HomeStyle.text(
                        12,
                        color: HomeStyle.secondary(context),
                      ),
                    ),
                  )
                else
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      for (final (index, day) in days.indexed)
                        Expanded(
                          child: Semantics(
                            button: true,
                            selected: day['date'] == _selected,
                            label:
                                '${day['date']}，${count(day, 'meetings')}场会议，${count(day, 'decisions')}项决策',
                            child: InkWell(
                              key: ValueKey('weekly-bar-${day['date']}'),
                              onTap: () => setState(
                                () => _selected = _selected == day['date']
                                    ? null
                                    : day['date'],
                              ),
                              borderRadius: BorderRadius.circular(9),
                              child: AnimatedContainer(
                                duration: duration,
                                padding: const EdgeInsets.symmetric(
                                  vertical: 5,
                                ),
                                decoration: BoxDecoration(
                                  color:
                                      day['date'] == _selected ||
                                          _selected == null &&
                                              index == days.length - 1
                                      ? HomeStyle.tint(context)
                                      : Colors.transparent,
                                  borderRadius: BorderRadius.circular(9),
                                ),
                                child: Column(
                                  children: [
                                    SizedBox(
                                      height: 58,
                                      child: Align(
                                        alignment: Alignment.bottomCenter,
                                        child: ClipRRect(
                                          borderRadius: BorderRadius.circular(
                                            5,
                                          ),
                                          child: SizedBox(
                                            width: 14,
                                            child: Column(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                if (count(day, 'meetings') +
                                                        count(
                                                          day,
                                                          'decisions',
                                                        ) ==
                                                    0)
                                                  Container(
                                                    height: 3,
                                                    color: colors.primary
                                                        .withValues(alpha: .12),
                                                  )
                                                else ...[
                                                  Container(
                                                    height:
                                                        58 *
                                                        count(
                                                          day,
                                                          'decisions',
                                                        ) /
                                                        peak,
                                                    color: const Color(
                                                      0xFF5B619D,
                                                    ),
                                                  ),
                                                  Container(
                                                    height:
                                                        58 *
                                                        count(day, 'meetings') /
                                                        peak,
                                                    color: HomeStyle.blue,
                                                  ),
                                                ],
                                              ],
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(height: 6),
                                    Text(
                                      index == days.length - 1
                                          ? '今'
                                          : [
                                              '一',
                                              '二',
                                              '三',
                                              '四',
                                              '五',
                                              '六',
                                              '日',
                                            ][(DateTime.tryParse(
                                                      day['date'] ?? '',
                                                    )?.weekday ??
                                                    1) -
                                                1],
                                      style: HomeStyle.text(
                                        10,
                                        color: index == days.length - 1
                                            ? HomeStyle.blue
                                            : HomeStyle.secondary(context),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                AnimatedSize(
                  duration: duration,
                  curve: Curves.easeOutCubic,
                  alignment: Alignment.topCenter,
                  child: selected == null
                      ? const SizedBox(width: double.infinity)
                      : AnimatedSwitcher(
                          duration: duration,
                          child: Column(
                            key: ValueKey(
                              'weekly-day-stats-${selected['date']}',
                            ),
                            children: [
                              const Divider(height: 26),
                              Semantics(
                                label: '当天会议关联目标的当前状态及当天待完成行动',
                                child:
                                    MediaQuery.textScalerOf(context).scale(10) >
                                        17
                                    ? Wrap(
                                        alignment: WrapAlignment.center,
                                        spacing: 20,
                                        runSpacing: 12,
                                        children: [
                                          stat(
                                            '进行中目标',
                                            count(selected, 'activeGoals'),
                                          ),
                                          stat(
                                            '信息待补全',
                                            count(selected, 'missingItems'),
                                          ),
                                          stat(
                                            '待完成行动',
                                            count(selected, 'pendingActions'),
                                          ),
                                        ],
                                      )
                                    : IntrinsicHeight(
                                        child: Row(
                                          children: [
                                            Expanded(
                                              child: stat(
                                                '进行中目标',
                                                count(selected, 'activeGoals'),
                                              ),
                                            ),
                                            VerticalDivider(
                                              width: 1,
                                              color: colors.outlineVariant
                                                  .withValues(alpha: .4),
                                            ),
                                            Expanded(
                                              child: stat(
                                                '信息待补全',
                                                count(selected, 'missingItems'),
                                              ),
                                            ),
                                            VerticalDivider(
                                              width: 1,
                                              color: colors.outlineVariant
                                                  .withValues(alpha: .4),
                                            ),
                                            Expanded(
                                              child: stat(
                                                '待完成行动',
                                                count(
                                                  selected,
                                                  'pendingActions',
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                              ),
                            ],
                          ),
                        ),
                ),
                if (home.error != null)
                  TextButton(
                    onPressed: home.refresh,
                    child: const Text('重新加载'),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}
