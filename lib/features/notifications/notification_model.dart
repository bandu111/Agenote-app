import 'package:flutter/foundation.dart';
import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../../core/network/api_config.dart';
import 'device_calendar_executor.dart';
import '../progress/models/progress_models.dart';
import '../progress/viewmodels/progress_view_model.dart';

enum NoticeState {
  pending,
  preparing,
  allowed,
  declined,
  completed,
  unavailable,
  cleared,
}

enum NoticeKind { information, action, completion, warning }

/// One immutable, explicitly scoped request; permission never carries to another request.
class ActionNotice {
  const ActionNotice({
    required this.id,
    required this.title,
    required this.instruction,
    this.state = NoticeState.pending,
    this.allowLabel = '允许',
    this.successState = NoticeState.allowed,
    this.kind = NoticeKind.action,
  });
  final String id, title, instruction, allowLabel;
  final NoticeState state;
  final NoticeState successState;
  final NoticeKind kind;
  bool get interrupts =>
      state == NoticeState.pending &&
      (kind == NoticeKind.completion || kind == NoticeKind.warning);
  // 不用标题关键词推断通知级别；同一 ID 内容更新后仍可重新进入收件箱。
  String get inboxVersion => jsonEncode([title, instruction, kind.name]);
}

class NotificationModel extends ChangeNotifier {
  NotificationModel({this.storage, this.readInbox, this.writeInbox});
  final FlutterSecureStorage? storage;
  final Future<String?> Function(String key)? readInbox;
  final Future<void> Function(String key, String value)? writeInbox;
  String? _inboxScope;
  int _inboxGeneration = 0;
  bool _inboxLoading = false;
  bool _restoreFailed = false;
  Future<void> _inboxReady = Future.value();
  Future<void> get inboxReady => _inboxReady;
  final _inboxCache = <String, String>{};
  final _deferredAnnouncements = <String>{};
  final _announced = <String>{};
  String? persistenceError;
  final Map<String, String> _cleared = {};
  final Set<String> _remoteCleared = {};
  final Set<String> _pendingRemoteClears = {};
  Set<String> get pendingRemoteClears => Set.unmodifiable(_pendingRemoteClears);
  void applyRemoteCleared(
    Iterable<String> ids, {
    Iterable<String> synced = const [],
  }) {
    final confirmed = ids.toSet();
    _remoteCleared.addAll(confirmed);
    _pendingRemoteClears.removeAll(synced.where(confirmed.contains));
    if (prompt != null && !_visible(prompt!)) prompt = null;
    _saveCleared();
    _emit();
  }

  final Map<String, String> _invalidated = {};
  Future<void> _write = Future.value();
  Future<void> configureInbox(String? scope) {
    if (_inboxScope == scope && !_restoreFailed) return _inboxReady;
    _inboxScope = scope;
    // 所有来源的消息和操作回调都属于登录账户，不能遗留给下一个账户。
    _items.clear();
    _actions.clear();
    _declines.clear();
    _decisions.clear();
    _errors.clear();
    _busy.clear();
    _initialized = false;
    prompt = null;
    persistenceError = null;
    _restoreFailed = false;
    final generation = ++_inboxGeneration;
    _deferredAnnouncements.clear();
    _announced.clear();
    _cleared.clear();
    _remoteCleared.clear();
    _pendingRemoteClears.clear();
    _invalidated.clear();
    _inboxLoading = scope != null && (storage != null || readInbox != null);
    Future.microtask(() {
      if (!_disposed && generation == _inboxGeneration) {
        if (_progress != null) _sync();
        _emit();
      }
    });
    return _inboxReady = _restoreInbox(scope, generation);
  }

