import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import '../knowledge/models/knowledge_models.dart';
import 'meeting_models.dart';
import 'meeting_remote.dart';
import 'meeting_store.dart';
import '../../core/network/api_config.dart';

/// The audio anchor survives delayed or replaced transcript segments.
Map<String, dynamic> questionAssociation(
  Map<String, dynamic> content,
  MeetingRecord record,
) {
  final part = content['part'];
  final sample = content['sample'] as int?;
  final at = content['atMs'] as int;
  final candidates = record.utterances.where(
    (u) =>
        !u.withdrawn &&
        (part == null || u.audioPath?.split(RegExp(r'[/\\]')).last == part),
  );
  // A cloud-restored record has audio IDs instead of the original local filename.
  // Keep its validated links; do not erase them merely because this is another device.
  if (part != null && candidates.isEmpty && record.audioPaths.isEmpty) {
    final valid = record.utterances
        .where((u) => !u.withdrawn)
        .map((u) => u.id)
        .toSet();
    return {
      ...content,
      'sourceIds': [
        for (final id in content['sourceIds'] as List? ?? [])
          if (valid.contains(id)) id,
      ],
    };
  }
  MeetingUtterance? nearest;
  var distance = 1 << 60;
  var exact = false;
  for (final u in candidates) {
    final point = sample == null ? at : sample * 1000 ~/ 16000;
    final end = sample == null
        ? u.at.inMilliseconds
        : u.audioEnd?.inMilliseconds;
    final start = sample == null
        ? (u.hasAudio
              ? u.at.inMilliseconds -
                    (u.audioEnd! - u.audioStart!).inMilliseconds
              : end)
        : u.audioStart?.inMilliseconds;
    if (start == null || end == null) continue;
    final inside = point >= start && point <= end;
    final gap = inside
        ? 0
        : point > end
        ? point - end
        : start - point;
    // A short silence normally refers to what was just heard.
    if (gap < distance || (gap == distance && point >= end)) {
      nearest = u;
      distance = gap;
      exact = inside && u.hasAudio;
    }
  }
  return {
    ...content,
    'sourceIds': nearest != null && distance <= 5000
        ? [nearest.id]
        : <String>[],
    'association': nearest == null || distance > 5000
        ? 'none'
        : exact
        ? 'exact'
        : 'nearby',
  };
}

/// One shared repository for the recording page and archived minutes.
/// Files are separate from MeetingRecord so ASR snapshots cannot erase edits.
class MeetingQuestions extends ChangeNotifier {
  MeetingQuestions(this.meetingStore, this.remote);
  final MeetingStore meetingStore;
  final MeetingRemoteRepository? remote;
  final _records = <String, List<Map<String, dynamic>>>{};
  final _loads = <String, Future<void>>{};
  final _syncing = <String>{};
  final _syncWorks = <String, Future<bool>>{};
  final _analyzing = <String>{};
  final _lastSync = <String, DateTime>{};
  final _forgotten = <String>{};
  final _meetings = <String, MeetingRecord>{};
  Future<void> _writes = Future.value();
  Timer? _retry;
  bool _disposed = false;
  String? error;
  int revision = 0;
  String _scope(MeetingRecord r) => '${r.ownerId ?? ''}:${r.id}';
  MeetingRecord latest(MeetingRecord r) => _meetings[_scope(r)] ?? r;
  bool _current(MeetingRecord r) =>
      !_disposed &&
      !_forgotten.contains(_scope(r)) &&
      (r.ownerId == null || remote?.accountId == r.ownerId);
  List<Map<String, dynamic>> items(MeetingRecord r) =>
      !_current(r)
            ? []
            : (_records[_scope(r)] ?? [])
                  .where((q) => q['content']['deleted'] != true)
                  .toList()
        ..sort(
          (a, b) => (a['content']['atMs'] as int).compareTo(
            b['content']['atMs'] as int,
          ),
        );
  Map<String, dynamic>? item(MeetingRecord r, String id) =>
      items(r).where((q) => q['id'] == id).firstOrNull;
  void _emit() {
    if (!_disposed) {
      revision++;
      notifyListeners();
    }
  }

