import 'dart:async';
import 'package:flutter/foundation.dart';
import '../../core/network/api_client.dart';
import 'notification_model.dart';

/// 全局仅接收明确风险；可填写的补全由进展负责，资料行动聚合在详情。
/// 问卷和普通行动有意保持静默，账户切换后不沿用旧回调。
class KnowledgeAssistance extends ChangeNotifier {
  KnowledgeAssistance(this.client, this.notifications, {this.onRecorded}) {
    notifications.addListener(_syncClears);
  }
  void _syncClears() {
    if (!_disposed &&
        !_loading &&
        notifications.pendingRemoteClears.isNotEmpty) {
      Future.microtask(refresh);
    }
  }

  Future<Map<String, dynamic>> documentActions(
    String id,
    String version,
  ) async {
    final response = await client.get(
      'knowledge/documents/${Uri.encodeComponent(id)}/actions?version_id=${Uri.encodeComponent(version)}',
      authenticated: true,
      accountId: client.accountId?.call(),
    );
    return Map<String, dynamic>.from(response['data']);
  }

  Future<bool> recordDocumentAction(Map<String, dynamic> item) async {
    final owner = client.accountId?.call();
    if (owner == null) return false;
    return _decide(owner, item, true);
  }

  final ApiClient client;
  final NotificationModel notifications;
  final Future<void> Function()? onRecorded;
  String? _owner;
  Timer? _timer;
  bool _disposed = false, _loading = false;
  bool _initialized = false;
  void refreshAccount() {
    final owner = client.accountId?.call();
    if (_owner == owner) return;
    _owner = owner;
    _initialized = false;
    _timer?.cancel();
    Future.microtask(() {
      if (!_disposed) notifications.syncAssistanceIds({});
    });
    if (owner != null) {
      Future.microtask(refresh);
      _timer = Timer.periodic(const Duration(seconds: 15), (_) => refresh());
    }
  }

  Future<void> refresh() async {
    final owner = _owner;
    if (_disposed || owner == null || _loading) return;
    _loading = true;
    try {
      // Persistence restoration must not block network refresh forever (for
      // example after a platform notification plugin is unavailable).
      await Future.any<void>([
        notifications.inboxReady,
        Future<void>.delayed(const Duration(milliseconds: 250)),
      ]);
      if (_disposed || owner != _owner) return;
      final pending = notifications.pendingRemoteClears.take(500).toSet();
      final inbox = pending.isEmpty
          ? await client.get(
              'knowledge/notice-inbox',
              authenticated: true,
              accountId: owner,
            )
          : await client.post(
              'knowledge/notice-inbox/clear',
              authenticated: true,
              accountId: owner,
              data: {'ids': pending.toList()},
            );
      if (_disposed || owner != _owner) return;
      notifications.applyRemoteCleared(
        List<String>.from(inbox['data']['clearedIds']),
        synced: pending,
      );
      if (pending.isNotEmpty) await onRecorded?.call();
      if (_disposed || owner != _owner) return;
      final response = await client.get(
        'knowledge/assistance',
        authenticated: true,
        accountId: owner,
      );
      if (_disposed || owner != _owner || owner != client.accountId?.call()) {
        return;
      }
      final ids = <String>{};
      for (final raw in response['data'] as List) {
        final item = Map<String, dynamic>.from(raw);
        if (item['kind'] != 'warning') continue;
        final id = 'assistance:${item['id']}:${item['fingerprint']}';
        ids.add(id);
        notifications.receive(
          ActionNotice(
            id: id,
            kind: NoticeKind.warning,
            title: item['title'],
            instruction: item['instruction'],
            allowLabel: item['allowLabel'],
            state: switch (item['state']) {
              'preparing' => NoticeState.preparing,
              'allowed' => NoticeState.allowed,
              'declined' => NoticeState.declined,
              'unavailable' => NoticeState.unavailable,
              _ => NoticeState.pending,
            },
          ),
          onAllow: () => _decide(owner, item, true),
          onDecline: () => _decide(owner, item, false),
          announce: _initialized,
        );
      }
      notifications.syncAssistanceIds(ids);
      _initialized = true;
    } catch (_) {
      // 断网不伪造提取、记录成功或问题已解决。
    } finally {
      _loading = false;
    }
  }

  Future<bool> _decide(
    String owner,
    Map<String, dynamic> item,
    bool allow,
  ) async {
    if (_disposed || owner != _owner || owner != client.accountId?.call()) {
      return false;
    }
    final response = await client.post(
      'knowledge/assistance/decision',
      authenticated: true,
      accountId: owner,
      data: {
        'id': item['id'],
        'fingerprint': item['fingerprint'],
        'allow': allow,
      },
    );
    if (_disposed || owner != _owner || owner != client.accountId?.call()) {
      return false;
    }
    if (response['data']['status'] == 'recorded') await onRecorded?.call();
    // 通知决定完成后再刷新，避免刷新移除正在处理的通知。
    Future.microtask(refresh);
    return true;
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    notifications.removeListener(_syncClears);
    super.dispose();
  }
}