  Future<void> _restoreInbox(String? scope, int generation) async {
    if (scope == null || (storage == null && readInbox == null)) return;
    try {
      // 清空→退出→立即登录时，必须先落完旧账户排队的清除记录。
      await _write;
      if (_disposed || generation != _inboxGeneration) return;
      final key = 'notice-inbox:$scope';
      final value =
          _inboxCache[scope] ??
          await (readInbox?.call(key) ?? storage!.read(key: key));
      if (_disposed || generation != _inboxGeneration || value == null) return;
      final decoded = jsonDecode(value) as Map;
      final structured = const [2, 3, 4, 5].contains(decoded['version']);
      String restoredKey(String id) {
        if (decoded['version'] == 5 ||
            decoded['version'] == 4 ||
            decoded['version'] == 3 &&
                (id.startsWith('progress-pending:') ||
                    id.startsWith('action:task:'))) {
          return id;
        }
        return _inboxKey(id);
      }

      final saved =
          Map<String, String>.from(
            structured ? decoded['cleared'] as Map : decoded,
          ).map((id, version) {
            // 迁移旧记录：服务端 pending/allowed 变化不能让已清除消息复活。
            final parts = jsonDecode(version) as List;
            if (parts.length == 4) parts.removeAt(2);
            // v3 canonicalized tasks, but still stored artifact revisions and
            // assistance fingerprints. Normalize every legacy key on restore.
            return MapEntry(restoredKey(id), jsonEncode(parts));
          });
      _remoteCleared.addAll(
        List<String>.from(decoded['remoteCleared'] ?? const []),
      );
      _pendingRemoteClears.addAll(
        List<String>.from(decoded['pendingRemoteClears'] ?? const []),
      );
      // 旧版本仅保存本机墓碑，升级后补交服务端，防止系统推送再次投递。
      if (decoded['version'] != 5) {
        _remoteCleared.addAll(saved.keys);
        _pendingRemoteClears.addAll(saved.keys);
      }
      // 读取期间发生的清空操作优先。
      _cleared.addAll({...saved, ..._cleared});
      if (structured) {
        _invalidated.addAll({
          ...Map<String, String>.from(
            decoded['invalidated'] as Map,
          ).map((id, value) => MapEntry(restoredKey(id), value)),
          ..._invalidated,
        });
      }
    } catch (_) {
      if (!_disposed && generation == _inboxGeneration) {
        _restoreFailed = true;
        persistenceError = '通知清除记录暂时无法读取，请重试';
      }
    } finally {
      if (!_disposed && generation == _inboxGeneration) {
        _inboxLoading = false;
        if (prompt != null && !_visible(prompt!)) prompt = null;
        final deferred = _deferredAnnouncements.toList();
        _deferredAnnouncements.clear();
        for (final id in deferred) {
          final notice = _items[id];
          if (notice != null) _announce(notice);
        }
        _emit();
      }
    }
  }

  // 审批仍使用完整版本 ID；只有收件箱清除记录使用稳定事项 ID。
  String _inboxKey(String id) {
    if (id.startsWith('progress-pending:') ||
        id.startsWith('action:task:') ||
        id.startsWith('artifact:')) {
      return id.replaceFirst(RegExp(r':\d+$'), '');
    }
    if (id.startsWith('assistance:')) {
      return id.replaceFirst(RegExp(r':[a-f0-9]{64}$'), '');
    }
    return id;
  }

  String deliveryKey(ActionNotice notice) => _inboxKey(notice.id);

  Future<void> flushInbox() => _write;

  void _saveCleared() {
    final scope = _inboxScope;
    if (_restoreFailed ||
        scope == null ||
        (storage == null && writeInbox == null)) {
      return;
    }
    final value = jsonEncode({
      'version': 5,
      'remoteCleared': _remoteCleared.toList(),
      'pendingRemoteClears': _pendingRemoteClears.toList(),
      'cleared': _cleared,
      'invalidated': _invalidated,
    });
    _inboxCache[scope] = value;
    persistenceError = null;
    _write = _write.then((_) async {
      try {
        final key = 'notice-inbox:$scope';
        await (writeInbox?.call(key, value) ??
            storage!.write(key: key, value: value));
        if (!_disposed && _inboxScope == scope) persistenceError = null;
      } catch (_) {
        if (!_disposed && _inboxScope == scope) {
          persistenceError = '通知已隐藏，但清除记录未能保存，请重试清空';
          _emit();
        }
      }
    });
  }