  Future<File?> _file(MeetingRecord r) async {
    if (meetingStore is! LocalMeetingStore) return null;
    final root =
        (meetingStore as LocalMeetingStore).directory ??
        await getApplicationSupportDirectory();
    final folder = Directory('${root.path}/meeting-questions');
    await folder.create(recursive: true);
    return File('${folder.path}/${knowledgeHash(_scope(r))}.json');
  }

  Future<void> _save(MeetingRecord r) {
    final snapshot = jsonEncode(_records[_scope(r)] ?? []);
    final next = _writes.catchError((Object _) {}).then((_) async {
      final file = await _file(r);
      if (file == null) return;
      final temp = File('${file.path}.tmp');
      final backup = File('${file.path}.backup');
      await temp.writeAsString(snapshot, flush: true);
      if (await file.exists()) {
        if (await backup.exists()) await backup.delete();
        await file.rename(backup.path);
      }
      try {
        await temp.rename(file.path);
      } catch (_) {
        if (await backup.exists()) await backup.rename(file.path);
        rethrow;
      }
    });
    _writes = next;
    return next;
  }

  Future<void> load(MeetingRecord r) async {
    if (!_current(r)) return;
    final scope = _scope(r);
    final previous = _meetings[scope];
    if (previous == null ||
        (r.syncRevision >= previous.syncRevision &&
            (!previous.ended || r.ended) &&
            r.utterances.length >= previous.utterances.length)) {
      _meetings[scope] = r;
    }
    try {
      await (_loads[scope] ??= () async {
        final file = await _file(r);
        final backup = file == null ? null : File('${file.path}.backup');
        var rows = <Map<String, dynamic>>[];
        Object? failure;
        for (final source in [file, backup]) {
          if (source == null || !await source.exists()) continue;
          try {
            rows = [
              for (final q in jsonDecode(await source.readAsString()) as List)
                Map<String, dynamic>.from(q),
            ];
            failure = null;
            break;
          } catch (e) {
            failure = e;
          }
        }
        if (failure != null) throw StateError('疑问记录读取失败，请保留本机数据后重试');
        if (!_current(r)) return;
        _records[scope] = rows;
        _emit();
      }());
    } catch (_) {
      _loads.remove(scope);
      error = '疑问记录暂时无法读取，请重试';
      _emit();
      rethrow;
    }
    if (!_current(r)) return;
    if (remote is DioMeetingRepository && !r.demo) {
      _retry ??= Timer.periodic(const Duration(seconds: 15), (_) {
        for (final record in _meetings.values.toList()) {
          if (_current(record)) {
            unawaited(() async {
              await sync(record);
              if (record.ended &&
                  record.cloudMinutes != null &&
                  items(record).any(
                    (q) =>
                        q['analysisDue'] == true &&
                        q['content']['status'] == 'pending',
                  )) {
                await afterArchive(record);
              }
            }());
          }
        }
      });
    }
    unawaited(sync(r));
  }

  Future<void> _write(MeetingRecord r, Map<String, dynamic> q) async {
    if (!_current(r)) throw StateError('账户已切换');
    final list = _records[_scope(r)] ??= [];
    final index = list.indexWhere((v) => v['id'] == q['id']);
    if (index < 0) {
      list.add(q);
    } else {
      list[index] = q;
    }
    _emit();
    try {
      await _save(r);
    } catch (_) {
      error = '疑问尚未保存，请保留页面并重试';
      _emit();
      rethrow;
    }
  }

  Future<String> create(
    MeetingRecord r, {
    required int atMs,
    String? part,
    int? sample,
  }) async {
    await load(r);
    final id = knowledgeId();
    await _write(r, {
      'id': id,
      'version': 0,
      'mutationId': knowledgeId(),
      'pending': true,
      'analysisDue': true,
      'content': questionAssociation({
        'atMs': atMs,
        'part': part,
        'sample': sample,
        'text': '',
        'status': 'pending',
        'deleted': false,
        'sourceIds': <String>[],
        'association': 'none',
      }, r),
    });
    unawaited(sync(r));
    return id;
  }

