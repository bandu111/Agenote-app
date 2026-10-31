import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'recorder_device_service.dart';
import 'recorder_models.dart';

/// SDK 协议细节只在适配层出现；SN 仅用于设备资料，不转发原始日志。
class SoniNoteDeviceAdapter implements RecorderDeviceService {
  static const method = MethodChannel('yanshu/soninote');
  static const eventChannel = EventChannel('yanshu/soninote/events');
  final _events = StreamController<RecorderEvent>.broadcast();
  StreamSubscription<dynamic>? _subscription;
  Future<void>? _initializing;
  bool _disposed = false;
  int _connectionEpoch = 0;
  @override
  Stream<RecorderEvent> get events => _events.stream;
  Future<void> _call(String command, [Object? args]) async {
    if (_disposed) return;
    try {
      await method.invokeMethod<void>(command, args);
    } on PlatformException catch (e) {
      throw RecorderFailure(e.code, e.message ?? '设备操作失败');
    } on MissingPluginException {
      throw const RecorderFailure(
        'sdk_unavailable',
        '当前平台尚不支持录音卡，请使用 Android 或 iOS 安装包',
      );
    }
  }

  @override
  Future<void> initialize() => _initializing ??= _initialize();
  Future<void> _initialize() async {
    _subscription = eventChannel.receiveBroadcastStream().listen(
      (raw) {
        if (_disposed || raw is! Map) return;
        final type = raw['event_type']?.toString();
        if (type == null) return;
        _events.add(
          RecorderEvent(
            type,
            epoch: RecorderInfo.number(raw['epoch']) ?? 0,
            deviceId: raw['device_id']?.toString(),
            data: Map<String, dynamic>.from(raw['data'] as Map? ?? {}),
          ),
        );
      },
      onError: (_) {
        if (!_disposed) {
          _events.add(
            const RecorderEvent(
              'error',
              data: {
                'code': 'event_channel_failed',
                'message': '设备事件连接失败，请重新进入设备页',
              },
            ),
          );
        }
      },
    );
    await checkBluetooth();
  }

  @override
  Future<void> requestPermissions() async {
    if (defaultTargetPlatform == TargetPlatform.android) {
      final api = await method.invokeMethod<int>('androidApi') ?? 0;
      final permissions = api >= 31
          ? [Permission.bluetoothScan, Permission.bluetoothConnect]
          : [Permission.locationWhenInUse];
      final result = await permissions.request();
      if (result.values.any((p) => !p.isGranted)) {
        await checkBluetooth();
        throw RecorderFailure(
          result.values.any((p) => p.isPermanentlyDenied)
              ? 'permission_permanently_denied'
              : 'permission_denied',
          '请在系统设置中允许蓝牙权限后重试',
        );
      }
    } else {
      await _call('requestPermissions');
    }
    await checkBluetooth();
  }

  @override
  Future<void> checkBluetooth() => _call('status');
  @override
  Future<void> startScan() => _call('startScan');
  @override
  Future<void> stopScan() => _call('stopScan');
  @override
  Future<void> connect(RecorderDevice device, int epoch) {
    _connectionEpoch = epoch;
    return _call('connect', {
      'device_id': device.id,
      'name': device.name,
      'epoch': epoch,
    });
  }

  @override
  Future<void> disconnect() {
    ++_connectionEpoch;
    return _call('disconnect');
  }

  @override
  Future<void> syncTime() => _call('syncTime');
  @override
  Future<void> refreshDeviceInfo() async {
    final epoch = _connectionEpoch;
    for (final name in [
      'battery',
      'capacity',
      'firmware',
      'firmwareCode',
      'serial',
      'recording',
      'duration',
    ]) {
      if (_disposed || epoch != _connectionEpoch) return;
      await _call(name);
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  @override
  Future<void> queryRecording() => _call('recording');
  @override
  Future<void> queryDuration() => _call('duration');
  @override
  Future<void> startRecording() => _call('startRecording');
  @override
  Future<void> pauseRecording() => _call('pauseRecording');
  @override
  Future<void> resumeRecording() => _call('resumeRecording');
  @override
  Future<void> stopRecording() => _call('stopRecording');
  @override
  Future<void> setForeground(bool foreground) =>
      _call('foreground', foreground);
  @override
  Future<void> dispose() async {
    _disposed = true;
    await _subscription?.cancel();
    await _events.close();
  }
}