  bool _visible(ActionNotice n) =>
      !_inboxLoading &&
      !_restoreFailed &&
      !_remoteCleared.contains(_inboxKey(n.id)) &&
      !(n.id.startsWith('progress-pending:confirm-') &&
          n.state == NoticeState.unavailable &&
          _cleared.containsKey(_inboxKey(n.id))) &&
      _cleared[_inboxKey(n.id)] != n.inboxVersion;
  NoticeState? stateOf(String id) {
    final notice = _items[id];
    if (notice == null) return null;
    if (_visible(notice)) return notice.state;
    return (_invalidated.containsKey(_inboxKey(id)) &&
                notice.state == NoticeState.pending) ||
            _invalidated[_inboxKey(id)] == notice.inboxVersion
        ? NoticeState.unavailable
        : NoticeState.cleared;
  }

  bool get canClear =>
      !_restoreFailed && (items.isNotEmpty || persistenceError != null);

  /// 清空整个收件箱，不批准、拒绝或取消已经开始的业务操作。
  int clearAll() {
    var count = 0;
    for (final n in items) {
      _cleared[_inboxKey(n.id)] = n.inboxVersion;
      _remoteCleared.add(_inboxKey(n.id));
      _pendingRemoteClears.add(_inboxKey(n.id));
      if (n.state == NoticeState.pending ||
          n.state == NoticeState.preparing ||
          busy(n.id)) {
        _invalidated[_inboxKey(n.id)] = n.inboxVersion;
      }
      _errors.remove(n.id);
      count++;
      if (prompt?.id == n.id) prompt = null;
    }
    _saveCleared();
    _emit();
    return count;
  }

  /// 知悉只清理显示，不调用授权、拒绝或执行回调。
  void acknowledge(String id) {
    final n = _items[id];
    if (n == null || n.interrupts || busy(id)) return;
    _cleared[_inboxKey(id)] = n.inboxVersion;
    _errors.remove(id);
    if (prompt?.id == id) prompt = null;
    _saveCleared();
    _emit();
  }

  void postpone(String id) {
    final n = _items[id];
    if (n == null || busy(id)) return;
    _cleared[_inboxKey(id)] = n.inboxVersion;
    if (prompt?.id == id) prompt = null;
    _saveCleared();
    _emit();
  }

  Future<bool?> Function(PendingProgressItem)? onCompleteProgress;
  final Map<String, ActionNotice> _items = {};
  final Map<String, Future<bool> Function()> _actions = {};
  final Map<String, Future<bool> Function()> _declines = {};
  final Map<String, NoticeState> _decisions = {};
  final Set<String> _busy = {};
  final Map<String, String> _errors = {};
  bool _initialized = false, _disposed = false;
  ActionNotice? prompt;
  int promptRevision = 0;
  ProgressViewModel? _progress;
  int _progressScope = 0;
  bool get loading => _inboxLoading || (_progress?.loading ?? false);
  String? get loadError => _restoreFailed ? persistenceError : _progress?.error;
  Future<void> refresh() async {
    if (_restoreFailed) await configureInbox(_inboxScope);
    await _progress?.load();
  }

  List<ActionNotice> get items => _items.values.where(_visible).toList()
    ..sort(
      (a, b) =>
          (a.interrupts
                  ? 0
                  : a.state == NoticeState.pending
                  ? 1
                  : 2)
              .compareTo(
                b.interrupts
                    ? 0
                    : b.state == NoticeState.pending
                    ? 1
                    : 2,
              ),
    );
  int get pendingCount =>
      _items.values.where((n) => _visible(n) && n.interrupts).length;
  bool busy(String id) => _busy.contains(id);
  String? error(String id) => _errors[id];

