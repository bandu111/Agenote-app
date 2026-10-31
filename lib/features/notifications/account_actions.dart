import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import '../../core/network/api_client.dart';
import '../../core/network/api_config.dart';
import 'device_calendar_executor.dart';
import 'notification_model.dart';

/// 全局行动沿用现有通知外观，只增加正式服务端状态和原生日历执行。
class AccountActions extends ChangeNotifier {
  AccountActions(
    this.client,
    this.notifications, {
    DeviceCalendarExecutor? executor,
    this.onChanged,
  }) : executor =
           executor ??
           DeviceCalendarExecutor(namespace: client.dio.options.baseUrl);
  final ApiClient client;
  final NotificationModel notifications;
  final DeviceCalendarExecutor executor;
  final Future<void> Function()? onChanged;
  String? _owner;
  final Map<String, String> _toolStates = {};
  bool _disposed = false, _loading = false;
  Timer? _timer;
  int _failures = 0;
  int malformedItems = 0;
  String? error;
  void _schedule() {
    _timer?.cancel();
    if (_disposed || _owner == null) return;
    final seconds = [15, 30, 60, 120][_failures.clamp(0, 3)];
    _timer = Timer(Duration(seconds: seconds), () async {
      await refresh();
    });
  }

  void refreshAccount() {
    final owner = client.accountId?.call();
    if (_owner == owner) return;
    _owner = owner;
    unawaited(
      notifications.configureInbox(
        owner == null ? null : '${client.dio.options.baseUrl}:$owner',
      ),
    );
    _toolStates.clear();
    _failures = 0;
    malformedItems = 0;
    error = null;
    Future.microtask(() {
      if (!_disposed) notifications.clearActionNotices();
    });
    _timer?.cancel();
    if (owner != null) {
      Future.microtask(refresh);
      _schedule();
    }
  }

