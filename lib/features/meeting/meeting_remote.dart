import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import '../../core/network/api_client.dart';
import '../../core/network/api_config.dart';
import 'meeting_models.dart';
import 'meeting_insights.dart';
import 'meeting_completion.dart';
import 'meeting_cloud_audio.dart';

abstract interface class MeetingSpeakerIdentityRemote {
  Future<Map<String, dynamic>> readSpeakerIdentities(MeetingRecord record);
}

abstract interface class MeetingAudioRemote {
  Future<void> uploadAudio(MeetingRecord record);
}

abstract interface class CancelableMeetingAudioRemote {
  Future<void> uploadAudioCancelable(
    MeetingRecord record,
    bool Function() isCurrent,
  );
}

abstract interface class MeetingDeletionRemote {
  Future<void> deleteMeeting(MeetingRecord record);
  Future<List<String>> deletedMeetingIds();
}

abstract interface class MeetingCompletionRemote {
  Future<List<MeetingCompletionItem>> completionItems(
    MeetingRecord record,
    List<String> sourceIds,
  );
  Future<MeetingCompletionItem> confirmCompletion(
    MeetingRecord record,
    MeetingCompletionItem item, {
    required String side,
    required DateTime deadline,
  });
}

abstract interface class MeetingRemoteRepository {
  String? get accountId;
  Future<void> sync(MeetingRecord record, {required bool paused});
  Future<Map<String, dynamic>> analyze(MeetingRecord record);
  Future<Map<String, dynamic>> archive(MeetingRecord record);
  Future<Map<String, dynamic>?> readArchive(MeetingRecord record);
  Future<List<MeetingRecord>> history();
}

/// Detail reads must not depend on the size or availability of history.
abstract interface class MeetingRecordReader {
  Future<MeetingRecord> readMeeting(String id);
}

/// 只检查认证连接和服务配置；不把配置检查冒充一次模型分析成功。
abstract interface class StreamingMeetingAnalysis {
  Future<Map<String, dynamic>> analyzeWithUpdates(
    MeetingRecord record,
    void Function(Map<String, dynamic>) onPreview,
  );
}

abstract interface class MeetingAnalysisConnection {
  Future<bool> checkAnalysisConnection();
}

/// 会中提示独立于完整分析队列，不产生正式业务状态。
abstract interface class LiveMeetingAnalysis {
  Future<void> liveHints(
    MeetingRecord record,
    void Function(Map<String, dynamic>) onUpdate,
  );
}

/// 只读风险独立于完整分析和 AI 补充；不写任务或批准。
abstract interface class LiveMeetingRiskAnalysis {
  Future<void> liveRisks(
    MeetingRecord record,
    void Function(Map<String, dynamic>) onUpdate,
  );
}

abstract interface class MeetingChangeReader {
  Future<List<Map<String, dynamic>>> readChanges(MeetingRecord record);
}

/// 会中业务小批次独立于完整分析、知识检索和会后问卷。
abstract interface class RealtimeMeetingBusiness {
  Future<void> updateBusiness(
    MeetingRecord record,
    void Function(Map<String, dynamic>) onUpdate,
  );
}

abstract interface class MeetingTranscriptPolisher {
  Future<String> polish(MeetingRecord record, MeetingUtterance utterance);
}

/// 只判断话者是否可能接着说，不参与业务决定或改写原话。
abstract interface class SemanticMeetingTurn {
  Future<bool?> isTurnComplete(MeetingRecord record, String text);
}

/// 仅传最终转写和状态，录音路径、录音数据及本地建议均留在手机。
Map<String, dynamic> meetingSyncPayload(
  MeetingRecord record, {
  required bool paused,
}) => {
  'id': record.id,
  'revision': record.syncRevision,
  'capabilities': ['tool_plans_v1', 'turns_v1'],
  'title': record.title,
  'startedAt': record.startedAt.toUtc().toIso8601String(),
  'elapsed': record.elapsed.inMilliseconds,
  'paused': paused && !record.ended,
  'ended': record.ended,
  'minutes': '',
  'utterances': [
    for (final u in record.utterances)
      {
        'id': u.id,
        'speaker': u.speaker,
        'speakerId': u.speakerId,
        'speakerSeparated': u.speakerSeparated,
        'speakerRevision': u.speakerRevision,
        'speakerHistory': u.speakerHistory,
        'raw': u.raw,
        'turnStatus': u.turnStatus,
        'turnId': u.turnId,
        'cleaned': u.cleaned,
        'correction': u.correction,
        'at': u.at.inMilliseconds,
        'withdrawn': u.withdrawn,
        'manual': u.manual,
      },
  ],
};

