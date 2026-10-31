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
import '../widgets/voice_evidence_player.dart';
import '../widgets/goal_related_sections.dart';
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
  final _viewport = GlobalKey();
  final _sections = List.generate(2, (_) => GlobalKey());
  int _selected = 0;
  bool _jumping = false;
  VoiceEvidenceController? _audio;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scroll.addListener(_onScroll);
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

  void _onScroll() {
    if (_jumping || !mounted) return;
    final viewport = _viewport.currentContext?.findRenderObject() as RenderBox?;
    if (viewport == null) return;
    final threshold = viewport.localToGlobal(Offset.zero).dy + 24;
    var current = 0;
    for (var i = 0; i < _sections.length; i++) {
      final box = _sections[i].currentContext?.findRenderObject() as RenderBox?;
      if (box != null && box.localToGlobal(Offset.zero).dy <= threshold) {
        current = i;
      }
    }
    if (current != _selected) setState(() => _selected = current);
  }

  Future<void> _jump(int index) async {
    final target = _sections[index].currentContext;
    if (target == null) return;
    setState(() {
      _selected = index;
      _jumping = true;
    });
    await Scrollable.ensureVisible(
      target,
      alignment: 0,
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : const Duration(milliseconds: 360),
      curve: Curves.easeOutCubic,
    );
    if (mounted) setState(() => _jumping = false);
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
                              style: HomeStyle.text(26, bold: true),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              '查看目标推进与双方承诺'.tr(context),
                              style: HomeStyle.text(
                                13,
                                color: HomeStyle.secondary(context),
                              ),
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
                          size: 29,
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
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
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
                            key: _viewport,
                            controller: _scroll,
                            physics: const AlwaysScrollableScrollPhysics(),
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(16, 4, 16, 40),
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
                                        _SectionHeading(
                                          key: _sections[0],
                                          icon: Icons.track_changes,
                                          title: '持续目标'.tr(context),
                                          subtitle: '重要决定不会随着会话结束而消失。',
                                          expanded: model.allGoals,
                                          onAll: model.toggleGoals,
                                        ),
                                        if (model.visibleGoals.isEmpty)
                                          const ProgressEmpty('还没有持续目标')
                                        else
                                          ...model.visibleGoals.map(
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
                                        const SizedBox(height: 8),
                                        _SectionHeading(
                                          key: _sections[1],
                                          icon: Icons.handshake_outlined,
                                          title: '双方承诺'.tr(context),
                                          subtitle: '基于会议内容生成，保留语音证据并持续跟进履行情况。',
                                          expanded: model.allCommitments,
                                          onAll: model.toggleCommitments,
                                        ),
                                        ProgressPills(
                                          labels: CommitmentSide.values
                                              .map((s) => s.label.tr(context))
                                              .toList(),
                                          keyPrefix: 'commitment-side',
                                          solid: false,
                                          counts: CommitmentSide.values
                                              .map(model.followUpCount)
                                              .toList(),
                                          selected: model.side.index,
                                          onSelected: (i) {
                                            unawaited(_audio?.suspend());
                                            model.selectSide(
                                              CommitmentSide.values[i],
                                            );
                                          },
                                        ),
                                        const SizedBox(height: 10),
                                        if (model.visibleCommitments.isEmpty)
                                          const ProgressEmpty('这一方还没有承诺记录')
                                        else
                                          ...model.visibleCommitments.map(
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

class _SectionHeading extends StatelessWidget {
  const _SectionHeading({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onAll,
    this.expanded = false,
  });
  final IconData icon;
  final String title, subtitle;
  final VoidCallback onAll;
  final bool expanded;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 6, bottom: 10),
    child: SizedBox(
      width: double.infinity,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 40),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(right: 78),
                  child: Text(title, style: HomeStyle.text(18, bold: true)),
                ),
                const SizedBox(height: 3),
                Text(
                  subtitle,
                  style: HomeStyle.text(
                    12,
                    color: HomeStyle.secondary(context),
                  ),
                ),
              ],
            ),
          ),
          Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: HomeStyle.tintColor(context, const Color(0xFFEAE8FF)),
            ),
            child: Icon(icon, color: const Color(0xFF6A5AF9), size: 22),
          ),
          Positioned(
            right: 0,
            top: -10,
            child: TextButton(
              onPressed: onAll,
              style: TextButton.styleFrom(
                minimumSize: const Size(48, 48),
                padding: const EdgeInsets.symmetric(horizontal: 4),
              ),
              child: Text(
                expanded ? '收起 ‹' : '查看全部 ›',
                style: HomeStyle.text(12, color: HomeStyle.blue),
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
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: InkWell(
                key: ValueKey('goal-${goal.id}'),
                onTap: onOpen,
                child: Text(goal.title,
                  softWrap: true,
                  style: HomeStyle.text(17, bold: true).copyWith(height: 1.5)),
              ),
            ),
            const SizedBox(width: 10),
            ProgressTag(
              goal.statusLabelAt(DateTime.now()) == '已过期'
                  ? '已过期'.tr(context)
                  : goal.status == GoalStatus.active ? '进度受控' : goal.statusLabelAt(DateTime.now()).tr(context),
              color: goal.statusLabelAt(DateTime.now()) != '已过期' && goal.status == GoalStatus.active ? HomeStyle.teal : HomeStyle.secondary(context),
              icon: Icons.circle,
              fontSize: goal.statusLabelAt(DateTime.now()) == '已过期' ? 14 : 12,
            ),
          ],
        ),
        if (goal.statusLabelAt(DateTime.now()) != '已过期') ...[
        const SizedBox(height: 5),
        Align(
          alignment: Alignment.centerRight,
          child: Text(goal.deadlineLabel(DateTime.now()).tr(context),
            style: HomeStyle.text(11, color: HomeStyle.secondary(context))),
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
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(item.side.itemLabel, style: HomeStyle.text(12)),
            ProgressTag(
              '${item.statusAt(DateTime.now()).label.tr(context)}${item.progress > 0 ? ' · ${(item.progress * 100).round()}%' : ''}',
            ),
          ],
        ),
        const SizedBox(height: 7),
        InkWell(
          key: ValueKey('commitment-${item.id}'),
          onTap: onOpen,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Text(item.title, style: HomeStyle.text(16, bold: true)),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          item.summary,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: HomeStyle.text(13, color: HomeStyle.secondary(context)),
        ),
        const SizedBox(height: 8),
        if (item.evidence.isDocument)
          DocumentEvidenceReference(evidence: item.evidence)
        else
          VoiceEvidencePlayer(evidence: item.evidence, onDetails: onOpen),
        const SizedBox(height: 8),
        LayoutBuilder(
          builder: (context, constraints) {
            final cells = [
              ProgressField(
                '承诺交付节点',
                '${item.deadline.month} 月 ${item.deadline.day} 日',
                icon: Icons.schedule,
                compact: MediaQuery.textScalerOf(context).scale(14) <= 20,
              ),
              ProgressField(
                '成果物拟定路径',
                item.attachment ?? '尚未关联附件',
                icon: Icons.description_outlined,
                compact: MediaQuery.textScalerOf(context).scale(14) <= 20,
              ),
            ];
            if (constraints.maxWidth < 280 ||
                MediaQuery.textScalerOf(context).scale(14) > 20) {
              return Column(
                children: [cells[0], const SizedBox(height: 6), cells[1]],
              );
            }
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: cells[0]),
                const SizedBox(width: 6),
                Expanded(child: cells[1]),
              ],
            );
          },
        ),
      ],
    ),
  );
}