  Future<void> refresh() async {
    final owner = _owner;
    if (_disposed || owner == null || _loading) return;
    _loading = true;
    malformedItems = 0;
    try {
      await notifications.inboxReady;
      if (_disposed || owner != _owner || owner != client.accountId?.call()) {
        return;
      }
      final response = await client.get(
        'actions?includeToolPlans=true',
        authenticated: true,
        accountId: owner,
      );
      if (_disposed || owner != client.accountId?.call()) return;
      final device = await executor.deviceId();
      if (_disposed || owner != _owner || owner != client.accountId?.call()) {
        return;
      }
      var toolsCompleted = false;
      for (final item in response['data'] as List) {
        try {
          final action = Map<String, dynamic>.from(item);
          if (action['kind'] == 'tool_plan') {
            final id = action['id'] as String;
            final status = action['status'] as String;
            if (_toolStates[id] != null &&
                _toolStates[id] != 'completed' &&
                status == 'completed') {
              toolsCompleted = true;
            }
            _toolStates[id] = status;
            _receiveToolPlan(owner, action, device);
            continue;
          }
          final status = action['status'];
          final operation = action['operation'] is String
              ? action['operation'] as String
              : 'create';
          if (!{'create', 'reschedule', 'cancel'}.contains(operation)) {
            malformedItems++;
            continue;
          }
          final mine =
              action['deviceId'] == null || action['deviceId'] == device;
          final pending =
              mine && (status == 'pending' || status == 'awaiting_device');
          final start = DateTime.tryParse(
            action['start'] as String? ?? '',
          )?.toLocal();
          final end = DateTime.tryParse(
            action['end'] as String? ?? '',
          )?.toLocal();
          if (start == null ||
              end == null ||
              !end.isAfter(start) ||
              action['id'] is! String ||
              action['title'] is! String) {
            malformedItems++;
            continue;
          }
          String time(DateTime value) =>
              '${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}';
          final endDate =
              end.year == start.year &&
                  end.month == start.month &&
                  end.day == start.day
              ? ''
              : '${end.year}/${end.month}/${end.day} ';
          final operationLabel = switch (operation) {
            'reschedule' => '改期日程',
            'cancel' => '取消日程',
            _ => '创建日程',
          };
          final operationInstruction = switch (operation) {
            'reschedule' => '更新原日历项并回读核验',
            'cancel' => '删除原日历项并回读确认',
            _ => '创建日历项并回读核验',
          };
          notifications.receive(
            ActionNotice(
              id: 'action:${action['id']}',
              title: '$operationLabel：${action['title']}',
              instruction:
                  '${start.year}/${start.month}/${start.day} ${time(start)}–$endDate${time(end)}，$operationInstruction。',
              state: pending
                  ? NoticeState.pending
                  : status == 'completed'
                  ? NoticeState.completed
                  : status == 'declined'
                  ? NoticeState.declined
                  : NoticeState.unavailable,
              successState: NoticeState.completed,
              allowLabel: status == 'awaiting_device' ? '重试' : '允许',
            ),
            onDecline: () async {
              final result = await _decision(owner, action, device, false);
              return result['status'] == 'declined';
            },
            onAllow: () async {
              final approved = await _decision(owner, action, device, true);
              if (approved['status'] == 'completed') return true;
              if (approved['status'] != 'awaiting_device') return false;
              final command = _approvedCalendarAction(action, approved);
              final receipt = await executor.execute(
                owner,
                command,
                isCurrent: () =>
                    !_disposed && owner == client.accountId?.call(),
              );
              final version = command['version'];
              final result = await client.post(
                'actions/${action['id']}/receipt',
                authenticated: true,
                accountId: owner,
                data: {
                  ...receipt,
                  'deviceId': device,
                  if (version is int) 'version': version,
                  'mutationId': _mutationId(owner, command, device, 'receipt'),
                },
              );
              return owner == client.accountId?.call() &&
                  result['data']['status'] == 'completed';
            },
          );
        } catch (_) {
          malformedItems++;
        }
      }
      if (toolsCompleted) await onChanged?.call();
      if (_disposed || owner != client.accountId?.call()) return;
      final tasks = await client.get(
        'tasks',
        authenticated: true,
        accountId: owner,
      );
      if (_disposed || owner != client.accountId?.call()) return;
      final current = <String>{};
      for (final item in tasks['data'] as List) {
        try {
          final task = Map<String, dynamic>.from(item);
          if (task['id'] is! String ||
              task['title'] is! String ||
              task['version'] is! int) {
            malformedItems++;
            continue;
          }
          final status = task['status'];
          final ready =
              (status == 'claimed_completed' ||
                  status == 'evidence_verified') &&
              (task['evidenceCurrent'] == true ||
                  ((task['attachments'] as List? ?? []).isEmpty &&
                      task['sourceCurrent'] == true));
          if (status != 'pending' && !ready) continue;
          final id = 'action:task:${task['id']}:${task['version']}';
          current.add(id);
          notifications.receive(
            ActionNotice(
              id: id,
              title: '${ready ? '确认任务完成' : '开始任务'}：${task['title']}',
              instruction: ready
                  ? '确认实际完成后更新对应目标，不代表客户验收。'
                  : '将此项标为进行中，保留原始会议依据。',
              allowLabel: ready ? '确认' : '开始',
              successState: NoticeState.completed,
            ),
            onAllow: () async {
              final result = await client.post(
                'tasks/${task['id']}/status',
                authenticated: true,
                accountId: owner,
                data: {
                  'version': task['version'],
                  'status': ready ? 'verified' : 'active',
                  'note': ready ? '本人核对实际完成情况' : '本人开始处理任务',
                },
              );
              if (_disposed || owner != client.accountId?.call()) return false;
              if (result['data']['status'] != (ready ? 'verified' : 'active')) {
                return false;
              }
              await onChanged?.call();
              return true;
            },
          );
        } catch (_) {
          malformedItems++;
        }
      }
      notifications.syncTaskIds(current);
      _failures = 0;
      error = malformedItems == 0
          ? null
          : '已跳过 $malformedItems 条格式异常的通知，其余事项已更新';
    } catch (_) {
      if (owner == _owner && !_disposed) {
        _failures++;
        error = '通知同步失败，将自动重试';
      }
    } finally {
      _loading = false;
      if (!_disposed) {
        _schedule();
        notifyListeners();
      }
    }
  }