  void bind(ProgressViewModel progress) {
    if (identical(progress, _progress)) return;
    _progress?.removeListener(_sync);
    _progress = progress..addListener(_sync);
    _sync();
  }

  void _sync() {
    final progress = _progress!;
    if (_progressScope != progress.accountScopeRevision) {
      _progressScope = progress.accountScopeRevision;
      for (final id
          in _items.keys
              .where(
                (id) =>
                    id.startsWith('artifact:') ||
                    id.startsWith('progress-pending:'),
              )
              .toList()) {
        _items.remove(id);
        _actions.remove(id);
        _decisions.remove(id);
        _errors.remove(id);
        _busy.remove(id);
      }
      if (prompt?.id.startsWith('artifact:') == true ||
          prompt?.id.startsWith('progress-pending:') == true) {
        prompt = null;
      }
    }
    if (progress.loading || progress.error != null) {
      _emit();
      return;
    }
    final previous = Map<String, ActionNotice>.from(_items);
    final currentIds = <String>{};
    for (final artifact in progress.data.artifacts) {
      final id = 'artifact:${artifact.id}:${artifact.version}';
      currentIds.add(id);
      final state = switch (artifact.status) {
        ArtifactStatus.confirmation => _decisions[id] ?? NoticeState.pending,
        ArtifactStatus.preparing => NoticeState.preparing,
        ArtifactStatus.failed ||
        ArtifactStatus.expired => NoticeState.unavailable,
        _ => NoticeState.completed,
      };
      final notice = ActionNotice(
        id: id,
        title: artifact.status == ArtifactStatus.confirmation
            ? '确认《${artifact.title}》'
            : artifact.title,
        instruction: artifact.status == ArtifactStatus.confirmation
            ? '将这份成果标记为已确认。'
            : state == NoticeState.preparing
            ? '准备完成后会通知你。'
            : '无需操作。',
        state: state,
        allowLabel: '确认',
      );
      _items[id] = notice;
      _actions[id] = () async {
        final latest = progress.artifact(artifact.id);
        // Recheck the exact version and content before consuming consent.
        if (latest == null ||
            latest.version != artifact.version ||
            latest.content != artifact.content ||
            latest.status != ArtifactStatus.confirmation) {
          return false;
        }
        return progress.approveArtifact(artifact.id, '用户在通知中确认当前版本');
      };
      if (_initialized &&
          state == NoticeState.pending &&
          previous[id]?.state != NoticeState.pending) {
        _announce(notice);
      }
    }
    for (final item in progress.data.pending) {
      if (item.reviewPending || (!item.needsSide && !item.needsDeadline)) {
        continue;
      }
      final id = 'progress-pending:${item.id}:${item.version}';
      currentIds.add(id);
      final notice = ActionNotice(
        id: id,
        title: '补全：${item.title}',
        state:
            item.expiredByClear ||
                item.deadline != null && !item.deadline!.isAfter(DateTime.now())
            ? NoticeState.unavailable
            : NoticeState.pending,
        instruction: [
          if (item.needsSide) '选择我方或对方履约项',
          if (item.needsDeadline) '补充交期',
        ].join('，'),
        allowLabel: '补全',
        kind: NoticeKind.completion,
      );
      _items[id] = notice;
      _actions[id] = () async {
        if (!progress.data.pending.any(
          (p) =>
              !p.reviewPending && p.id == item.id && p.version == item.version,
        )) {
          return false;
        }
        final result = await onCompleteProgress?.call(item);
        if (result == null || result == false) throw const NoticeCancelled();
        return true;
      };
      if (!_initialized) _announced.add(_inboxKey(id));
      if (_initialized &&
          !previous.values.any(
            (old) =>
                _inboxKey(old.id) == _inboxKey(id) &&
                old.inboxVersion == notice.inboxVersion,
          )) {
        _announce(notice);
      }
    }
    for (final item in progress.data.commitments) {
      if (item.status != CommitmentStatus.pending ||
          item.reviewPending ||
          progress.data.pending.any(
            (p) => p.id == item.id && p.reviewPending,
          )) {
        continue;
      }
      final id = 'progress-pending:confirm-${item.id}:${item.version}';
      currentIds.add(id);
      final expired = item.statusAt(DateTime.now()) == CommitmentStatus.overdue;
      _items[id] = ActionNotice(
        id: id,
        title: '${expired ? '已逾期' : '确认承诺'}：${item.title}',
        instruction: expired ? '交期已过，请在承诺详情核对或调整安排' : '履约信息已完整，请明确确认承诺成立',
        allowLabel: '确认承诺',
        kind: NoticeKind.completion,
        state: expired
            ? NoticeState.unavailable
            : (_decisions[id] ?? NoticeState.pending),
      );
      _actions[id] = () async {
        final current = progress.commitment(item.id);
        if (current == null ||
            current.status != CommitmentStatus.pending ||
            !progress.canConfirm(current) ||
            current.confirmationKey != item.confirmationKey ||
            current.deadline != item.deadline ||
            current.statusAt(DateTime.now()) == CommitmentStatus.overdue) {
          return false;
        }
        return progress.confirmCommitment(item);
      };
      if (!_initialized) _announced.add(_inboxKey(id));
      if (_initialized && !previous.containsKey(id)) _announce(_items[id]!);
    }
    for (final id in previous.keys.where(
      (id) =>
          (id.startsWith('artifact:') || id.startsWith('progress-pending:')) &&
          !currentIds.contains(id),
    )) {
      _items.remove(id);
      _actions.remove(id);
      _declines.remove(id);
      _decisions.remove(id);
      _busy.remove(id);
      _errors.remove(id);
    }
    if (prompt != null && _items[prompt!.id]?.state != NoticeState.pending) {
      prompt = null;
    }
    _initialized = true;
    _emit();
  }

