enum GoalStatus {
  active('进行中'),
  completed('已完成'),
  delayed('已延期'),
  paused('已暂停'),
  pending('待确认');

  const GoalStatus(this.label);
  final String label;
}

enum CommitmentSide {
  ours('我方承诺'),
  theirs('对方承诺');

  const CommitmentSide(this.label);
  final String label;
  String get itemLabel => this == ours ? '我方履约项' : '对方履约项';
}

enum CommitmentStatus {
  pending('待确认'),
  planned('待履行'),
  active('进行中'),
  claimed('声称完成'),
  verified('已核实'),
  withdrawn('已撤回'),
  overdue('已逾期');

  const CommitmentStatus(this.label);
  final String label;
  bool get needsFollowUp => this != verified && this != withdrawn;
}

enum ArtifactStatus {
  preparing('准备中'),
  prepared('已准备'),
  confirmation('待确认'),
  approved('已批准'),
  verified('已验证'),
  expired('已过期'),
  failed('处理失败');

  const ArtifactStatus(this.label);
  final String label;
}

enum ArtifactFilter {
  all('全部'),
  preparing('准备中'),
  confirmation('待确认'),
  accepted('已验收');

  const ArtifactFilter(this.label);
  final String label;
  bool matches(ProgressArtifact item) => switch (this) {
    all => true,
    preparing => item.status == ArtifactStatus.preparing,
    confirmation => item.status == ArtifactStatus.confirmation,
    accepted => item.status == ArtifactStatus.verified,
  };
}

enum MilestoneStatus { pending, active, completed }

class Milestone {
  const Milestone(
    this.title, {
    required this.weight,
    bool completed = false,
    MilestoneStatus? status,
    this.statusBasis,
  }) : status =
           status ??
           (completed ? MilestoneStatus.completed : MilestoneStatus.pending);
  final String title;
  final int weight;
  final MilestoneStatus status;
  final String? statusBasis;
  bool get completed => status == MilestoneStatus.completed;
}

class ProgressChange {
  const ProgressChange(this.at, this.description);
  final DateTime at;
  final String description;
}

class ProgressGoal {
  const ProgressGoal({
    required this.id,
    required this.title,
    required this.code,
    required this.phase,
    required this.condition,
    required this.acceptance,
    required this.deadline,
    required this.status,
    required this.milestones,
    required this.history,
    this.projectId,
    this.expiredByClear = false,
    this.knowledgeReferences = const [],
  });
  final String id, title, code, phase, condition, acceptance;
  final String? projectId;
  final bool expiredByClear;
  final List<Map<String, dynamic>> knowledgeReferences;
  final DateTime? deadline;
  final GoalStatus status;
  final List<Milestone> milestones;
  final List<ProgressChange> history;
  ProgressGoal withStatus(GoalStatus value) => ProgressGoal(
    id: id,
    title: title,
    code: code,
    phase: phase,
    condition: condition,
    acceptance: acceptance,
    deadline: deadline,
    status: value,
    milestones: milestones,
    history: history,
    projectId: projectId,
    expiredByClear: expiredByClear,
    knowledgeReferences: knowledgeReferences,
  );
  String statusLabelAt(DateTime now) =>
      status != GoalStatus.completed &&
          (expiredByClear || deadline != null && !now.isBefore(deadline!))
      ? '已过期'
      : status.label;
  double get progress {
    final total = milestones.fold<int>(0, (sum, m) => sum + m.weight);
    if (total <= 0) return 0;
    final done = milestones
        .where((m) => m.completed)
        .fold<int>(0, (sum, m) => sum + m.weight);
    return (done / total).clamp(0, 1);
  }

  int remainingDays(DateTime now) {
    final local = deadline?.toLocal();
    if (local == null) return 0;
    final today = now.toLocal();
    return DateTime.utc(
      local.year,
      local.month,
      local.day,
    ).difference(DateTime.utc(today.year, today.month, today.day)).inDays;
  }

  /// 截止时间只改变展示，不自动宣称目标已完成或撤回。
  String deadlineLabel(DateTime now) {
    if (status == GoalStatus.completed) return '已完成';
    if (expiredByClear) return '已过期';
    final end = deadline;
    if (end == null) return '交期待明确';
    if (!now.isBefore(end)) return '已过期';
    final days = remainingDays(now);
    return days <= 0 ? '今天到期' : '剩余 $days 天';
  }
}

enum EvidenceSource { missingDemo, provided }

enum EvidenceAccess { authorized, unknown, denied }