  Future<void> edit(
    MeetingRecord r,
    String id, {
    String? text,
    String? status,
    bool deleted = false,
  }) async {
    final q = item(r, id);
    if (q == null) return;
    final content = Map<String, dynamic>.from(q['content']);
    if (text != null) content['text'] = text.trim();
    if (status != null) content['status'] = status;
    content['deleted'] = deleted;
    if (jsonEncode(content) == jsonEncode(q['content'])) {
      // A previous failed disk write must still be retryable.
      await _save(r);
      return;
    }
    final latest = _meetings[_scope(r)] ?? r;
    await _write(r, {
      ...q,
      'mutationId': knowledgeId(),
      'pending': true,
      'analysisDue': !latest.ended || latest.cloudMinutes == null,
      'content': content,
      if (q['analysis'] != null)
        'analysis': {
          ...Map<String, dynamic>.from(q['analysis']),
          'stale': true,
        },
    });
    unawaited(sync(r));
  }

  Future<void> associate(MeetingRecord r) async {
    if (!_current(r)) return;
    await load(r);
    r = latest(r);
    for (final initial in items(r)) {
      final q = item(r, initial['id']);
      if (q == null) continue;
      final content = questionAssociation(
        Map<String, dynamic>.from(q['content']),
        r,
      );
      if (jsonEncode(content) != jsonEncode(q['content'])) {
        await _write(r, {
          ...q,
          'content': content,
          'mutationId': knowledgeId(),
          'pending': true,
          'analysisDue': true,
          if (q['analysis'] != null)
            'analysis': {
              ...Map<String, dynamic>.from(q['analysis']),
              'stale': true,
            },
        });
      }
    }
    unawaited(sync(r));
  }

  String _path(MeetingRecord r) =>
      'meetings/${Uri.encodeComponent(r.id)}/questions';
  Future<bool> sync(MeetingRecord r) {
    final scope = _scope(r);
    final running = _syncWorks[scope];
    if (running != null) return running;
    final work = _sync(r);
    _syncWorks[scope] = work;
    return work.whenComplete(() => _syncWorks.remove(scope));
  }

  Future<bool> _sync(MeetingRecord r) async {
    if (!_current(r) || r.demo || remote is! DioMeetingRepository) return false;
    final scope = _scope(r);
    if (_syncing.contains(scope) || !_records.containsKey(scope)) return false;
    if (!_records[scope]!.any((q) => q['pending'] == true) &&
        DateTime.now()
                .difference(_lastSync[scope] ?? DateTime(2000))
                .inSeconds <
            30) {
      return true;
    }
    final client = (remote as DioMeetingRepository).client;
    _syncing.add(scope);
    try {
      for (final initial in List<Map<String, dynamic>>.of(_records[scope]!)) {
        var q = _records[scope]!.where((v) => v['id'] == initial['id']).first;
        if (q['pending'] != true || q['conflict'] != null) continue;
        final sent = q;
        final response = await client.post(
          '${_path(r)}/${q['id']}/save',
          authenticated: true,
          accountId: r.ownerId,
          data: {
            'baseVersion': q['version'],
            'mutationId': q['mutationId'],
            'content': q['content'],
          },
        );
        if (!_current(r)) return false;
        final saved = Map<String, dynamic>.from(response['data']);
        q = _records[scope]!.where((v) => v['id'] == sent['id']).first;
        await _write(
          r,
          q['mutationId'] == sent['mutationId']
              ? {
                  ...saved,
                  'pending': false,
                  'analysisDue': q['analysisDue'] == true,
                }
              : {...q, 'version': saved['version']},
        );
      }
      final response = await client.get(
        _path(r),
        authenticated: true,
        accountId: r.ownerId,
      );
      if (!_current(r)) return false;
      for (final value in response['data'] as List) {
        final saved = Map<String, dynamic>.from(value);
        final local = _records[scope]!
            .where((v) => v['id'] == saved['id'])
            .firstOrNull;
        if (local?['pending'] == true) continue;
        await _write(r, {
          ...saved,
          'pending': false,
          'analysisDue': local?['analysisDue'] == true,
        });
      }
      error = null;
      _lastSync[scope] = DateTime.now();
      _emit();
      return !(_records[scope]!.any((q) => q['pending'] == true));
    } on ApiFailure catch (failure) {
      if (_current(r) && failure.status == 409) {
        try {
          final response = await client.get(
            _path(r),
            authenticated: true,
            accountId: r.ownerId,
          );
          if (!_current(r)) return false;
          for (final value in response['data'] as List) {
            final saved = Map<String, dynamic>.from(value);
            final local = _records[scope]!
                .where((q) => q['id'] == saved['id'])
                .firstOrNull;
            if (local?['pending'] == true &&
                local!['version'] != saved['version']) {
              await _write(r, {...local, 'conflict': saved});
            }
          }
        } catch (_) {
          /* Keep local edits until reconciliation is available. */
        }
      }
      if (_current(r)) {
        error = '疑问已保存在本机，同步待重试';
        _emit();
      }
      return false;
    } catch (failure, stack) {
      debugPrint('meeting_question_sync_failed: ${failure.runtimeType}\n$stack');
      if (_current(r)) {
        error = '疑问已保存在本机，联网后重试；若云端有更新，请先处理冲突';
        _emit();
      }
      return false;
    } finally {
      _syncing.remove(scope);
    }
  }