  /// Future backend events use the same global inbox and prompt surface.
  void receive(
    ActionNotice notice, {
    required Future<bool> Function() onAllow,
    Future<bool> Function()? onDecline,
    bool announce = true,
  }) {
    if (_disposed ||
        _busy.contains(notice.id) ||
        _decisions.containsKey(notice.id)) {
      return;
    }
    final previous = _items[notice.id];
    _items[notice.id] = notice;
    if (prompt?.id == notice.id && !notice.interrupts) prompt = null;
    if (notice.state != NoticeState.pending) _errors.remove(notice.id);
    _actions[notice.id] = onAllow;
    if (onDecline != null) _declines[notice.id] = onDecline;
    if (!announce && notice.interrupts) _announced.add(_inboxKey(notice.id));
    if (announce &&
        notice.state == NoticeState.pending &&
        (previous?.state != NoticeState.pending ||
            previous?.inboxVersion != notice.inboxVersion)) {
      _announce(notice);
    }
    _emit();
  }

  void _announce(ActionNotice notice) {
    if (_inboxLoading) {
      if (notice.interrupts) _deferredAnnouncements.add(notice.id);
      return;
    }
    if (!notice.interrupts || !_visible(notice)) return;
    if (!_announced.add(_inboxKey(notice.id))) return;
    prompt = notice;
    promptRevision++;
  }

  void dismissPrompt() {
    prompt = null;
    _emit();
  }

  void clearActionNotices() {
    for (final id
        in _items.keys.where((id) => id.startsWith('action:')).toList()) {
      _items.remove(id);
      _actions.remove(id);
      _declines.remove(id);
      _decisions.remove(id);
      _errors.remove(id);
      _busy.remove(id);
      if (prompt?.id == id) prompt = null;
    }
    _emit();
  }

  /// 删除旧版本任务提示，不让用户批准已变化的任务。
  void syncTaskIds(Set<String> current) {
    for (final id
        in _items.keys
            .where(
              (id) => id.startsWith('action:task:') && !current.contains(id),
            )
            .toList()) {
      if (_busy.contains(id)) continue;
      _items.remove(id);
      _actions.remove(id);
      _declines.remove(id);
      _decisions.remove(id);
      _errors.remove(id);
      if (prompt?.id == id) prompt = null;
    }
    _emit();
  }

