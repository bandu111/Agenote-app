import '../models/progress_models.dart';

abstract interface class ProgressRepository {
  Future<ProgressSnapshot> load();
  Future<void> updateCommitment(
    String id,
    CommitmentStatus status,
    String note,
  );
  Future<void> rescheduleCommitment(
    String id,
    DateTime deadline,
    String reason,
  );
  Future<void> approveArtifact(String id, String note);
}

abstract interface class AccountProgressRepository
    implements ProgressRepository {
  String? get accountId;
}

abstract interface class ProgressCompletionRepository {
  Future<void> completeMissing(
    PendingProgressItem item, {
    CommitmentSide? side,
    DateTime? deadline,
  });
}

abstract interface class GoalRemovalRepository {
  Future<void> removeGoal(String id);
}

/// 未配置账户后端时保持空状态，不填入演示业务，也不假装写入成功。
class EmptyProgressRepository implements ProgressRepository {
  @override
  Future<ProgressSnapshot> load() async => const ProgressSnapshot(demo: false);
  @override
  Future<void> updateCommitment(
    String id,
    CommitmentStatus status,
    String note,
  ) async => throw StateError('尚未连接账户进展服务');
  @override
  Future<void> rescheduleCommitment(
    String id,
    DateTime deadline,
    String reason,
  ) async => throw StateError('尚未连接账户进展服务');
  @override
  Future<void> approveArtifact(String id, String note) async =>
      throw StateError('尚未连接账户进展服务');
}

