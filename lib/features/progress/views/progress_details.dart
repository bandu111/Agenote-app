import '../../meeting/meeting_view_model.dart';
import '../../../shared/widgets/confirmation_dialog.dart';
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
import '../widgets/goal_topology.dart';
import '../widgets/goal_related_sections.dart';
import '../widgets/voice_evidence_player.dart';
import '../widgets/goal_removal_sheet.dart';
import '../../home/viewmodels/home_view_model.dart';

class ProgressDetailPage extends StatefulWidget {
  const ProgressDetailPage({super.key, required this.kind, required this.id});
  final String kind, id;
  @override
  State<ProgressDetailPage> createState() => _ProgressDetailPageState();
}

class _ProgressDetailPageState extends State<ProgressDetailPage>
    with WidgetsBindingObserver {
  VoiceEvidenceController? _audio;
  CommitmentStatus? _submittingStatus;
  Timer? _noticeTimer;
  int? _noticeScope;
  String? _successNotice;
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
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _noticeTimer?.cancel();
    unawaited(_audio?.suspend());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final model = context.watch<ProgressViewModel>();
    final title = switch (widget.kind) {
      'goals' => '目标详情',
      'commitments' => '承诺详情',
      _ => '承诺详情',
    };
    final content = switch (widget.kind) {
      'goals' => _goal(context, model),
      'commitments' => _commitment(context, model),
      _ => _commitment(context, model),
    };
    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        // 提示占用导航栏下方的独立空间，不遮挡正文；账户切换后不显示上一账户的结果。
        bottom:
            _successNotice != null && _noticeScope == model.accountScopeRevision
            ? PreferredSize(
                preferredSize: Size.fromHeight(
                  MediaQuery.textScalerOf(context).scale(12) * 1.45 + 16,
                ),
                child: Semantics(
                  liveRegion: true,
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    color: HomeStyle.tint(context),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.check_circle_outline,
                          size: 16,
                          color: HomeStyle.blue,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _successNotice!,
                            key: const ValueKey('commitment-confirm-notice'),
                            style: HomeStyle.text(12, color: HomeStyle.blue),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              )
            : null,
        actions: [
          if (widget.kind != 'goals' && model.commitment(widget.id) != null)
            Padding(
              padding: const EdgeInsets.only(right: 16),
              child: Center(
                child: ProgressTag(
                  model
                      .commitment(widget.id)!
                      .statusAt(DateTime.now())
                      .label
                      .tr(context),
                ),
              ),
            ),
        ],
        leading: BackButton(
          onPressed: () {
            if (context.canPop()) {
              context.pop();
            } else {
              context.go('/affairs');
            }
          },
        ),
      ),
      body: SafeArea(
        top: false,
        child:
            model.loading &&
                (widget.kind == 'goals'
                    ? model.goal(widget.id) == null
                    : model.commitment(widget.id) == null)
            ? const ContentSkeleton(
                layout: SkeletonLayout.detail,
                label: '正在加载进展详情',
              )
            : model.error != null
            ? Column(
                children: [
                  ProgressEmpty(model.error!),
                  ProgressAction('重试'.tr(context), onPressed: model.load),
                ],
              )
            : SingleChildScrollView(
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 640),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                      child: content,
                    ),
                  ),
                ),
              ),
      ),
    );
  }

  Future<void> _confirmCommitment(ProgressViewModel model, Commitment item) =>
      _changeCommitment(model, item, CommitmentStatus.planned);

  Future<void> _changeCommitment(
    ProgressViewModel model,
    Commitment item,
    CommitmentStatus target,
  ) async {
    if (model.saving || model.loading) return;
    final removing = target == CommitmentStatus.withdrawn;
    final completing = target == CommitmentStatus.claimed;
    final scope = model.accountScopeRevision;
    // 确认与完成均直接提交，完成仅声明 claimed；只有撤回需要二次确认。
    if (removing) {
      final confirmed = await showAppConfirmation(
        context,
        title: '移除这条承诺？',
        message: '${item.title}\n\n移除后将标记为“已撤回”，退出当前承诺列表。原始会议记录保留，当前不支持恢复。',
        action: '移除并撤回',
        icon: Icons.remove_circle_outline,
        actionColor: const Color(0xFFD82532),
        actionKey: const ValueKey('remove-commitment-submit'),
      );
      if (!mounted ||
          confirmed != true ||
          scope != model.accountScopeRevision) {
        return;
      }
    }
    // 确认、完成和撤回共用账户、内容及版本校验，不以本地动画替代服务端持久化。
    if (!identical(model.commitment(item.id), item)) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('承诺内容已更新，请重新核对后确认')));
      return;
    }
    setState(() => _submittingStatus = target);
    final success = await model.updateCommitment(
      item.id,
      target,
      removing
          ? '用户在承诺详情移除承诺，标记为已撤回'
          : completing
          ? '用户声明承诺已完成，待核实'
          : '用户核对履约方与交期后确认承诺成立',
    );
    if (!mounted) return;
    setState(() => _submittingStatus = null);
    if (scope != model.accountScopeRevision) return;
    if (success && !removing) {
      // 状态由服务端刷新结果驱动，成功提示两秒自动消失；退出页面时取消计时器。
      _noticeTimer?.cancel();
      setState(() {
        _successNotice = completing ? '已标记为声称完成' : '承诺已确认';
        _noticeScope = scope;
      });
      _noticeTimer = Timer(const Duration(seconds: 2), () {
        if (mounted) setState(() => _successNotice = null);
      });
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    if (success && removing) {
      if (context.canPop()) {
        context.pop();
      } else {
        context.go('/affairs');
      }
    }
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          success ? '承诺已移除，状态为已撤回' : model.actionError ?? '操作失败，请刷新后重试',
        ),
      ),
    );
  }

  Widget _goal(BuildContext context, ProgressViewModel model) {
    final goal = model.goal(widget.id);
    if (goal == null) return const ProgressEmpty('目标不存在或暂不可用');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ProgressCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ProgressTag(goal.statusLabelAt(DateTime.now()).tr(context)),
              const SizedBox(height: 10),
              Text(goal.title, style: HomeStyle.text(22, bold: true)),
            ],
          ),
        ),
        const SizedBox(height: 16),
        GoalTopology(key: ValueKey('goal-topology-${goal.id}'), goal: goal),
        const SizedBox(height: 20),
        GoalCommitmentsSection(items: model.commitmentsFor(goal.id)),
        const SizedBox(height: 22),
        if (model.data.demo)
          GoalKnowledgeSection(goal: goal)
        else
          BoundKnowledgeSection(
            references: goal.knowledgeReferences,
            relationLabel: '目标关联 · ${goal.title}',
            relationQuery: '${goal.title} ${goal.condition} ${goal.acceptance}',
          ),
        _demoNote(context),
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton(
            key: const ValueKey('remove-goal'),
            onPressed:
                model.loading || model.saving || !model.supportsGoalRemoval
                ? null
                : () => _removeGoal(model, goal),
            style: OutlinedButton.styleFrom(
              foregroundColor: const Color(0xFFD82532),
              backgroundColor: const Color(0xFFD82532).withValues(alpha: .035),
              side: BorderSide(
                color: const Color(0xFFD82532).withValues(alpha: .26),
              ),
              minimumSize: const Size.fromHeight(44),
              shape: const StadiumBorder(),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.remove_rounded, size: 15),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    model.saving ? '正在移除…' : '移除这个目标',
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _removeGoal(ProgressViewModel model, ProgressGoal goal) async {
    if (model.loading || model.saving) return;
    final scope = model.accountScopeRevision;
    final confirmed = await showGoalRemovalSheet(context, goal.title);
    if (!mounted || !confirmed || scope != model.accountScopeRevision) return;
    final saved = await model.removeGoal(goal);
    if (!mounted || scope != model.accountScopeRevision) return;
    if (!saved) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(model.actionError ?? '移除失败，请稍后重试')),
      );
      return;
    }
    unawaited(context.read<HomeViewModel?>()?.refresh());
    if (context.canPop()) {
      context.pop();
    } else {
      context.go('/affairs');
    }
  }

  Widget _commitment(BuildContext context, ProgressViewModel model) {
    final item = model.commitment(widget.id);
    if (item == null) return const ProgressEmpty('承诺不存在或暂不可用');
    final evidence = item.evidence;
    final goal = model.goal(item.goalId);
    final meetings = context.watch<MeetingViewModel?>();
    final meeting = meetings?.record?.id == evidence.sessionId
        ? meetings?.record
        : meetings?.history
              .where((m) => m.id == evidence.sessionId)
              .firstOrNull;
    // 只复用同场会议、同来源 ID 且原文一致的展示副本，避免把相似发言误当成此承诺。
    // evidence.transcript 仍保留原始引用，供证据校验和音频定位使用。
    final sourceUtterance = meeting?.utterances
        .where(
          (u) =>
              !u.withdrawn &&
              evidence.id.endsWith(':${u.id}') &&
              u.raw == evidence.transcript,
        )
        .firstOrNull;
    final transcript = sourceUtterance?.display ?? evidence.displayTranscript;
    // 逾期仅影响展示，不阻止补报完成；按钮按持久化状态判定，不能把声明完成当成核实通过。
    final canComplete =
        item.status == CommitmentStatus.planned ||
        item.status == CommitmentStatus.active;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SelectableText(
          '「${transcript.isEmpty ? item.title : transcript}」',
          style: HomeStyle.text(20),
        ),
        const SizedBox(height: 10),
        Text(
          evidence.isDocument
              ? '文档来源 · ${progressDate(evidence.recordedAt)}'
              : '发言人：待确认 · ${evidence.meetingTitle ?? meeting?.title ?? '会议记录'} · ${voiceTime(evidence.start)}',
          style: HomeStyle.text(12, color: HomeStyle.secondary(context)),
        ),
        if (!evidence.isDocument) ...[
          const SizedBox(height: 14),
          VoiceEvidencePlayer(evidence: evidence, detail: true),
        ],
        _commitmentHeading('承诺信息'),
        ProgressCard(
          padding: 0,
          child: Column(
            children: [
              _CommitmentInfoRow('约定方', item.side.itemLabel.tr(context)),
              const Divider(height: 1),
              _CommitmentInfoRow('承诺时间', progressDate(item.createdAt)),
              const Divider(height: 1),
              _CommitmentInfoRow('截止时间', progressDate(item.deadline)),
              if (item.withdrawalReason != null) ...[
                const Divider(height: 1),
                _CommitmentInfoRow('撤回原因', item.withdrawalReason!),
              ],
            ],
          ),
        ),
        _commitmentHeading('关联目标'),
        if (goal != null)
          ProgressCard(
            onTap: () => context.push('/progress/goals/${goal.id}'),
            child: Row(
              children: [
                const Icon(Icons.flag_outlined, color: HomeStyle.blue),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(goal.title, style: HomeStyle.text(14, bold: true)),
                      const SizedBox(height: 4),
                      Text(
                        '${goal.status.label} · ${goal.deadlineLabel(DateTime.now())}',
                        style: HomeStyle.text(
                          12,
                          color: HomeStyle.secondary(context),
                        ),
                      ),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right, size: 18),
              ],
            ),
          )
        else
          const ProgressEmpty('暂无可用的关联目标'),
        // 会议来源统一收敛为一个可点击条目，不另加纪要链接或重复的知识库卡片。
        if (!evidence.isDocument) ...[
          _commitmentHeading('来源会议'),
          ProgressCard(
            key: const ValueKey('commitment-source-meeting'),
            onTap: () {
              if (evidence.sessionId.trim().isEmpty) {
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(const SnackBar(content: Text('来源会议暂不可用')));
                return;
              }
              // 使用证据绑定的会议 ID 直达纪要，避免依赖标题或两个文档入口的来源映射。
              context.push(
                '/meetings/${Uri.encodeComponent(evidence.sessionId)}/minutes',
              );
            },
            child: Row(
              children: [
                const Icon(Icons.mic_none_outlined, color: HomeStyle.blue),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        evidence.meetingTitle ?? meeting?.title ?? '会议记录',
                        style: HomeStyle.text(14, bold: true),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${progressDate(meeting?.startedAt ?? evidence.recordedAt)} · ${meeting == null || meeting.elapsed <= Duration.zero ? '时长待补充' : '时长 ${voiceTime(meeting.elapsed)}'} · 发言人数待确认',
                        style: HomeStyle.text(
                          12,
                          color: HomeStyle.secondary(context),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                const Icon(Icons.chevron_right, size: 18),
              ],
            ),
          ),
        ],
        // 本页暂不渲染知识库区域；knowledgeReferences 仍保留，未删除或合并底层关联。
        const SizedBox(height: 14),
        ProgressCard(
          child: Text(
            '当前状态：${item.statusAt(DateTime.now()).label}。履约结果以实际核验为准。',
            style: HomeStyle.text(12, color: HomeStyle.secondary(context)),
          ),
        ),
        if (item.status == CommitmentStatus.pending) ...[
          const SizedBox(height: 12),
          Text(
            '履约信息已补全，请核对并确认这条承诺。',
            style: HomeStyle.text(12, color: HomeStyle.secondary(context)),
          ),
        ],
        if (canComplete) ...[
          const SizedBox(height: 12),
          Text(
            '完成后标记为声称完成，履约结果仍需核实。',
            style: HomeStyle.text(12, color: HomeStyle.secondary(context)),
          ),
        ],
        // 确认或完成与移除等宽并排；声明完成后隐藏主按钮，已核实/已撤回不提供操作。
        if ({
          CommitmentStatus.pending,
          CommitmentStatus.planned,
          CommitmentStatus.active,
          CommitmentStatus.claimed,
        }.contains(item.status)) ...[
          const SizedBox(height: 10),
          Row(
            children: [
              if (item.status == CommitmentStatus.pending || canComplete) ...[
                Expanded(
                  child: FilledButton(
                    key: ValueKey(
                      canComplete
                          ? 'complete-commitment'
                          : 'confirm-commitment',
                    ),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(0, 48),
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                    ),
                    onPressed: model.saving || model.loading
                        ? null
                        : () => canComplete
                              ? _changeCommitment(
                                  model,
                                  item,
                                  CommitmentStatus.claimed,
                                )
                              : _confirmCommitment(model, item),
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        canComplete
                            ? (_submittingStatus == CommitmentStatus.claimed
                                  ? '正在提交…'
                                  : '完成承诺')
                            : (_submittingStatus == CommitmentStatus.planned
                                  ? '正在确认…'
                                  : '确认承诺'),
                        maxLines: 1,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
              ],
              Expanded(
                child: OutlinedButton(
                  key: const ValueKey('remove-commitment'),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(0, 48),
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    foregroundColor: Theme.of(context).colorScheme.error,
                    side: BorderSide(
                      color: Theme.of(
                        context,
                      ).colorScheme.error.withValues(alpha: .4),
                    ),
                  ),
                  onPressed: model.saving || model.loading
                      ? null
                      : () => _changeCommitment(
                          model,
                          item,
                          CommitmentStatus.withdrawn,
                        ),
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      _submittingStatus == CommitmentStatus.withdrawn
                          ? '正在移除…'
                          : '移除承诺',
                      maxLines: 1,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
        _demoNote(context),
      ],
    );
  }
}

class _CommitmentInfoRow extends StatelessWidget {
  const _CommitmentInfoRow(this.label, this.value);
  final String label, value;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: HomeStyle.text(12, color: HomeStyle.secondary(context)),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Text(
            value,
            textAlign: TextAlign.right,
            style: HomeStyle.text(13),
          ),
        ),
      ],
    ),
  );
}

Widget _demoNote(BuildContext context) => Padding(
  padding: const EdgeInsets.only(top: 20),
  child: Text(
    context.watch<ProgressViewModel>().data.demo
        ? '言枢 · 演示数据，重启后恢复。不代表真实业务履行或录音。'
        : '言枢 · 来源于会议或资料，履约状态以实际核验为准。',
    style: HomeStyle.text(12, color: HomeStyle.secondary(context)),
  ),
);

Widget _commitmentHeading(String value) => Padding(
  padding: const EdgeInsets.fromLTRB(0, 20, 0, 10),
  child: Text(value, style: HomeStyle.text(12)),
);
