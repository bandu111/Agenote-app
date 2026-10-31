import 'package:flutter/material.dart';
import '../../home/views/home_style.dart';

class MeetingProcessingView extends StatelessWidget {
  const MeetingProcessingView({
    super.key,
    required this.loading,
    required this.title,
    required this.transcripts,
    required this.actions,
    required this.onOpen,
    required this.onHome,
    required this.onRetry,
    this.error,
    this.progress,
  });
  final bool loading;
  final Map<String, dynamic>? progress;
  final String title;
  final int transcripts, actions;
  final String? error;
  final VoidCallback onOpen, onHome, onRetry;

  @override
  Widget build(BuildContext context) {
    final failed = !loading && error != null;
    final done = !loading && !failed;
    final percent = loading
        ? ((progress?['percent'] as num?)?.toInt() ?? 0).clamp(0, 99)
        : done
        ? 100
        : ((progress?['percent'] as num?)?.toInt() ?? 0).clamp(0, 99);
    final muted = HomeStyle.secondary(context);
    final line = HomeStyle.tintColor(context, const Color(0xFFDFE7F7));
    final surface = HomeStyle.surface(context);
    final reduced = MediaQuery.disableAnimationsOf(context);
    final duration = reduced
        ? Duration.zero
        : const Duration(milliseconds: 280);
    Widget text(String value, double size, {Color? color, bool bold = false}) =>
        Text(
          value,
          style: HomeStyle.text(
            size,
            bold: bold,
            color: color ?? HomeStyle.foreground(context),
          ),
        );
    Widget card(
      Widget child, {
      bool success = false,
      double radius = 20,
      EdgeInsets padding = const EdgeInsets.all(16),
    }) => Container(
      width: double.infinity,
      padding: padding,
      decoration: BoxDecoration(
        color: success
            ? HomeStyle.tintColor(context, const Color(0xFFF2F7FF))
            : surface,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(
          color: success ? HomeStyle.blue.withValues(alpha: .2) : line,
        ),
      ),
      child: child,
    );
    final stage = percent < 10
        ? 0
        : percent < 65
        ? 1
        : 2;
    Widget step(int index, IconData icon, String label, String description) {
      final complete = index < stage;
      final running = index == stage;
      final color = running || complete
          ? HomeStyle.blue
          : muted.withValues(alpha: .55);
      return IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              width: 26,
              child: Column(
                children: [
                  Container(
                    width: 26,
                    height: 26,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: complete
                          ? HomeStyle.blue
                          : HomeStyle.tint(context),
                      border: Border.all(
                        color: running
                            ? HomeStyle.blue.withValues(alpha: .45)
                            : line,
                      ),
                    ),
                    child: complete
                        ? const Icon(Icons.done, size: 14, color: Colors.white)
                        : running
                        ? const _ActiveBadge()
                        : Icon(Icons.circle, size: 5, color: color),
                  ),
                  if (index < 2)
                    Expanded(
                      child: Center(child: Container(width: 1, color: line)),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(bottom: 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(icon, size: 14, color: color),
                        const SizedBox(width: 6),
                        Expanded(
                          child: text(
                            label,
                            12.5,
                            color: running || complete ? null : muted,
                            bold: true,
                          ),
                        ),
                        text(
                          complete
                              ? '完成'
                              : running
                              ? '生成中'
                              : '等待',
                          9.5,
                          color: color,
                        ),
                      ],
                    ),
                    const SizedBox(height: 5),
                    text(
                      description,
                      10.5,
                      color: muted.withValues(
                        alpha: running || complete ? 1 : .7,
                      ),
                    ),
                    if (running) ...[
                      const SizedBox(height: 8),
                      const _ProcessingSweep(),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    }

    final result = failed
        ? card(
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.error_outline,
                      size: 24,
                      color: Theme.of(context).colorScheme.error,
                    ),
                    const SizedBox(width: 10),
                    Expanded(child: text('失败原因', 13, bold: true)),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  error!,
                  key: const ValueKey('minutes-generation-error'),
                  style: HomeStyle.text(12, color: muted),
                ),
              ],
            ),
          )
        : done
        ? card(
            Column(
              children: [
                Row(
                  children: [
                    Container(
                      width: 34,
                      height: 34,
                      decoration: const BoxDecoration(
                        shape: BoxShape.circle,
                        color: HomeStyle.blue,
                      ),
                      child: const Icon(
                        Icons.done_all,
                        size: 18,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          text('转写、纪要、后续行动都已生成', 12.5, bold: true),
                          const SizedBox(height: 3),
                          text('原始记录仍在，纪要里每条结论都能回到原话', 9.5, color: muted),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    for (final entry in [
                      ('$transcripts', '段转写'),
                      ('1', '份纪要'),
                      ('$actions', '项后续行动'),
                    ]) ...[
                      if (entry.$2 != '段转写') const SizedBox(width: 8),
                      Expanded(
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 10,
                          ),
                          decoration: BoxDecoration(
                            color: surface,
                            border: Border.all(color: line),
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: Column(
                            children: [
                              text(entry.$1, 17),
                              const SizedBox(height: 4),
                              text(entry.$2, 9, color: muted),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
            success: true,
          )
        : card(
            Column(
              children: [
                step(
                  0,
                  Icons.description_outlined,
                  '转写',
                  percent >= 10
                      ? '$transcripts 段原话 · 已核对转写版本'
                      : '正在核对带时间点的文字，并保留原声切片',
                ),
                step(
                  1,
                  Icons.edit_note,
                  '纪要',
                  percent >= 65 ? '摘要、核心决策与会议依据已生成' : '生成摘要、核心决策与会议依据',
                ),
                step(
                  2,
                  Icons.checklist,
                  '后续行动',
                  percent >= 65 ? '正在同步行动项与任务清单' : '把承诺、行动和待确认拆成清单',
                ),
              ],
            ),
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          );
    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: HomeStyle.tintColor(context, const Color(0xFFF1F7FF)),
            border: Border.all(color: HomeStyle.blue.withValues(alpha: .2)),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.circle,
                size: 5,
                color: failed
                    ? Theme.of(context).colorScheme.error
                    : HomeStyle.blue,
              ),
              const SizedBox(width: 5),
              text(
                failed
                    ? '会议已结束 · 整理失败'
                    : done
                    ? '会议已归档'
                    : '会议已结束 · 整理中',
                9.5,
                color: HomeStyle.blue,
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        text(
          failed
              ? '生成会议纪要失败'
              : done
              ? '这场会议整理好了'
              : '正在把这场会议整理清楚',
          23,
          bold: true,
        ),
        const SizedBox(height: 6),
        text(title, 11.5, color: muted),
        const SizedBox(height: 16),
        card(
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        text('整体进度', 10, color: muted),
                        const SizedBox(height: 4),
                        text(
                          failed
                              ? '整理中断，可重试'
                              : done
                              ? '三份结果都已经生成'
                              : progress?['label'] as String? ?? '正在核对录音与转写',
                          11,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  TweenAnimationBuilder<double>(
                    tween: Tween(end: percent.toDouble()),
                    duration: duration,
                    builder: (_, value, _) => Text.rich(
                      TextSpan(
                        text: '${value.round()}',
                        style: HomeStyle.text(
                          30,
                        ).copyWith(height: 1, fontWeight: FontWeight.w400),
                        children: [
                          TextSpan(
                            text: '%',
                            style: HomeStyle.text(13, color: muted),
                          ),
                        ],
                      ),
                      semanticsLabel: '$percent%',
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TweenAnimationBuilder<double>(
                tween: Tween(end: percent / 100),
                duration: duration,
                builder: (_, value, _) => LinearProgressIndicator(
                  value: value,
                  minHeight: 5,
                  borderRadius: BorderRadius.circular(4),
                  color: HomeStyle.blue,
                  backgroundColor: line,
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Icon(Icons.schedule, size: 11, color: muted),
                  const SizedBox(width: 4),
                  Expanded(
                    child: text(
                      done
                          ? '整理完成'
                          : failed
                          ? '等待重试'
                          : '正在整理',
                      9.5,
                      color: muted,
                    ),
                  ),
                  text('原始录音与转写已保存', 9.5, color: muted.withValues(alpha: .7)),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        AnimatedSize(
          duration: duration,
          alignment: Alignment.topCenter,
          child: AnimatedSwitcher(
            duration: duration,
            child: KeyedSubtree(
              key: ValueKey(
                failed
                    ? 'failed'
                    : done
                    ? 'done'
                    : 'loading',
              ),
              child: result,
            ),
          ),
        ),
        const SizedBox(height: 12),
        card(
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(
                Icons.verified_user_outlined,
                size: 13,
                color: HomeStyle.blue,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    text('录音与转写已经保存，整理期间关闭页面也不会中断', 10.5),
                    const SizedBox(height: 4),
                    text('整理结果会进入知识库，行动会进入任务清单。', 9.5, color: muted),
                  ],
                ),
              ),
            ],
          ),
          radius: 18,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        ),
      ],
    );
    return Scaffold(
      backgroundColor: HomeStyle.canvas(context),
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 560),
                    child: TweenAnimationBuilder<double>(
                      tween: Tween(begin: reduced ? 1 : 0, end: 1),
                      duration: duration,
                      child: body,
                      builder: (_, value, child) => Opacity(
                        opacity: value,
                        child: Transform.translate(
                          offset: Offset(0, (1 - value) * 8),
                          child: child,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Container(
              width: double.infinity,
              decoration: BoxDecoration(
                color: surface,
                border: Border(top: BorderSide(color: line)),
              ),
              child: SafeArea(
                top: false,
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 600),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(20, 14, 20, 14),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (done || failed) ...[
                            SizedBox(
                              width: double.infinity,
                              height: 48,
                              child: FilledButton(
                                onPressed: failed ? onRetry : onOpen,
                                style: FilledButton.styleFrom(
                                  backgroundColor: HomeStyle.blue,
                                  shape: const StadiumBorder(),
                                  textStyle: HomeStyle.text(13, bold: true),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(failed ? '重新生成' : '查看纪要'),
                                    const SizedBox(width: 6),
                                    const Icon(Icons.arrow_forward, size: 16),
                                  ],
                                ),
                              ),
                            ),
                            const SizedBox(height: 8),
                            SizedBox(
                              width: double.infinity,
                              height: 36,
                              child: TextButton(
                                onPressed: onHome,
                                child: Text(
                                  '回到首页',
                                  style: HomeStyle.text(11.5, color: muted),
                                ),
                              ),
                            ),
                          ] else ...[
                            SizedBox(
                              width: double.infinity,
                              height: 44,
                              child: OutlinedButton(
                                onPressed: onHome,
                                style: OutlinedButton.styleFrom(
                                  side: BorderSide(color: line),
                                  shape: const StadiumBorder(),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    text('先去忙别的', 12),
                                    const SizedBox(width: 4),
                                    Icon(
                                      Icons.north_east,
                                      size: 13,
                                      color: muted,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            const SizedBox(height: 8),
                            text(
                              '关闭这一页不会取消整理，进度会自己走完',
                              9.5,
                              color: muted.withValues(alpha: .7),
                            ),
                          ],
                        ],
                      ),
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

class _ActiveBadge extends StatelessWidget {
  const _ActiveBadge();
  @override
  Widget build(BuildContext context) => Stack(
    alignment: Alignment.center,
    children: [
      if (!MediaQuery.disableAnimationsOf(context))
        const Padding(
          padding: EdgeInsets.all(3),
          child: CircularProgressIndicator(
            strokeWidth: 1.2,
            color: HomeStyle.blue,
          ),
        ),
      const Icon(Icons.circle, size: 5, color: HomeStyle.blue),
    ],
  );
}

class _ProcessingSweep extends StatefulWidget {
  const _ProcessingSweep();
  @override
  State<_ProcessingSweep> createState() => _ProcessingSweepState();
}

class _ProcessingSweepState extends State<_ProcessingSweep>
    with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  );
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context) ||
        !TickerMode.valuesOf(context).enabled) {
      _controller.stop();
    } else {
      _controller.repeat();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(3),
    child: SizedBox(
      height: 3,
      child: ColoredBox(
        color: HomeStyle.tint(context),
        child: LayoutBuilder(
          builder: (_, box) => AnimatedBuilder(
            animation: _controller,
            builder: (_, _) => Transform.translate(
              offset: Offset(
                (_controller.value * 1.33 - .33) * box.maxWidth,
                0,
              ),
              child: Align(
                alignment: Alignment.centerLeft,
                child: SizedBox(
                  width: box.maxWidth / 3,
                  child: const ColoredBox(color: Color(0xFF6196FF)),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