  void syncAssistanceIds(Set<String> current) {
    for (final id
        in _items.keys
            .where(
              (id) => id.startsWith('assistance:') && !current.contains(id),
            )
            .toList()) {
      _items.remove(id);
      _actions.remove(id);
      _declines.remove(id);
      _decisions.remove(id);
      _errors.remove(id);
      _busy.remove(id);
      if (prompt?.id == id) prompt = null;
    }
    _emit();
  }

  /// 账户退出时仅移除会议产生的私有提示，避免进入下一个账户。
  void clearMeetingNotices() {
    final ids = _items.keys
        .where(
          (id) =>
              id.startsWith('meeting:') || id.startsWith('meeting-calendar:'),
        )
        .toList();
    for (final id in ids) {
      _items.remove(id);
      _actions.remove(id);
      _declines.remove(id);
      _decisions.remove(id);
      _busy.remove(id);
      _errors.remove(id);
    }
    if (ids.contains(prompt?.id)) prompt = null;
    _emit();
  }

  Future<bool> decide(String id, {required bool allow}) async {
    final generation = _inboxGeneration;
    final notice = _items[id];
    if (_disposed ||
        notice == null ||
        !_visible(notice) ||
        notice.state != NoticeState.pending ||
        _busy.contains(id)) {
      return false;
    }
    _errors.remove(id);
    if (!allow) {
      if (_declines.containsKey(id)) {
        _busy.add(id);
        _emit();
        try {
          if (await _declines[id]!() != true) return false;
          if (generation != _inboxGeneration || !_items.containsKey(id)) {
            return false;
          }
          _settle(notice, NoticeState.declined);
          return true;
        } on ApiFailure catch (error) {
          if (generation == _inboxGeneration) _errors[id] = error.message;
          return false;
        } catch (_) {
          if (generation == _inboxGeneration) _errors[id] = '操作未完成，请重试';
          return false;
        } finally {
          if (generation == _inboxGeneration) _busy.remove(id);
          _emit();
        }
      }
      if (id.startsWith('progress-pending:')) {
        if (prompt?.id == id) prompt = null;
        _emit();
        return true;
      }
      _settle(notice, NoticeState.declined);
      return true;
    }
    _busy.add(id);
    _emit();
    try {
      if (await _actions[id]?.call() != true) {
        throw StateError('request failed');
      }
      if (_disposed || generation != _inboxGeneration) {
        return false;
      }
      // 业务回读可能已移除完成的请求，不把真实成功误报成失败。
      if (!_items.containsKey(id)) return true;
      _settle(notice, notice.successState);
      return true;
    } on NoticeCancelled {
      return false;
    } on CalendarExecutionFailure catch (error) {
      if (!_disposed && generation == _inboxGeneration) {
        _errors[id] = error.message;
      }
      return false;
    } on ApiFailure catch (error) {
      if (!_disposed && generation == _inboxGeneration) {
        _errors[id] = error.message;
      }
      return false;
    } catch (_) {
      if (!_disposed && generation == _inboxGeneration) {
        _errors[id] = '操作未完成，请重试';
      }
      return false;
    } finally {
      if (generation == _inboxGeneration) _busy.remove(id);
      _emit();
    }
  }

  void _settle(ActionNotice notice, NoticeState state) {
    _decisions[notice.id] = state;
    _items[notice.id] = ActionNotice(
      id: notice.id,
      title: notice.title,
      instruction: notice.instruction,
      allowLabel: notice.allowLabel,
      state: state,
      kind: notice.kind,
      successState: notice.successState,
    );
    if (prompt?.id == notice.id) prompt = null;
    _emit();
  }

  void _emit() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _progress?.removeListener(_sync);
    super.dispose();
  }
}

class NoticeCancelled implements Exception {
  const NoticeCancelled();
}