class VoiceEvidence {
  const VoiceEvidence({
    required this.id,
    required this.commitmentId,
    required this.sessionId,
    this.uri,
    required this.start,
    required this.end,
    required this.transcript,
    this.cleaned = '',
    this.correction,
    required this.recordedAt,
    required this.timeZone,
    required this.source,
    required this.access,
    this.speakerConfirmed = false,
    this.documentId,
    this.versionId,
    this.meetingTitle,
  });
  final String id, commitmentId, sessionId, transcript, timeZone;
  final String cleaned;
  final String? correction;
  String get displayTranscript => correction?.trim().isNotEmpty == true
      ? correction! : cleaned.trim().isNotEmpty ? cleaned : transcript;
  final Uri? uri;
  final Duration start, end;
  final DateTime recordedAt;
  final EvidenceSource source;
  final EvidenceAccess access;
  final bool speakerConfirmed;
  final String? documentId, versionId;
  final String? meetingTitle;
  bool get isDocument => documentId != null;
  Duration get duration => end - start;
  String? get unavailableReason {
    if (isDocument) return '文档依据不包含录音';
    if (access != EvidenceAccess.authorized) return '语音证据尚未获得播放授权';
    if (source == EvidenceSource.missingDemo) return '示例音频未提供';
    if (uri == null) return '当前设备未保存该语音片段';
    if (duration <= Duration.zero) return '语音片段时间无效';
    return null;
  }
}

class Commitment {
  const Commitment({
    required this.id,
    required this.side,
    required this.person,
    required this.title,
    required this.summary,
    required this.goalId,
    required this.createdAt,
    required this.deadline,
    required this.status,
    required this.evidence,
    required this.history,
    this.progress = 0,
    this.version = 1,
    this.reviewPending = false,
    this.expiredByClear = false,
    this.attachment,
    this.withdrawalReason,
    this.knowledgeReferences = const [],
  });
  final String id, person, title, summary, goalId;
  final CommitmentSide side;
  final DateTime createdAt, deadline;
  final CommitmentStatus status;
  final double progress;
  final int version;
  final bool reviewPending;
  int get confirmationKey => Object.hash(
    version,
    title,
    summary,
    side,
    person,
    deadline,
    goalId,
    evidence.transcript,
  );
  final bool expiredByClear;
  final VoiceEvidence evidence;
  final String? attachment, withdrawalReason;
  final List<Map<String, dynamic>> knowledgeReferences;
  final List<ProgressChange> history;
  CommitmentStatus statusAt(DateTime now) =>
      (status == CommitmentStatus.pending ||
              status == CommitmentStatus.planned ||
              status == CommitmentStatus.active) &&
          (expiredByClear || !deadline.isAfter(now))
      ? CommitmentStatus.overdue
      : status;
  Commitment revised({
    required DateTime at,
    required String note,
    CommitmentStatus? status,
    DateTime? deadline,
  }) => Commitment(
    id: id,
    side: side,
    person: person,
    title: title,
    summary: summary,
    goalId: goalId,
    createdAt: createdAt,
    deadline: deadline ?? this.deadline,
    status: status ?? this.status,
    evidence: evidence,
    progress: progress,
    version: version + 1,
    reviewPending: reviewPending,
    expiredByClear: expiredByClear,
    attachment: attachment,
    knowledgeReferences: knowledgeReferences,
    withdrawalReason: status == CommitmentStatus.withdrawn
        ? note
        : withdrawalReason,
    history: [...history, ProgressChange(at, note)],
  );
}

class ProgressArtifact {
  const ProgressArtifact({
    required this.id,
    required this.title,
    required this.summary,
    required this.goalId,
    required this.version,
    required this.createdAt,
    required this.status,
    required this.content,
    required this.risk,
    this.approvalNote,
  });
  final String id, title, summary, goalId, version, content, risk;
  final DateTime createdAt;
  final ArtifactStatus status;
  final String? approvalNote;
  ProgressArtifact withApproval(String note) => ProgressArtifact(
    id: id,
    title: title,
    summary: summary,
    goalId: goalId,
    version: version,
    createdAt: createdAt,
    status: ArtifactStatus.approved,
    content: content,
    risk: risk,
    approvalNote: note,
  );
}

class ProgressSnapshot {
  const ProgressSnapshot({
    this.goals = const [],
    this.commitments = const [],
    this.artifacts = const [],
    this.demo = true,
    this.pending = const [],
  });
  final List<ProgressGoal> goals;
  final List<Commitment> commitments;
  final List<ProgressArtifact> artifacts;
  final bool demo;
  final List<PendingProgressItem> pending;
}

class PendingProgressItem {
  const PendingProgressItem({
    required this.id,
    required this.kind,
    required this.title,
    required this.version,
    this.side,
    this.deadline,
    this.reviewPending = false,
    this.expiredByClear = false,
  });
  final String id, kind, title;
  final int version;
  final bool reviewPending;
  final bool expiredByClear;
  final CommitmentSide? side;
  final DateTime? deadline;
  bool get needsSide => kind == 'commitment' && side == null;
  bool get needsDeadline => deadline == null;
}

String progressDate(DateTime value) {
  final local = value.toLocal();
  return '${local.year}/${local.month.toString().padLeft(2, '0')}/${local.day.toString().padLeft(2, '0')}';
}

String voiceTime(Duration value) =>
    '${value.inMinutes.toString().padLeft(2, '0')}:${(value.inSeconds % 60).toString().padLeft(2, '0')}';

class ProgressSearchHit {
  const ProgressSearchHit(this.kind, this.title, this.subtitle, this.path);
  final String kind, title, subtitle, path;
}
