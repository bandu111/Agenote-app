import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../../core/network/api_client.dart';
import 'notification_model.dart';

/// 只展示真实待补全和风险；稳定 ID 替换原生通知，内容版本负责送达去重。
class LocalNotifications extends ChangeNotifier with WidgetsBindingObserver {
  LocalNotifications(
    this.client,
    this.notifications, {
    required this.onChanged,
    required this.onOpen,
    FlutterSecureStorage? storage,
  }) : storage = storage ?? const FlutterSecureStorage() {
    WidgetsBinding.instance.addObserver(this);
    notifications.addListener(_changed);
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'opened' &&
          _enabled &&
          call.arguments == _owner &&
          _owner == client.accountId?.call()) {
        final generation = _generation;
        try {
          await _consumeOpen(generation);
        } catch (_) {
          if (_current(generation)) _setError('open', '通知入口暂不可用，请重试');
        }
      }
    });
  }
  static const _channel = MethodChannel('agenote/local-notifications');
  final ApiClient client;
  final NotificationModel notifications;
  final FlutterSecureStorage storage;
  final Future<void> Function() onChanged;
  final VoidCallback onOpen;
  Timer? _timer;
  int _generation = 0;
  bool _disposed = false, _enabled = false, _ready = false, _refreshing = false;
  bool _delivering = false, _dirty = false;
  int? _initializing, _opening;
  bool _openAgain = false;
  final _activeKeys = <String>{};
  String? _owner;
  final _errors = <String, String>{};
  String? get error => _errors.isEmpty ? null : _errors.values.first;
  final _seen = <String, String>{};
  String _key(String owner) =>
      'local-notice-delivery:${client.dio.options.baseUrl}:$owner';
  bool _current(int generation) =>
      !_disposed &&
      generation == _generation &&
      _owner == client.accountId?.call();
  void _setError(String source, String? value) {
    if (_disposed || _errors[source] == value) return;
    if (value == null) {
      _errors.remove(source);
    } else {
      _errors[source] = value;
    }
    notifyListeners();
  }

  void configure({required bool enabled}) {
    final owner = client.accountId?.call();
    final next =
        enabled &&
        owner != null &&
        !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS);
    if (_owner == owner && _enabled == next) return;
    final generation = ++_generation;
    _owner = owner;
    _enabled = next;
    _ready = false;
    _seen.clear();
    _activeKeys.clear();
    _openAgain = false;
    _errors.clear();
    _timer?.cancel();
    // 先建立重试调度；首次桥接/存储异常不会永久失去恢复机会。
    if (next) {
      _timer = Timer.periodic(
        const Duration(seconds: 30),
        (_) => unawaited(retry()),
      );
    }
    Future.microtask(() => _initialize(generation));
  }

  Future<void> _initialize(int generation) async {
    if (!_current(generation) || _initializing == generation) return;
    _initializing = generation;
    try {
      await _channel.invokeMethod<void>('configure', {
        'owner': _owner,
        'enabled': _enabled,
      });
      if (!_current(generation)) return;
      final owner = _owner;
      final raw = owner == null ? null : await storage.read(key: _key(owner));
      if (!_current(generation)) return;
      if (raw != null) {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          // 旧格式只有 ID，没有内容版本：下一次按当前真实内容重新核对。
          for (final id in decoded.whereType<String>()) {
            _seen[id] = '';
          }
        } else if (decoded is Map && decoded['seen'] is Map) {
          _seen.addAll(Map<String, String>.from(decoded['seen']));
        }
      }
      _ready = true;
      if (!_enabled) _timer?.cancel();
      _setError('initialize', null);
      if (_enabled) await _checkPermission(generation);
      if (!_current(generation)) return;
      _changed();
      await _consumeOpen(generation);
    } catch (_) {
      if (_current(generation)) {
        _ready = false;
        _setError('initialize', '本地通知暂不可用，将自动重试；应用内通知仍可查看');
        if (!_enabled) {
          _timer?.cancel();
          _timer = Timer(
            const Duration(seconds: 30),
            () => _initialize(generation),
          );
        }
      }
    } finally {
      if (_initializing == generation) _initializing = null;
    }
  }

  Future<void> _consumeOpen(int generation) async {
    if (!_current(generation)) return;
    if (_opening == generation) {
      _openAgain = true;
      return;
    }
    _opening = generation;
    try {
      // 热启动和冷启动共用一次性消费，不让点击标记残留至下次启动。
      final opened = await _channel.invokeMethod<String>('takeOpen');
      if (_current(generation)) _setError('open', null);
      if (!_current(generation) ||
          !_enabled ||
          opened == null ||
          opened != _owner) {
        return;
      }
      await _refresh();
      if (_current(generation) && _enabled) onOpen();
    } finally {
      if (_opening == generation) _opening = null;
      if (_openAgain && _current(generation)) {
        _openAgain = false;
        Future.microtask(() => _consumeOpen(generation));
      }
    }
  }

  Future<void> _checkPermission(int generation) async {
    final status = await _channel.invokeMapMethod<String, dynamic>('status');
    if (!_current(generation)) return;
    if (status?['activeIds'] is List) {
      _activeKeys
        ..clear()
        ..addAll(List<String>.from(status!['activeIds']));
    }
    if (status?['permissionGranted'] == false) {
      _setError('permission', '系统通知已关闭，请在系统设置中允许通知；应用内通知仍可查看');
    } else if (status?['permissionGranted'] == true) {
      _setError('permission', null);
    }
  }

  Future<void> retry() async {
    final generation = _generation;
    if (!_current(generation)) return;
    if (!_ready) {
      await _initialize(generation);
      return;
    }
    try {
      if (_enabled) await _checkPermission(generation);
      if (!_current(generation)) return;
      await _refresh();
      await _consumeOpen(generation);
      _changed();
    } catch (_) {
      if (_current(generation)) _setError('delivery', '通知权限或系统状态暂时无法读取，请重试');
    }
  }

  void _changed() {
    if (_disposed) return;
    _dirty = true;
    Future.microtask(_deliver);
  }

  Future<void> _deliver() async {
    if (_disposed || !_ready || _delivering) return;
    _delivering = true;
    final generationAtStart = _generation;
    try {
      while (_dirty && !_disposed) {
        _dirty = false;
        final generation = _generation, owner = _owner;
        if (owner == null || !_current(generation)) continue;
        // 暂时没有加载完成，不据此删除历史去重记录或原生通知。
        if (notifications.loading) continue;
        if (_enabled) await _checkPermission(generation);
        if (!_current(generation)) continue;
        final pending = notifications.items.where((n) => n.interrupts).toList();
        final keys = pending.map(notifications.deliveryKey).toSet();
        await _channel.invokeMethod<void>('sync', {
          'owner': owner,
          'ids': _enabled ? keys.toList() : <String>[],
          'badge': _enabled ? notifications.pendingCount : 0,
        });
        if (!_current(generation) || !_enabled) continue;
        _setError('delivery', null);
        // 只保留当前有效待处理事项；历史记录随清空、失效、完成而回收。
        _seen.removeWhere((key, _) => !keys.contains(key));
        for (final notice in pending) {
          if (!_current(generation)) break;
          final key = notifications.deliveryKey(notice),
              version = notice.inboxVersion;
          if (_seen[key] == version ||
              !notifications.items.any(
                (n) =>
                    n.interrupts &&
                    notifications.deliveryKey(n) == key &&
                    n.inboxVersion == version,
              )) {
            continue;
          }
          final foreground =
              WidgetsBinding.instance.lifecycleState ==
              AppLifecycleState.resumed;
          final shown =
              (foreground && !_activeKeys.contains(key)) ||
              await _channel.invokeMethod<bool>('show', {
                    'owner': owner,
                    'id': key,
                    'title': notice.title,
                    'body': notice.instruction,
                    'badge': notifications.pendingCount,
                    'silent': foreground,
                  }) ==
                  true;
          if (!_current(generation)) break;
          if (shown) {
            _seen[key] = version;
            _setError('delivery', null);
          } else {
            _setError('delivery', '系统通知未能展示，请检查通知权限或重试');
          }
        }
        if (_current(generation)) {
          await storage.write(
            key: _key(owner),
            value: jsonEncode({'version': 2, 'seen': _seen}),
          );
        }
      }
    } catch (_) {
      if (_current(generationAtStart)) {
        _setError('delivery', '本地通知未完成，将自动重试；应用内通知仍可查看');
      }
    } finally {
      _delivering = false;
      if (_dirty && !_disposed) Future.microtask(_deliver);
    }
  }

  Future<void> _refresh() async {
    if (_disposed ||
        !_enabled ||
        _refreshing ||
        _owner != client.accountId?.call()) {
      return;
    }
    final generation = _generation;
    _refreshing = true;
    try {
      await onChanged();
      if (_current(generation)) _setError('sync', null);
    } catch (_) {
      if (_current(generation)) _setError('sync', '通知状态同步失败，将自动重试');
    } finally {
      _refreshing = false;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(retry());
  }

  @override
  void dispose() {
    _disposed = true;
    ++_generation;
    _timer?.cancel();
    notifications.removeListener(_changed);
    WidgetsBinding.instance.removeObserver(this);
    _channel.setMethodCallHandler(null);
    super.dispose();
  }
}
