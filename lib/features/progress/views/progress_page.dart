import '../../../shared/widgets/content_skeleton.dart';
import '../../../app/l10n/app_strings.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../../home/views/home_style.dart';
import '../models/progress_models.dart';
import '../viewmodels/progress_view_model.dart';
import '../viewmodels/voice_evidence_controller.dart';
import '../widgets/progress_components.dart';
import 'progress_search.dart';
import '../../notifications/notification_views.dart';

class ProgressPage extends StatefulWidget {
  const ProgressPage({super.key, this.focusGoals = false});
  final bool focusGoals;
  @override
  State<ProgressPage> createState() => _ProgressPageState();
}

class _ProgressPageState extends State<ProgressPage>
    with WidgetsBindingObserver {
  final _scroll = ScrollController();
  final _search = TextEditingController();
  final _searchFocus = FocusNode();
  bool _searchOpen = false;
  int _selected = 0;
  VoiceEvidenceController? _audio;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _audio = context.read<VoiceEvidenceController>();
    if (!TickerMode.valuesOf(context).enabled) unawaited(_audio?.suspend());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) unawaited(_audio?.suspend());
  }

  @override
  void didUpdateWidget(covariant ProgressPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.focusGoals && !oldWidget.focusGoals) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _jump(0);
      });
    }
  }

  // 主 Tab 只展示自己的内容，避免滚动联动让目标和承诺混在一起。
  void _jump(int index) {
    unawaited(_audio?.suspend());
    setState(() => _selected = index);
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  void _open(String path) {
    unawaited(_audio?.suspend());
    context.push(path);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _scroll.dispose();
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final model = context.watch<ProgressViewModel>();
    return Scaffold(
      backgroundColor: HomeStyle.canvas(context),
      body: SafeArea(
        bottom: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 6, 12, 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '进展'.tr(context),
                              style: HomeStyle.text(22, bold: true),
                            ),
                          ],
                        ),
                      ),
                      const NotificationAction(
                        key: ValueKey('progress-notifications'),
                      ),
                      IconButton(
                        key: const ValueKey('progress-search'),
                        tooltip: _searchOpen ? '收起搜索' : '搜索进展',
                        onPressed: () {
                          unawaited(_audio?.suspend());
                          setState(() {
                            _searchOpen = !_searchOpen;
                            if (!_searchOpen) _search.clear();
                          });
                          if (_searchOpen) {
                            _searchFocus.requestFocus();
                          } else {
                            _searchFocus.unfocus();
                          }
                        },
                        icon: Icon(
                          _searchOpen ? Icons.search_off : Icons.search,
                          size: 24,
                          color: _searchOpen
                              ? HomeStyle.blue
                              : HomeStyle.secondary(context),
                        ),
                      ),
                    ],
                  ),
                ),
                if (_searchOpen)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
                    child: TextField(
                      key: const ValueKey('progress-search-input'),
                      controller: _search,
                      focusNode: _searchFocus,
                      onChanged: (_) => setState(() {}),
                      style: HomeStyle.text(14),
                      decoration: InputDecoration(
                        hintText: '会议、目标、承诺或资料关键词',
                        prefixIcon: const Icon(Icons.search, size: 20),
                        filled: true,
                        fillColor: HomeStyle.surface(context),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(28),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: ProgressPills(
                    keyPrefix: 'progress-section',
                    labels: ['目标'.tr(context), '双方承诺'.tr(context)],
                    counts: [
                      model.data.goals.length,
                      model.listedCommitments.length,
                    ],
                    selected: _selected,
                    onSelected: _jump,
                  ),
                ),
                Expanded(
                  child: _searchOpen && _search.text.trim().isNotEmpty
                      ? ProgressSearchResults(
                          model: model,
                          query: _search.text,
                          onOpen: (path) {
                            _searchFocus.unfocus();
                            _open(path);
                          },
                        )
                      : RefreshIndicator(
                          onRefresh: model.load,
                          child: SingleChildScrollView(
                            controller: _scroll,
                            physics: const AlwaysScrollableScrollPhysics(),
                            child: Padding(
                              padding: EdgeInsets.fromLTRB(
                                16,
                                _selected == 1 ? 0 : 4,
                                16,
                                40,
                              ),
                              child:
                                  model.loading &&
                                      model.data.goals.isEmpty &&
                                      model.listedCommitments.isEmpty
                                  ? const ContentSkeleton(
                                      scrollable: false,
                                      label: '正在加载进展',
                                    )
                                  : model.error != null
                                  ? Column(
                                      children: [
                                        ProgressEmpty(model.error!),
                                        ProgressAction(
                                          '重试'.tr(context),
                                          onPressed: model.load,
                                          icon: Icons.refresh,
                                        ),
                                      ],
                                    )
                                  : Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        if (model.dataWarning != null)
                                          ProgressEmpty(model.dataWarning!),
                                        if (_selected == 0) ...[
                                          if (model.data.goals.isEmpty)
                                            const ProgressEmpty('还没有持续目标')
                                          else
                                            ...model.data.goals.map(
                                              (goal) => Padding(
                                                padding: const EdgeInsets.only(
                                                  bottom: 10,
                                                ),
                                                child: _GoalCard(
                                                  goal,
                                                  model: model,
                                                  onOpen: () => _open(
                                                    '/progress/goals/${goal.id}',
                                                  ),
                                                ),
                                              ),
                                            ),
                                        ],
                                        if (_selected == 1) ...[
                                          _CommitmentSideFilter(
                                            model: model,
                                            onSelected: (side) {
                                              unawaited(_audio?.suspend());
                                              model.selectSide(side);
                                            },
                                          ),
                                          const SizedBox(height: 12),
                                          if (model.selectedCommitments.isEmpty)
                                            const ProgressEmpty('这一方还没有承诺记录')
                                          else
                                            ...model.selectedCommitments.map(
                                              (item) => Padding(
                                                padding: const EdgeInsets.only(
                                                  bottom: 10,
                                                ),
                                                child: _CommitmentCard(
                                                  item,
                                                  onOpen: () => _open(
                                                    '/progress/commitments/${item.id}',
                                                  ),
                                                ),
                                              ),
                                            ),
                                        ],
                                      ],
                                    ),
                            ),
                          ),
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 次级筛选采用紧凑分段外观，与上方主导航区分；大字体时允许标签换行。
class _CommitmentSideFilter extends StatelessWidget {
  const _CommitmentSideFilter({required this.model, required this.onSelected});
  final ProgressViewModel model;
  final ValueChanged<CommitmentSide> onSelected;

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.center,
    child: Container(
      constraints: const BoxConstraints(maxWidth: 320),
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: HomeStyle.tint(context),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final side in CommitmentSide.values)
            Flexible(
              child: Semantics(
                selected: model.side == side,
                button: true,
                child: Material(
                  color: model.side == side
                      ? HomeStyle.surface(context)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(8),
                  child: InkWell(
                    key: ValueKey('commitment-side-${side.index}'),
                    borderRadius: BorderRadius.circular(8),
                    onTap: () => onSelected(side),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                      child: Text(
                        '${side.label.tr(context)} ${model.listedCommitments.where((item) => item.side == side).length}',
                        textAlign: TextAlign.center,
                        style: HomeStyle.text(
                          12,
                          bold: model.side == side,
                          color: model.side == side
                              ? HomeStyle.blue
                              : HomeStyle.secondary(context),
                        ),
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

class _GoalCard extends StatelessWidget {
  const _GoalCard(this.goal, {required this.model, required this.onOpen});
  final ProgressGoal goal;
  final ProgressViewModel model;
  final VoidCallback onOpen;
  @override
  Widget build(BuildContext context) => ProgressCard(
    onTap: onOpen,
    // 外层已有圆角背景；内层不再裁剪标题和竖条，避免左上角缺失。
    clipBehavior: Clip.none,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 为标题留出安全边距，避免圆角裁剪首字；竖条标识每个目标。
            const SizedBox(width: 4),
            Container(
              width: 3,
              height: 18,
              margin: const EdgeInsets.only(top: 2, right: 9),
              decoration: BoxDecoration(
                color: HomeStyle.blue,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Expanded(
              child: InkWell(
                key: ValueKey('goal-${goal.id}'),
                onTap: onOpen,
                child: Text(
                  goal.title,
                  softWrap: true,
                  style: HomeStyle.text(15, bold: true).copyWith(height: 1.4),
                ),
              ),
            ),
            const SizedBox(width: 10),
            ProgressTag(
              goal.statusLabelAt(DateTime.now()) == '已过期'
                  ? '已过期'.tr(context)
                  : goal.status == GoalStatus.active
                  ? '进度受控'
                  : goal.statusLabelAt(DateTime.now()).tr(context),
              color:
                  goal.statusLabelAt(DateTime.now()) != '已过期' &&
                      goal.status == GoalStatus.active
                  ? HomeStyle.teal
                  : HomeStyle.secondary(context),
              icon: Icons.circle,
              fontSize: goal.statusLabelAt(DateTime.now()) == '已过期' ? 14 : 12,
            ),
          ],
        ),
        // 待确认且没有交期时，状态标签已经足够，不重复提示缺少交期。
        if (goal.statusLabelAt(DateTime.now()) != '已过期' &&
            !(goal.status == GoalStatus.pending && goal.deadline == null)) ...[
          const SizedBox(height: 5),
          Align(
            alignment: Alignment.centerRight,
            child: Text(
              goal.deadlineLabel(DateTime.now()).tr(context),
              style: HomeStyle.text(11, color: HomeStyle.secondary(context)),
            ),
          ),
        ],
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.all(9),
          decoration: BoxDecoration(
            color: HomeStyle.tintColor(context, const Color(0xFFF1F4FE)),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(
                    Icons.outlined_flag,
                    color: HomeStyle.blue,
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '交付完成条件',
                          style: HomeStyle.text(
                            12,
                            color: HomeStyle.secondary(context),
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(goal.condition, style: HomeStyle.text(12)),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(
                    Icons.fact_check_outlined,
                    size: 19,
                    color: HomeStyle.teal,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '验收基准：${goal.acceptance}',
                      style: HomeStyle.text(12),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(child: Text('关键交付里程碑推进', style: HomeStyle.text(12))),
            Text(
              '${(goal.progress * 100).round()}%',
              style: HomeStyle.text(12, color: HomeStyle.blue),
            ),
          ],
        ),
        const SizedBox(height: 5),
        Semantics(
          label: '里程碑完成比例',
          value: '${(goal.progress * 100).round()}%',
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: LinearProgressIndicator(
              value: goal.progress,
              minHeight: 6,
              color: HomeStyle.blue,
              backgroundColor: HomeStyle.tintColor(
                context,
                const Color(0xFFEAF0FF),
              ),
            ),
          ),
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 7,
          runSpacing: 6,
          children: [
            ProgressTag(
              '关联成果 ${model.artifactsFor(goal.id).length}',
              icon: Icons.description_outlined,
            ),
            ProgressTag(
              '关键承诺 ${model.commitmentsFor(goal.id).length}',
              icon: Icons.link,
            ),
            const ProgressTag('查看详情', icon: Icons.arrow_forward),
          ],
        ),
      ],
    ),
  );
}

class _CommitmentCard extends StatelessWidget {
  const _CommitmentCard(this.item, {required this.onOpen});
  final Commitment item;
  final VoidCallback onOpen;
  @override
  Widget build(BuildContext context) => ProgressCard(
    onTap: onOpen,
    clipBehavior: Clip.none,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 首行只呈现标题；日期和无背景状态统一放到第二行。
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(width: 4),
            Container(
              width: 3,
              height: 18,
              margin: const EdgeInsets.only(top: 2, right: 9),
              decoration: BoxDecoration(
                color: HomeStyle.blue,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Expanded(
              child: InkWell(
                key: ValueKey('commitment-${item.id}'),
                onTap: onOpen,
                child: Text(item.title, style: HomeStyle.text(15, bold: true)),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        // 列表只提供原声入口，点击进入当前承诺详情，不在列表直接播放。
        Row(
          children: [
            Expanded(
              child: Text(
                '${item.deadline.month}月${item.deadline.day}日 ｜ ${item.statusAt(DateTime.now()).label.tr(context)}',
                style: HomeStyle.text(12, color: HomeStyle.secondary(context)),
              ),
            ),
            const SizedBox(width: 8),
            TextButton(
              key: ValueKey('commitment-source-${item.id}'),
              onPressed: onOpen,
              style: TextButton.styleFrom(
                foregroundColor: HomeStyle.blue,
                // 去除默认按钮高度带来的上下空白，保持两行卡片紧凑。
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    item.evidence.isDocument
                        ? Icons.description_outlined
                        : Icons.play_circle_outline,
                    size: 20,
                  ),
                  const SizedBox(width: 5),
                  Text(
                    item.evidence.isDocument ? '依据' : '原声',
                    style: HomeStyle.text(13, color: HomeStyle.blue),
                  ),
                  const SizedBox(width: 2),
                  const Icon(Icons.chevron_right, size: 18),
                ],
              ),
            ),
          ],
        ),
      ],
    ),
  );
}
