import 'dart:io';
import '../../../core/network/api_client.dart';
import '../../../core/network/api_config.dart';
import '../../meeting/meeting_store.dart';
import '../models/progress_models.dart';
import 'progress_repository.dart';

/// 复用账户 Dio；服务器无数据时保持空列表，不回退到演示项目。
class DioProgressRepository
    implements
        AccountProgressRepository,
        ProgressCompletionRepository,
        GoalRemovalRepository {
  DioProgressRepository(this.client, {this.meetingStore});
  final ApiClient client;
  final MeetingStore? meetingStore;
  final Map<String, Map<String, dynamic>> _versions = {};
  String? _cachedOwner;
  int skippedRows = 0;
  List<T> _parseRows<T>(Object? raw, T Function(Map<String, dynamic>) parse) {
    final result = <T>[];
    if (raw is! List) return result;
    for (final row in raw) {
      try {
        result.add(parse(Map<String, dynamic>.from(row as Map)));
      } catch (_) {
        skippedRows++;
      }
    }
    return result;
  }

  @override
  String? get accountId => client.accountId?.call();

  String _owner() {
    final owner = accountId;
    if (owner == null) throw const ApiFailure('请先登录账户');
    if (_cachedOwner != owner) {
      _versions.clear();
      _cachedOwner = owner;
    }
    return owner;
  }

  @override
  Future<ProgressSnapshot> load() async {
    if (accountId == null) return const ProgressSnapshot(demo: false);
    final owner = _owner();
    final response = await client.get(
      'progress',
      authenticated: true,
      accountId: owner,
    );
    final local = await meetingStore?.read() ?? [];
    if (accountId != owner) throw const ApiFailure('账户已切换');
    final data = Map<String, dynamic>.from(response['data']);
    skippedRows = 0;
    _versions.clear();
    for (final key in ['goals', 'commitments', 'artifacts', 'pending']) {
      for (final value in _parseRows(data[key], (row) => row)) {
        if (value['id'] is! String || value['version'] is! int) continue;
        _versions["${key == 'pending' ? '${value['kind']}s' : key}:${value['id']}"] =
            Map<String, dynamic>.from(value);
      }
    }
    List<ProgressChange> history(Map item) => [
      for (final event in item['history'] as List? ?? [])
        ProgressChange(DateTime.parse(event['at']), event['description']),
    ];
    return ProgressSnapshot(
      demo: false,
      pending: [
        for (final value in data['pending'] as List? ?? [])
          if (value['status'] != 'withdrawn' &&
              value['status'] != 'completed' &&
              value['status'] != 'verified')
            PendingProgressItem(
              reviewPending:
                  value['reviewPending'] == true ||
                  value['reason'] == '原话已变更，等待重新核对',
              expiredByClear: value['expiredByClear'] == true,
              id: value['id'],
              kind: value['kind'],
              title: value['title'],
              version: value['version'],
              side: switch (value['side']) {
                'ours' => CommitmentSide.ours,
                'theirs' => CommitmentSide.theirs,
                _ => null,
              },
              deadline: DateTime.tryParse(value['deadline'] ?? ''),
            ),
      ],
      goals: _parseRows(
        data['goals'],
        (value) => ProgressGoal(
          expiredByClear: value['expiredByClear'] == true,
          id: value['id'],
          title: value['title'],
          code: value['code'] ?? '',
          phase: value['phase'] ?? '',
          condition: value['condition'] ?? '',
          acceptance: value['acceptance'] ?? '',
          deadline: DateTime.tryParse(value['deadline'] ?? ''),
          status: GoalStatus.values.byName(value['status']),
          milestones: [
            for (final m in value['milestones'] as List)
              Milestone(
                m['title'],
                weight: m['weight'],
                status: MilestoneStatus.values.byName(m['status']),
                statusBasis: m['statusBasis'],
              ),
          ],
          history: history(value),
          projectId: value['projectId'],
          knowledgeReferences: [
            for (final r in value['knowledgeReferences'] ?? [])
              Map<String, dynamic>.from(r),
          ],
        ),
      ),
      commitments: _parseRows(
        data['commitments'],
        (value) => () {
          final source = value['evidence'] as Map;
          final record = local
              .where(
                (r) =>
                    r.ownerId == owner &&
                    r.id == source['sessionId'] &&
                    !r.demo,
              )
              .firstOrNull;
          final utterance = record?.utterances
              .where(
                (u) => u.id == source['id'] && u.raw == source['transcript'],
              )
              .firstOrNull;
          final hasAudio =
              utterance?.hasAudio == true &&
              File(utterance!.audioPath!).existsSync();
          return Commitment(
            version: value['version'],
            reviewPending: value['reviewPending'] == true,
            expiredByClear: value['expiredByClear'] == true,
            id: value['id'],
            side: CommitmentSide.values.byName(value['side']),
            person: value['person'] ?? '',
            title: value['title'],
            summary: value['summary'] ?? '',
            goalId: value['goalId'] ?? '',
            createdAt: DateTime.parse(value['createdAt']),
            deadline: DateTime.parse(value['deadline']),
            status: CommitmentStatus.values.byName(value['status']),
            history: history(value),
            withdrawalReason: value['withdrawalReason'],
            attachment: value['attachment'],
            knowledgeReferences: [
              for (final r in value['knowledgeReferences'] ?? [])
                Map<String, dynamic>.from(r),
            ],
            evidence: VoiceEvidence(
              id: '${value['id']}:${source['id']}',
              commitmentId: value['id'],
              sessionId: source['sessionId'],
              transcript: source['transcript'],
              // utterance 已按账户、会议、来源 ID 和原文核对；页面未加载会议历史也能展示整理版。
              cleaned: utterance?.cleaned ?? '',
              correction: utterance?.correction,
              start: hasAudio
                  ? utterance.audioStart!
                  : Duration(milliseconds: source['start']),
              end: hasAudio
                  ? utterance.audioEnd!
                  : Duration(milliseconds: source['end']),
              uri: hasAudio
                  ? Uri.file(utterance.audioPath!)
                  : source['audioId'] == null
                  ? null
                  : Uri(scheme: 'yanshu-audio', path: source['audioId']),
              meetingTitle: source['meetingTitle'],
              recordedAt: DateTime.parse(source['recordedAt']),
              timeZone: source['timeZone'],
              source: EvidenceSource.provided,
              access: EvidenceAccess.authorized,
              speakerConfirmed: false,
              documentId: source['kind'] == 'document'
                  ? source['documentId'] as String?
                  : null,
              versionId: source['kind'] == 'document'
                  ? source['versionId'] as String?
                  : null,
            ),
          );
        }(),
      ),
      artifacts: _parseRows(
        data['artifacts'],
        (value) => ProgressArtifact(
          id: value['id'],
          title: value['title'],
          summary: value['summary'] ?? '',
          goalId: value['goalId'] ?? '',
          version: value['versionLabel'],
          createdAt: DateTime.parse(value['createdAt']),
          status: ArtifactStatus.values.byName(value['status']),
          content: value['content'],
          risk: value['risk'],
          approvalNote: value['approvalNote'],
        ),
      ),
    );
  }

  Future<void> _write(
    String id,
    String action,
    Map<String, dynamic> data, {
    String? entityKind,
  }) async {
    final owner = _owner();
    final kind =
        entityKind ??
        (action.startsWith('artifacts/')
            ? 'artifacts'
            : action.startsWith('commitments/')
            ? 'commitments'
            : (_versions.containsKey('commitments:$id')
                  ? 'commitments'
                  : 'goals'));
    final current = _versions['$kind:$id'];
    if (current == null) throw const ApiFailure('请先刷新进展');
    await client.post(
      'progress/$action',
      authenticated: true,
      accountId: owner,
      data: {...data, 'version': current['version']},
    );
    if (accountId != owner) throw const ApiFailure('账户已切换');
    _versions.remove('$kind:$id');
  }

  @override
  Future<void> completeMissing(
    PendingProgressItem item, {
    CommitmentSide? side,
    DateTime? deadline,
  }) async {
    if (_versions['${item.kind}s:${item.id}']?['version'] != item.version) {
      throw const ApiFailure('记录已更新，请刷新后补全');
    }
    await _write(item.id, '${item.id}/complete', {
      if (side != null) 'side': side.name,
      if (deadline != null) 'deadline': deadline.toUtc().toIso8601String(),
      'note': '用户补全履约信息',
    }, entityKind: '${item.kind}s');
  }

  Future<void> confirmCommitment(Commitment expected) async {
    final row = _versions['commitments:${expected.id}'];
    if (row == null ||
        row['version'] != expected.version ||
        row['title'] != expected.title ||
        (row['summary'] ?? '') != expected.summary ||
        row['side'] != expected.side.name ||
        (row['person'] ?? '') != expected.person ||
        (row['evidence'] as Map?)?['transcript'] !=
            expected.evidence.transcript ||
        row['reviewPending'] == true ||
        DateTime.tryParse(row['deadline'] ?? '') != expected.deadline) {
      throw const ApiFailure('承诺已更新，请刷新并核对后确认');
    }
    try {
      await updateCommitment(
        expected.id,
        CommitmentStatus.planned,
        '用户明确确认当前版本承诺成立',
      );
    } on ApiFailure catch (error) {
      if (error.status == 409) {
        throw const ApiFailure('承诺已更新或正在复核，请刷新并核对后确认');
      }
      rethrow;
    }
  }

  @override
  Future<void> removeGoal(String id) => _write(
    id,
    'goals/${Uri.encodeComponent(id)}/remove',
    {'note': '用户在目标详情移除目标，保留原始记录'},
    entityKind: 'goals',
  );

  @override
  Future<void> updateCommitment(
    String id,
    CommitmentStatus status,
    String note,
  ) => _write(id, 'commitments/$id/status', {
    'status': status.name,
    'note': note,
  });
  @override
  Future<void> rescheduleCommitment(
    String id,
    DateTime deadline,
    String reason,
  ) => _write(id, 'commitments/$id/reschedule', {
    'deadline': deadline.toUtc().toIso8601String(),
    'reason': reason,
  });
  @override
  Future<void> approveArtifact(String id, String note) =>
      _write(id, 'artifacts/$id/approve', {
        'note': note,
        'artifactVersion': _versions['artifacts:$id']?['versionLabel'],
      });
}