  String _mutationId(
    String owner,
    Map<String, dynamic> action,
    String device,
    String phase,
  ) {
    final value = jsonEncode({
      'owner': owner,
      'actionId': action['id'],
      'fingerprint': action['fingerprint'],
      'version': action['version'],
      'deviceId': device,
      'phase': phase,
    });
    return '$phase-${sha256.convert(utf8.encode(value))}';
  }

  Map<String, dynamic> _approvedCalendarAction(
    Map<String, dynamic> requested,
    Map<String, dynamic> decision,
  ) {
    final nested = decision['approvedAction'];
    if (nested != null && nested is! Map) {
      throw const ApiFailure('服务端批准的日历操作无法核对');
    }
    final approved = nested is Map
        ? Map<String, dynamic>.from(nested)
        : decision.keys.any(
            (key) => const {
              'id',
              'operation',
              'fingerprint',
              'title',
              'start',
              'end',
              'target',
            }.contains(key),
          )
        ? decision
        : const <String, dynamic>{};
    final command = <String, dynamic>{...requested, ...approved};
    if (nested is Map &&
        command['version'] == requested['version'] &&
        decision['version'] is int) {
      command['version'] = decision['version'];
    }
    final requestedOperation = requested['operation'] is String
        ? requested['operation']
        : 'create';
    final commandOperation = command['operation'] is String
        ? command['operation']
        : 'create';
    if (command['id'] != requested['id'] ||
        command['fingerprint'] != requested['fingerprint'] ||
        commandOperation != requestedOperation) {
      throw const ApiFailure('服务端批准的日历操作已变化，请刷新后重试');
    }
    return command;
  }

  Future<Map<String, dynamic>> _decision(
    String owner,
    Map<String, dynamic> action,
    String device,
    bool allow,
  ) async {
    final version = action['version'];
    final response = await client.post(
      'actions/${action['id']}/decision',
      authenticated: true,
      accountId: owner,
      receiveTimeout: const Duration(seconds: 100),
      data: {
        'fingerprint': action['fingerprint'],
        'allow': allow,
        'deviceId': device,
        if (version is int) 'version': version,
        'mutationId': _mutationId(
          owner,
          action,
          device,
          allow ? 'decision-allow' : 'decision-decline',
        ),
      },
    );
    return Map<String, dynamic>.from(response['data']);
  }

  void _receiveToolPlan(
    String owner,
    Map<String, dynamic> action,
    String device,
  ) {
    final status = action['status'];
    final recovering =
        status == 'retryable' &&
        action['approved'] == true &&
        (action['executionAttempts'] as int? ?? 0) < 3;
    notifications.receive(
      ActionNotice(
        id: 'action:${action['id']}',
        title: action['title'] as String,
        instruction: recovering
            ? '已获批准，正在从未完成步骤恢复。'
            : status == 'blocked'
            ? '参数或依据未通过校验，已停止执行。'
            : status == 'retryable'
            ? '自动恢复未完成，可从中断步骤重试。'
            : action['instruction'] as String,
        state: recovering
            ? NoticeState.preparing
            : status == 'pending' || status == 'retryable'
            ? NoticeState.pending
            : status == 'completed'
            ? NoticeState.completed
            : status == 'declined'
            ? NoticeState.declined
            : NoticeState.unavailable,
        successState: NoticeState.completed,
        allowLabel: status == 'retryable' ? '重试' : '允许',
      ),
      onAllow: () async {
        final result = await _decision(owner, action, device, true);
        if (_disposed || owner != client.accountId?.call()) return false;
        if (result['status'] == 'completed') {
          await onChanged?.call();
          return true;
        }
        if (result['status'] == 'retryable' && result['approved'] == true) {
          await refresh();
          throw const NoticeCancelled();
        }
        if (result['status'] == 'blocked') {
          throw const ApiFailure('执行已停止：相关依据或参数需要重新核对');
        }
        return false;
      },
      onDecline: () async {
        final declined =
            (await _decision(owner, action, device, false))['status'] ==
            'declined';
        if (declined && !_disposed && owner == client.accountId?.call()) {
          await onChanged?.call();
        }
        return declined;
      },
    );
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}