  Future<void> analyze(
    MeetingRecord r, {
    String? id,
    bool suggest = false,
    bool automatic = false,
  }) async {
    if (!_current(r) || r.demo || remote is! DioMeetingRepository) {
      throw StateError('请连接账户网络后使用 AI');
    }
    await load(r);
    final scope = _scope(r);
    if (_analyzing.contains(scope)) throw StateError('疑问分析正在进行，请稍后重试');
    if (automatic &&
        (!r.ended || !r.canGenerateMinutes || r.cloudMinutes == null)) {
      return;
    }
    final selected = items(r)
        .where(
          (q) =>
              q['content']['status'] != 'resolved' &&
              (id == null || q['id'] == id) &&
              (!automatic || q['analysisDue'] == true),
        )
        .map((q) => q['id'])
        .toList();
    if (selected.isEmpty) return;
    _analyzing.add(scope);
    try {
      if (!await sync(r)) throw StateError('请等待会议原文和疑问同步完成后重试');
      final client = (remote as DioMeetingRepository).client;
      final response = await client.post(
        suggest ? '${_path(r)}/$id/suggest' : '${_path(r)}/analyze',
        authenticated: true,
        accountId: r.ownerId,
        receiveTimeout: const Duration(minutes: 5),
        data: suggest ? const {} : {'ids': selected},
      );
      if (!_current(r)) return;
      for (final value
          in suggest ? [response['data']] : response['data'] as List) {
        final saved = Map<String, dynamic>.from(value);
        final local = item(r, saved['id']);
        if (local == null ||
            local['pending'] == true ||
            local['mutationId'] != saved['mutationId']) {
          continue;
        }
        await _write(r, {
          ...saved,
          'pending': false,
          'analysisDue': suggest ? local['analysisDue'] : false,
        });
      }
      error = null;
    } finally {
      _analyzing.remove(scope);
      _emit();
    }
  }

  Future<void> afterArchive(MeetingRecord r) async {
    try {
      await associate(r);
      await analyze(r, automatic: true);
    } catch (_) {
      if (_current(r)) {
        error = '纪要已归档，疑问分析稍后重试';
        _emit();
      }
    }
  }

  /// Resume existing local outboxes after app restart, even if another meeting is open.
  Future<void> resumePending(List<MeetingRecord> records) async {
    for (final record in records) {
      if (!_current(record)) continue;
      try {
        final file = await _file(record);
        if (file != null && (await file.exists() || await File('${file.path}.backup').exists())) {
          await associate(record);
        }
      } catch (_) { /* A damaged question file must not block meeting history. */ }
    }
  }

  Future<void> resolveConflict(
    MeetingRecord r,
    String id, {
    required bool keepLocal,
  }) async {
    final local = item(r, id);
    final cloud = local?['conflict'];
    if (local == null || cloud is! Map) return;
    if (keepLocal) {
      final next = {
        ...local,
        'version': cloud['version'],
        'mutationId': knowledgeId(),
        'pending': true,
      };
      next.remove('conflict');
      await _write(r, next);
    } else {
      await _write(r, {
        ...Map<String, dynamic>.from(cloud),
        'pending': false,
        'analysisDue': false,
      });
    }
    unawaited(sync(r));
  }

  Future<void> forget(MeetingRecord r) async {
    final scope = _scope(r);
    _forgotten.add(scope);
    _meetings.remove(scope);
    _records[scope] = [];
    await _save(r);
    // Replace the recovery copy too, so deleted questions cannot reappear.
    await _save(r);
    _emit();
  }

  @override
  void dispose() {
    _disposed = true;
    _retry?.cancel();
    super.dispose();
  }
}