/// Local, synthetic examples only. No network, real identity, or audio recording.
class MockProgressRepository
    implements ProgressRepository, GoalRemovalRepository {
  MockProgressRepository({DateTime? now, ProgressSnapshot? seed})
    : _now = now ?? DateTime.now() {
    _snapshot = seed ?? _examples(_now);
  }
  final DateTime _now;
  late ProgressSnapshot _snapshot;
  final _removedGoals = <String>{};
  @override
  Future<ProgressSnapshot> load() async => ProgressSnapshot(
    goals: _snapshot.goals.where((g) => !_removedGoals.contains(g.id)).toList(),
    pending: _snapshot.pending
        .where((p) => p.kind != 'goal' || !_removedGoals.contains(p.id))
        .toList(),
    commitments: _snapshot.commitments,
    artifacts: _snapshot.artifacts,
    demo: _snapshot.demo,
  );
  @override
  Future<void> removeGoal(String id) async {
    if (!_snapshot.goals.any((g) => g.id == id)) throw StateError('目标不存在');
    _removedGoals.add(id);
  }

  @override
  Future<void> updateCommitment(
    String id,
    CommitmentStatus status,
    String note,
  ) async {
    final item = _snapshot.commitments.firstWhere((c) => c.id == id);
    if (!allowedCommitmentUpdates(item.status).contains(status)) {
      throw StateError('当前状态不能进行此变更');
    }
    if (note.trim().isEmpty) throw StateError('请填写变更说明');
    final changed = item.revised(
      at: DateTime.now(),
      status: status,
      note: '${item.status.label} → ${status.label}：${note.trim()}',
    );
    _replaceCommitment(changed);
  }

  @override
  Future<void> rescheduleCommitment(
    String id,
    DateTime deadline,
    String reason,
  ) async {
    final item = _snapshot.commitments.firstWhere((c) => c.id == id);
    if (!item.status.needsFollowUp || reason.trim().isEmpty) {
      throw StateError('已结束的承诺不可改期，改期需要说明双方约定');
    }
    _replaceCommitment(
      item.revised(
        at: DateTime.now(),
        deadline: deadline,
        note:
            '截止时间由 ${progressDate(item.deadline)} 改为 ${progressDate(deadline)}：${reason.trim()}',
      ),
    );
  }

  void _replaceCommitment(Commitment item) {
    _snapshot = ProgressSnapshot(
      goals: _snapshot.goals,
      pending: _snapshot.pending,
      demo: _snapshot.demo,
      commitments: List.unmodifiable(
        _snapshot.commitments.map((c) => c.id == item.id ? item : c),
      ),
      artifacts: _snapshot.artifacts,
    );
  }

  @override
  Future<void> approveArtifact(String id, String note) async {
    final item = _snapshot.artifacts.firstWhere((a) => a.id == id);
    if (item.status != ArtifactStatus.confirmation || note.trim().isEmpty) {
      throw StateError('只能确认当前待确认的成果版本');
    }
    _snapshot = ProgressSnapshot(
      goals: _snapshot.goals,
      pending: _snapshot.pending,
      demo: _snapshot.demo,
      commitments: _snapshot.commitments,
      artifacts: List.unmodifiable(
        _snapshot.artifacts.map(
          (a) => a.id == id
              ? a.withApproval('模拟批准 ${a.version}：${note.trim()}')
              : a,
        ),
      ),
    );
  }

  static ProgressSnapshot _examples(DateTime now) {
    final day = DateTime(now.year, now.month, now.day);
    final meeting = day
        .subtract(const Duration(days: 3))
        .add(const Duration(hours: 14));
    final goals = [
      ProgressGoal(
        id: 'goal-delivery',
        projectId: 'delivery',
        title: '星澜客户管理 App 一期交付',
        code: 'CP-PRJ-2024-09',
        phase: '项目一期',
        condition: '完成 Android / iOS 双端测试并部署至客户预发环境',
        acceptance: '满足双方已经确认的交付指标',
        deadline: day.add(const Duration(days: 18, hours: 18)),
        status: GoalStatus.active,
        milestones: const [
          Milestone('需求范围确认', weight: 20, completed: true),
          Milestone('核心模块开发', weight: 25, completed: true),
          Milestone('双端联调', weight: 23, completed: true),
          Milestone('双端测试与问题修复', weight: 20, status: MilestoneStatus.active),
          Milestone('预发部署与客户验收', weight: 12),
        ],
        history: [
          ProgressChange(meeting, '双方确认一期交付范围'),
          ProgressChange(day, '完成双端联调，进入测试阶段'),
        ],
      ),
      ProgressGoal(
        id: 'goal-desktop',
        projectId: 'desktop',
        title: '桌面端需求评估与范围确认',
        code: 'CP-SCOPE-2024-02',
        phase: '范围评估',
        condition: '形成桌面端范围、影响评估与分期建议',
        acceptance: '等待双方确认范围与验收标准',
        deadline: day.add(const Duration(days: 7, hours: 18)),
        status: GoalStatus.pending,
        milestones: const [
          Milestone('需求访谈', weight: 30, completed: true),
          Milestone('影响评估', weight: 40),
          Milestone('范围确认', weight: 30),
        ],
        history: [ProgressChange(meeting, '范围评估已建立，尚未形成正式交付承诺')],
      ),
    ];
    const titles = [
      '周三前提交新平台技术可行性与工期评估报告',
      '完成双端测试问题清单与修复计划',
      '提供预发环境访问方式与测试账号',
      '确认一期验收指标与测试范围',
      '提供最新桌面端需求说明',
    ];
    const quotes = [
      '我们会在下次会议前提交完整的技术评估报告。',
      '我们会整理双端测试问题清单，并提出修复计划。',
      '我们会提供预发环境的测试账号。',
      '我先核对验收指标，下次会议再确认。',
      '资料已经整理完成，稍后提供需求说明。',
    ];
    final commitments = List.generate(5, (i) {
      final ours = i < 2;
      final evidence = VoiceEvidence(
        id: 'voice-$i',
        commitmentId: 'commitment-$i',
        sessionId: 'session-review',
        start: Duration(seconds: 72 + i * 45),
        end: Duration(seconds: 110 + i * 45),
        transcript: quotes[i],
        recordedAt: meeting,
        timeZone: 'Asia/Shanghai',
        source: EvidenceSource.missingDemo,
        access: EvidenceAccess.authorized,
      );
      return Commitment(
        id: 'commitment-$i',
        side: ours ? CommitmentSide.ours : CommitmentSide.theirs,
        person: ours ? '技术负责人' : '客户项目负责人（待确认）',
        title: titles[i],
        summary: '${meeting.month}/${meeting.day} 项目会议中的演示承诺，后续变更保留记录。',
        goalId: 'goal-delivery',
        createdAt: meeting,
        deadline: day.add(Duration(days: i + 2, hours: 18)),
        status: [
          CommitmentStatus.active,
          CommitmentStatus.planned,
          CommitmentStatus.planned,
          CommitmentStatus.pending,
          CommitmentStatus.claimed,
        ][i],
        progress: i == 0 ? .8 : 0,
        evidence: evidence,
        attachment: i == 0 ? 'PRD–Arch–v2.1.pdf' : null,
        history: [
          ProgressChange(
            meeting,
            i == 3 ? '讨论已记录，承诺归属和成立情况待确认' : '录入演示承诺；未核实实际履行',
          ),
        ],
      );
    });
    const names = [
      'Windows 需求影响评估',
      '双端测试方案与检查清单',
      '一期交付风险与分期建议',
      '预发部署手册',
      '客户验收范围记录',
      '桌面端需求访谈纪要',
    ];
    final artifacts = List.generate(
      6,
      (i) => ProgressArtifact(
        id: 'artifact-$i',
        title: names[i],
        summary: i == 0
            ? '基于项目资料与相关讨论，整理桌面端需求对现有交付方案的影响。'
            : '结合项目上下文整理${names[i]}，供下一阶段讨论与核对。',
        goalId: i < 4 ? 'goal-delivery' : 'goal-desktop',
        version: i == 0 ? 'v1.2' : 'v1.0',
        createdAt: meeting.add(Duration(hours: i)),
        status: [
          ArtifactStatus.confirmation,
          ArtifactStatus.preparing,
          ArtifactStatus.confirmation,
          ArtifactStatus.confirmation,
          ArtifactStatus.verified,
          ArtifactStatus.verified,
        ][i],
        content:
            '一、背景与目标\n根据演示会议与项目范围，整理${names[i]}。\n\n'
            '二、当前结论\n一期优先完成 Android / iOS 双端交付。桌面端新增范围应单独评估依赖、工期与验收条件。\n\n'
            '三、下一步\n核对双方约定与资料，确认未决范围后更新交付计划。\n\n'
            '本文为内置演示草稿，不代表真实 AI 生成结果或已签署文件。',
        risk: i == 0
            ? '新增桌面端范围可能影响当前 30 天交付周期，请先确认分期策略。'
            : '请结合最新有效资料核对，不用于替代正式确认。',
      ),
    );
    return ProgressSnapshot(
      goals: List.unmodifiable(goals),
      commitments: List.unmodifiable(commitments),
      artifacts: List.unmodifiable(artifacts),
    );
  }
}

Set<CommitmentStatus> allowedCommitmentUpdates(CommitmentStatus status) =>
    switch (status) {
      CommitmentStatus.pending => {
        CommitmentStatus.planned,
        CommitmentStatus.withdrawn,
      },
      CommitmentStatus.planned ||
      CommitmentStatus.active ||
      CommitmentStatus.overdue => {
        CommitmentStatus.active,
        CommitmentStatus.claimed,
        CommitmentStatus.withdrawn,
      }..remove(status),
      CommitmentStatus.claimed => {
        CommitmentStatus.verified,
        CommitmentStatus.active,
        CommitmentStatus.withdrawn,
      },
      CommitmentStatus.verified || CommitmentStatus.withdrawn => {},
    };