abstract interface class MeetingArchiveProgressRemote {
  ValueListenable<Map<String, dynamic>?> get archiveProgress;
}

class DioMeetingRepository
    implements
        MeetingRemoteRepository,
        MeetingSpeakerIdentityRemote,
        MeetingRecordReader,
        MeetingArchiveProgressRemote,
        MeetingDeletionRemote,
        MeetingTranscriptPolisher,
        SemanticMeetingTurn,
        MeetingAnalysisConnection,
        StreamingMeetingAnalysis,
        LiveMeetingAnalysis,
        LiveMeetingRiskAnalysis,
        RealtimeMeetingBusiness,
        MeetingChangeReader,
        MeetingAudioRemote,
        CancelableMeetingAudioRemote,
        MeetingCompletionRemote {
  @override
  ValueListenable<Map<String, dynamic>?> get archiveProgress =>
      _archiveProgress;
  final _archiveProgress = ValueNotifier<Map<String, dynamic>?>(null);

  DioMeetingRepository(
    this.client, {
    this.pollInterval = const Duration(seconds: 2),
  });
  final ApiClient client;
  @override
  Future<Map<String, dynamic>> readSpeakerIdentities(
    MeetingRecord record,
  ) async {
    final owner = _owner(record);
    final response = await client.get(
      'meetings/${Uri.encodeComponent(record.id)}/speaker-identities',
      authenticated: true,
      accountId: owner,
    );
    if (accountId != owner) throw const ApiFailure('账户已切换');
    return Map<String, dynamic>.from(response['data']);
  }

  @override
  Future<void> deleteMeeting(MeetingRecord record) async {
    final owner = _owner(record);
    await client.delete(
      'meetings/${Uri.encodeComponent(record.id)}',
      accountId: owner,
      data: {'revision': record.syncRevision},
    );
    if (accountId != owner) throw const ApiFailure('账户已切换');
  }

  @override
  Future<List<String>> deletedMeetingIds() async {
    final owner = accountId;
    if (owner == null) return [];
    final result = await client.get(
      'meetings/deleted',
      authenticated: true,
      accountId: owner,
    );
    if (accountId != owner) throw const ApiFailure('账户已切换');
    return List<String>.from(result['data'] as List);
  }

  @override
  Future<void> uploadAudioCancelable(
    MeetingRecord record,
    bool Function() isCurrent,
  ) => uploadMeetingAudio(client, record, isCurrent: isCurrent);

  @override
  Future<void> uploadAudio(MeetingRecord record) =>
      uploadMeetingAudio(client, record);
  Future<void> downloadAudioClip(
    MeetingRecord record,
    String id,
    String target,
    Duration start,
    Duration end,
  ) => client.downloadAudio(
    id,
    target,
    owner: _owner(record),
    start: start,
    end: end,
  );
  Future<Map<String, dynamic>> segmentImportant(String text) async {
    final owner = accountId;
    if (owner == null || text.length > 3000) return {};
    final result = await client.post(
      'meetings/segment-quality',
      data: {'text': text},
      authenticated: true,
      accountId: owner,
    );
    if (accountId != owner) return {};
    final data = result['data'] as Map?;
    return data?['available'] == true ? Map<String, dynamic>.from(data!) : {};
  }

  final Duration pollInterval;
  Future<String?> cloudAudioId(
    MeetingRecord record,
    MeetingUtterance utterance,
  ) async {
    final owner = _owner(record);
    final response = await client.get(
      'meetings/${Uri.encodeComponent(record.id)}/audio',
      authenticated: true,
      accountId: owner,
    );
    if (accountId != owner) throw const ApiFailure('账户已切换');
    final original = record.utterances
        .where((u) => u.id == utterance.id)
        .firstOrNull;
    if (original == null) return null;
    final hash = sha256.convert(utf8.encode(original.raw)).toString();
    for (final audio in response['data'] as List) {
      if ((audio['sources'] as List).any(
        (s) => s['id'] == original.id && s['hash'] == hash,
      )) {
        return audio['id'];
      }
    }
    return null;
  }

  final _syncBases = <String, (int, Map<String, String>)>{};

  @override
  Future<bool?> isTurnComplete(MeetingRecord record, String text) async {
    final owner = _owner(record);
    final response = await client.post(
      'meetings/turn-end',
      data: {
        'text': text.length > 3000 ? text.substring(text.length - 3000) : text,
      },
      authenticated: true,
      accountId: owner,
    );
    if (accountId != owner) throw const ApiFailure('账户已切换');
    final data = response['data'] as Map;
    final confidence = data['confidence'];
    if (confidence is! num || confidence < .85) return null;
    return switch (data['status']) {
      'complete' => true,
      'continue' => false,
      _ => null,
    };
  }

  @override
  Future<List<MeetingCompletionItem>> completionItems(
    MeetingRecord record,
    List<String> sourceIds,
  ) async {
    final owner = _owner(record);
    final response = await client.get(
      'progress',
      authenticated: true,
      accountId: owner,
    );
    if (accountId != owner) throw const ApiFailure('账户已切换');
    final data = response['data'] as Map;
    final ids = sourceIds.toSet();
    return [
      for (final value in [
        ...(data['pending'] as List? ?? []),
        ...(data['commitments'] as List? ?? []),
      ])
        if ((value['kind'] == null || value['kind'] == 'commitment') &&
            value['evidence']?['sessionId'] == record.id &&
            value['status'] != 'withdrawn' &&
            (ids.isEmpty ||
                ids.contains(value['evidence']?['id']) ||
                (value['sourceEvents'] as List? ?? []).any(
                  (event) =>
                      (event['evidence_ids'] as List? ?? []).any(ids.contains),
                )))
          MeetingCompletionItem.fromJson(Map<String, dynamic>.from(value)),
    ];
  }

  @override
  Future<MeetingCompletionItem> confirmCompletion(
    MeetingRecord record,
    MeetingCompletionItem item, {
    required String side,
    required DateTime deadline,
  }) async {
    final owner = _owner(record);
    final response = await client.post(
      'progress/${item.id}/complete',
      authenticated: true,
      accountId: owner,
      data: {
        'version': item.version,
        'side': side,
        if (item.deadline == null)
          'deadline': deadline.toUtc().toIso8601String(),
        'confirm': true,
        'note': '用户在会议原话下确认履约方和交期',
      },
    );
    if (accountId != owner) throw const ApiFailure('账户已切换');
    final saved = MeetingCompletionItem.fromJson(
      Map<String, dynamic>.from(response['data']),
    );
    if (!saved.confirmed || saved.side == null || saved.deadline == null) {
      throw const ApiFailure('服务端尚未确认，请刷新后重试');
    }
    return saved;
  }

  @override
  String? get accountId => client.accountId?.call();

  @override
  Future<void> updateBusiness(
    MeetingRecord record,
    void Function(Map<String, dynamic>) onUpdate,
  ) async {
    final owner = _owner(record);
    var completed = false;
    await for (final event in client.postEvents(
      'meetings/${Uri.encodeComponent(record.id)}/realtime',
      data: {'revision': record.syncRevision},
      accountId: owner,
    )) {
      if (accountId != owner) throw const ApiFailure('账户已切换');
      if (event['event'] == 'error') throw const ApiFailure('会中业务更新未完成，原话已保存');
      onUpdate(event);
      if (event['event'] == 'done') completed = true;
    }
    if (!completed) throw const ApiFailure('会中业务连接中断，原话已保存');
  }

  @override
  Future<List<Map<String, dynamic>>> readChanges(MeetingRecord record) async {
    final owner = _owner(record);
    final response = await client.get(
      'meetings/${Uri.encodeComponent(record.id)}',
      authenticated: true,
      accountId: owner,
    );
    if (owner != accountId) throw const ApiFailure('账户已切换');
    return (response['data']['sourceChanges'] as List? ?? [])
        .map((v) => Map<String, dynamic>.from(v))
        .toList();
  }

  @override
  Future<void> liveHints(
    MeetingRecord record,
    void Function(Map<String, dynamic>) onUpdate,
  ) async {
    final owner = _owner(record);
    final bounded = _hintSources(record);
    if (bounded.isEmpty) return;
    var completed = false;
    await for (final event in client.postEvents(
      'meetings/live-hints',
      data: {
        'utterances': bounded,
        'include_model': true,
        'output_protocol': 'text_v2',
        'meeting_id': record.id,
      },
      accountId: owner,
    )) {
      if (owner != accountId) throw const ApiFailure('账户已切换');
      if (event['event'] == 'done') completed = true;
      onUpdate(event);
    }
    if (!completed) throw const ApiFailure('会议提示流中断');
  }

  /// 两条只读流使用同一有界来源选择，长会议不反复发送整场转写。
  List<Map<String, dynamic>> _hintSources(MeetingRecord record) {
    final all =
        (meetingSyncPayload(record, paused: false)['utterances'] as List)
            .cast<Map<String, dynamic>>()
            .where((u) => u['turnStatus'] != 'pending')
            .toList();
    // 保留较早的中断和最近发言；不是将整场长会议反复发给模型。
    final selected = <String, Map<String, dynamic>>{};
    final latestText = all.reversed.take(4).map((u) => u['raw']).join('\n');
    if (RegExp(r'接着刚才|接回|回到刚才|继续刚才|刚才').hasMatch(latestText)) {
      const topics = [
        '验收',
        '交付',
        '交期',
        '预算',
        '接口',
        '账号',
        '测试',
        '报告',
        '范围',
        '合同',
        '报价',
      ];
      final mentioned = topics.where(latestText.contains).toList();
      for (final u
          in all
              .take((all.length - 4).clamp(0, all.length))
              .toList()
              .reversed
              .where(
                (u) => mentioned.any(
                  (topic) => (u['raw'] as String).contains(topic),
                ),
              )
              .take(4)) {
        selected[u['id'] as String] = u;
      }
    }
    for (final u
        in all
            .where((u) => u['turnStatus'] == 'interrupted')
            .toList()
            .reversed
            .take(16)) {
      selected[u['id'] as String] = u;
    }
    for (final u in all.reversed.take(16)) {
      selected[u['id'] as String] = u;
    }
    final sources = all.where((u) => selected.containsKey(u['id'])).toList();
    var characters = 0;
    final bounded = <Map<String, dynamic>>[];
    for (final u in sources.reversed) {
      final length =
          (u['raw'] as String).length +
          ((u['correction'] as String?)?.length ?? 0);
      if (characters + length > 12000) continue;
      bounded.insert(0, u);
      characters += length;
    }
    return bounded;
  }

  @override
  Future<void> liveRisks(
    MeetingRecord record,
    void Function(Map<String, dynamic>) onUpdate,
  ) async {
    final owner = _owner(record);
    final sources = _hintSources(record);
    if (sources.isEmpty) return;
    var completed = false;
    await for (final event in client.postEvents(
      'meetings/live-risks',
      data: {'utterances': sources, 'meeting_id': record.id},
      accountId: owner,
    )) {
      if (owner != accountId) throw const ApiFailure('账户已切换');
      onUpdate(event);
      if (event['event'] == 'done') completed = true;
    }
    if (!completed) throw const ApiFailure('会中风险流中断');
  }

  @override
  Future<bool> checkAnalysisConnection() async {
    final owner = accountId;
    if (owner == null) throw const ApiFailure('请重新登录以启用会议AI');
    final result = await client.get(
      'meetings/analysis/capabilities',
      authenticated: true,
      accountId: owner,
    );
    if (owner != accountId) throw const ApiFailure('账户已切换');
    return result['data']['configured'] == true;
  }

  String _owner(MeetingRecord record) {
    final owner = accountId;
    if (owner == null || owner != record.ownerId || record.demo) {
      throw const ApiFailure('当前会议不属于此登录账户，已保留本地记录');
    }
    return owner;
  }

  @override
  Future<void> sync(MeetingRecord record, {required bool paused}) async {
    final owner = _owner(record);
    final key = '$owner:${record.id}';
    final full = meetingSyncPayload(record, paused: paused);
    final all = (full['utterances'] as List).cast<Map<String, dynamic>>();
    String digest(Map<String, dynamic> value) =>
        sha256.convert(utf8.encode(jsonEncode(value))).toString();
    final base = _syncBases[key];
    final delta = base != null && base.$1 < record.syncRevision;
    final payload = delta
        ? <String, dynamic>{
            ...full,
            'baseRevision': base.$1,
            'utterances': [
              for (final u in all)
                if (base.$2[u['id']] != digest(u)) u,
            ],
          }
        : full;
    Map<String, dynamic> response;
    try {
      response = await client.post(
        delta ? 'meetings/sync-delta' : 'meetings/sync',
        data: payload,
        authenticated: true,
        accountId: owner,
      );
    } on ApiFailure catch (error) {
      if ([404, 409].contains(error.status)) _syncBases.remove(key);
      rethrow;
    }
    if (accountId != owner) throw const ApiFailure('账户已切换');
    final saved = response['data'] as Map;
    if (saved['revision'] != record.syncRevision) {
      _syncBases.remove(key);
      throw const ApiFailure('会议云端已有更新，请重新读取后再同步');
    }
    if (saved['deltaSupported'] == true) {
      if (_syncBases.length >= 8 && !_syncBases.containsKey(key)) {
        _syncBases.remove(_syncBases.keys.first);
      }
      _syncBases[key] = (
        record.syncRevision,
        {for (final u in all) u['id'] as String: digest(u)},
      );
    }
  }

  final _submittedJobs = <String, Map<String, dynamic>>{};

  Future<Map<String, dynamic>> _job(
    MeetingRecord record,
    String operation, {
    void Function(Map<String, dynamic>)? onPreview,
  }) async {
    final owner = _owner(record);
    final jobKey = '$owner:${record.id}:${record.syncRevision}:$operation';
    final submitted = _submittedJobs[jobKey] ??= await client.post(
      'meetings/${Uri.encodeComponent(record.id)}/jobs',
      data: {'operation': operation},
      authenticated: true,
      accountId: owner,
    );
    return _poll(
      submitted,
      owner,
      record.syncRevision,
      timeout: Duration(
        minutes: (6 + record.elapsed.inMinutes ~/ 2).clamp(6, 60),
      ),
      onPreview: onPreview,
      onProgress: operation == 'archive'
          ? (job) {
              if (owner == accountId &&
                  job['revision'] == record.syncRevision) {
                _archiveProgress.value = {
                  ...job,
                  'meetingId': record.id,
                  'ownerId': owner,
                };
              }
            }
          : null,
    );
  }

  Future<Map<String, dynamic>> _poll(
    Map<String, dynamic> submitted,
    String owner,
    int revision, {
    Duration timeout = const Duration(minutes: 6),
    void Function(Map<String, dynamic>)? onPreview,
    void Function(Map<String, dynamic>)? onProgress,
  }) async {
    var job = Map<String, dynamic>.from(submitted['data']);
    var consecutiveReadFailures = 0;
    final id = Uri.encodeComponent(job['id'] as String);
    final watch = Stopwatch()..start();
    String? lastPreview;
    void publishPreview() {
      onProgress?.call(job);
      final preview = job['preview'];
      if (owner != accountId ||
          job['revision'] != revision ||
          preview is! Map ||
          !{
            'verified_inference_only',
            'source_checked_inference_only',
            'action_preparation',
          }.contains(preview['kind'])) {
        return;
      }
      final signature = jsonEncode(preview);
      if (signature == lastPreview) return;
      lastPreview = signature;
      onPreview?.call(Map<String, dynamic>.from(preview));
    }

    publishPreview();
    if (job['status'] == 'queued' || job['status'] == 'running') {
      try {
        // 所有任务都由事件唤醒，润色等短任务不再固定等待一个轮询间隔；
        // 断网或旧服务端再回退轮询。
        await for (final event in client.postEvents(
          'meetings/jobs/$id/events',
          data: const {},
          accountId: owner,
        )) {
          if (owner != accountId) throw const ApiFailure('账户已切换');
          if (watch.elapsed > timeout) break;
          if (event['event'] != 'job' || event['data'] is! Map) continue;
          final update = Map<String, dynamic>.from(event['data']);
          if (update['id'] != job['id'] || update['revision'] != revision) {
            throw const ApiFailure('会议分析来源不一致');
          }
          job = update;
          publishPreview();
          if (job['status'] != 'queued' && job['status'] != 'running') break;
        }
      } catch (error) {
        final status = error is ApiFailure
            ? error.status
            : error is DioException
            ? error.response?.statusCode
            : null;
        if (owner != accountId || status == 401 || status == 403) {
          rethrow;
        }
      }
    }
    while (job['status'] == 'queued' || job['status'] == 'running') {
      if (watch.elapsed > timeout) {
        throw const ApiFailure('会议分析仍在处理中，本地记录已保留，请稍后重试');
      }
      await Future<void>.delayed(pollInterval);
      Map<String, dynamic> response;
      try {
        response = await client.get(
          'meetings/jobs/$id',
          authenticated: true,
          accountId: owner,
        );
        consecutiveReadFailures = 0;
      } on ApiFailure catch (error) {
        if (owner != accountId || !_temporaryReadFailure(error)) rethrow;
        if (++consecutiveReadFailures >= 12) {
          throw const ApiFailure('暂时无法查询会议进度，后台任务可能仍在处理，请重新加载查看');
        }
        // The server job continues after a transport failure. Keep its ID and
        // resume reading instead of reporting a failed model execution.
        continue;
      }
      job = Map<String, dynamic>.from(response['data']);
      publishPreview();
    }
    if (job['status'] != 'succeeded' || job['revision'] != revision) {
      _submittedJobs.removeWhere(
        (_, value) => (value['data'] as Map?)?['id'] == job['id'],
      );
      throw ApiFailure(
        job['errorMessage'] as String? ?? '会议分析未完成，本地记录已保留，可稍后重试',
      );
    }
    return Map<String, dynamic>.from(job['result']);
  }

  @override
  Future<String> polish(
    MeetingRecord record,
    MeetingUtterance utterance,
  ) async {
    final owner = _owner(record);
    final submitted = await client.post(
      'meetings/polish',
      data: {'meetingId': record.id, 'id': utterance.id, 'raw': utterance.raw},
      authenticated: true,
      accountId: owner,
    );
    final result = await _poll(submitted, owner, 0);
    final polished = result['polished'] as Map;
    if (polished['id'] != utterance.id ||
        polished['meetingId'] != record.id ||
        polished['rawHash'] !=
            sha256.convert(utf8.encode(utterance.raw)).toString()) {
      throw const ApiFailure('转写整理来源不一致，已保留原话');
    }
    return polished['accepted'] == true
        ? polished['cleaned'] as String
        : utterance.raw;
  }

  @override
  Future<Map<String, dynamic>> analyzeWithUpdates(
    MeetingRecord record,
    void Function(Map<String, dynamic>) onPreview,
  ) async {
    final result = await _job(record, 'analysis', onPreview: onPreview);
    return Map<String, dynamic>.from(result['analysis']);
  }

  @override
  Future<Map<String, dynamic>> analyze(MeetingRecord record) async {
    final result = await _job(record, 'analysis');
    return Map<String, dynamic>.from(result['analysis']);
  }

  @override
  Future<Map<String, dynamic>> archive(MeetingRecord record) =>
      _job(record, 'archive');

  @override
  Future<Map<String, dynamic>?> readArchive(MeetingRecord record) async {
    final owner = _owner(record);
    try {
      final response = await _readWithRetry(
        'meetings/${Uri.encodeComponent(record.id)}/archive',
        owner,
      );
      final result = Map<String, dynamic>.from(response['data']);
      return result['revision'] == record.syncRevision ? result : null;
    } on ApiFailure catch (error) {
      if (error.status == 404) return null;
      rethrow;
    }
  }

  bool _temporaryReadFailure(ApiFailure error) =>
      error.status == null ||
      error.status == 408 ||
      error.status == 429 ||
      (error.status! >= 500);

  Future<Map<String, dynamic>> _readWithRetry(String path, String owner) async {
    for (var attempt = 0; ; attempt++) {
      try {
        return await client.get(path, authenticated: true, accountId: owner);
      } on ApiFailure catch (error) {
        if (owner != accountId ||
            !_temporaryReadFailure(error) ||
            attempt >= 2) {
          rethrow;
        }
        await Future<void>.delayed(pollInterval);
      }
    }
  }

  @override
  Future<List<MeetingRecord>> history() async {
    final owner = accountId;
    if (owner == null) return [];
    final response = await client.get(
      'meetings',
      authenticated: true,
      accountId: owner,
    );
    final records = <MeetingRecord>[];
    for (final value in response['data'] as List) {
      try {
        records.add(_restore(value, owner));
      } on FormatException {
        // A malformed historical row cannot hide unrelated meetings.
      } on TypeError {
        // Recover the requested meeting independently through the detail API.
      }
    }
    return records;
  }

  @override
  Future<MeetingRecord> readMeeting(String id) async {
    final owner = accountId;
    if (owner == null) throw const ApiFailure('请先登录');
    final response = await client.get(
      'meetings/${Uri.encodeComponent(id)}',
      authenticated: true,
      accountId: owner,
    );
    final record = _restore(response['data'], owner);
    if (record.id != id) throw const ApiFailure('会议记录不匹配，请重新加载');
    return record;
  }

  MeetingRecord _restore(dynamic value, String owner) {
    final record = MeetingRecord.fromJson({
      ...Map<String, dynamic>.from(value),
      'ownerId': owner,
      'syncRevision': value['revision'],
      'demo': false,
      'audioPaths': <String>[],
      'utterances': [
        for (final u in value['utterances'] as List)
          if (value['audioSources']?[u['id']] case final Map audio)
            {
              ...Map<String, dynamic>.from(u),
              'audioPath': Uri(
                scheme: 'yanshu-audio',
                path: audio['audioId'],
              ).toString(),
              'audioStart': (audio['start'] as int) * 1000,
              'audioEnd': (audio['end'] as int) * 1000,
            }
          else
            u,
      ],
      'documentId': null,
      'insights': <Object>[],
    });
    return value['analysisRevision'] == value['revision'] &&
            value['analysis'] is Map
        ? applyMeetingAnalysis(record, {
            ...Map<String, dynamic>.from(value['analysis']),
            'source_changes': value['sourceChanges'] ?? [],
          })
        : record;
  }
}

/// 后端建议只改变展示副本；原始转写、音频和人工纠错始终独立保留。
MeetingRecord applyMeetingAnalysis(
  MeetingRecord record,
  Map<String, dynamic> report, {
  bool preserveInferences = false,
}) {
  final ids = record.utterances.map((u) => u.id).toSet();
  bool valid(Object? source) =>
      source is List && source.isNotEmpty && source.every(ids.contains);
  final insights = <String, MeetingInsight>{
    if (preserveInferences)
      for (final i in record.insights)
        if (valid(i.evidenceIds)) i.id: i,
  };
  for (final value
      in report['insights'] is List ? report['insights'] as List : const []) {
    if (value is! Map) continue;
    final item = Map<String, dynamic>.from(value);
    if (item['id'] is! String ||
        item['title'] is! String ||
        item['body'] is! String ||
        !InsightKind.values.any((kind) => kind.name == item['kind'])) {
      continue;
    }
    if (valid(item['evidence_ids'])) {
      try {
        final previous = record.insights
            .where((i) => i.id == item['id'])
            .firstOrNull;
        final anchor =
            previous?.anchorId ??
            (item['anchor_id'] is String &&
                    (item['evidence_ids'] as List).contains(item['anchor_id'])
                ? item['anchor_id'] as String
                : null) ??
            record.utterances
                .where(
                  (u) => (previous?.evidenceIds ?? item['evidence_ids'])
                      .contains(u.id),
                )
                .lastOrNull
                ?.id;
        final insight = MeetingInsight.fromJson({
          ...item,
          'evidenceIds': item['evidence_ids'],
          'anchorId': anchor,
          'inference': true,
        });
        insights[insight.id] = insight;
      } catch (_) {
        // Invalid optional fields affect this suggestion only.
        continue;
      }
    }
  }
  final repairs = <String, SpeechRepair>{
    if (preserveInferences)
      for (final u in record.utterances)
        if (u.repair != null &&
            !u.withdrawn &&
            u.correction == null &&
            valid(u.repair!.evidenceIds))
          u.id: u.repair!,
  };
  // 语义续写与有后文依据的补齐分开接收；后者始终优先。
  for (final value in report['inferred_completions'] as List? ?? []) {
    final item = Map<String, dynamic>.from(value);
    if (item['inferred'] != true || !valid(item['evidence_ids'])) continue;
    final target = record.utterances
        .where((u) => u.id == item['target_id'])
        .firstOrNull;
    if (target == null ||
        target.turnStatus != 'interrupted' ||
        target.withdrawn ||
        target.manual ||
        target.correction != null ||
        (repairs[target.id] != null && !repairs[target.id]!.inferred)) {
      continue;
    }
    if ((item['evidence_ids'] as List).length != 1 ||
        item['evidence_ids'][0] != target.id) {
      continue;
    }
    final marker = [
      '……',
      '...',
      '…',
      '[中断]',
    ].where(target.raw.contains).firstOrNull;
    final start = marker == null
        ? target.raw.length
        : target.raw.indexOf(marker);
    if (item['start'] != start ||
        item['end'] != start + (marker?.length ?? 0)) {
      continue;
    }
    final repair = SpeechRepair.fromJson({
      ...item,
      'evidenceIds': item['evidence_ids'],
    });
    if (repair.validFor(target.raw) && repair.text.trim().isNotEmpty) {
      repairs[target.id] = repair;
    }
  }
  for (final value in report['repairs'] as List? ?? []) {
    final item = Map<String, dynamic>.from(value);
    if (!valid(item['evidence_ids'])) continue;
    final target = record.utterances
        .where((u) => u.id == item['target_id'])
        .firstOrNull;
    final repair = SpeechRepair.fromJson({
      ...item,
      'evidenceIds': item['evidence_ids'],
    });
    if (target != null &&
        target.correction == null &&
        !target.withdrawn &&
        repair.validFor(target.raw)) {
      repairs[target.id] = repair;
    }
  }
  final withdrawn = <String>{};
  for (final value in report['withdrawals'] as List? ?? []) {
    if (valid(value['evidence_ids']) && ids.contains(value['target_id'])) {
      withdrawn.add(value['target_id']);
    }
  }
  return record.copy(
    sourceChanges: report.containsKey('source_changes')
        ? [
            for (final item in report['source_changes'] as List? ?? [])
              if (valid(item['evidence_ids']) &&
                  ids.contains(item['target_id']) &&
                  ids.contains(item['replacement_id']))
                Map<String, dynamic>.from(item),
          ]
        : record.sourceChanges,
    insights: compactMeetingInsights(insights.values, record.utterances),
    commitments: [
      for (final value in report['commitments'] as List? ?? [])
        if (ids.contains(value['origin_id']) &&
            (value['events'] as List? ?? []).isNotEmpty &&
            (value['events'] as List).every(
              (event) => valid(event['evidence_ids']),
            ))
          Map<String, dynamic>.from(value),
    ],
    utterances: [
      for (final item in record.utterances)
        item.revise(
          repair: repairs[item.id],
          clearRepair: !repairs.containsKey(item.id),
          withdrawn: item.withdrawn || withdrawn.contains(item.id),
        ),
    ],
  );
}
