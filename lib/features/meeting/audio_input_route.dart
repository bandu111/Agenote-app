import 'dart:io';
import 'package:flutter/services.dart';

/// 记录实际采音路由，不能用蓝牙“已配对”或播放设备代替麦克风证据。
class AudioInputRoute {
  const AudioInputRoute({
    required this.id,
    required this.name,
    required this.type,
    required this.verified,
    this.sampleRate = 0,
    this.channels = 0,
    this.silenced = false,
  });
  final String id, name, type;
  final bool verified, silenced;
  final int sampleRate, channels;
  bool get bluetooth => type == 'bluetooth';
  factory AudioInputRoute.fromMap(Map<Object?, Object?> value) =>
      AudioInputRoute(
        id: value['id']?.toString() ?? '',
        name: value['name']?.toString() ?? '',
        type: value['type']?.toString() ?? 'unknown',
        verified: value['verified'] == true,
        sampleRate: (value['sampleRate'] as num?)?.toInt() ?? 0,
        channels: (value['channels'] as num?)?.toInt() ?? 0,
        silenced: value['silenced'] == true,
      );
  Map<String, Object> toMap() => {
    'id': id,
    'name': name,
    'type': type,
    'verified': verified,
    'sampleRate': sampleRate,
    'channels': channels,
    'silenced': silenced,
  };
}

class DeviceAudioInputMonitor {
  static const _methods = MethodChannel('yanshu/audio_input');
  static const _events = EventChannel('yanshu/audio_input/events');
  bool get supported => Platform.isAndroid || Platform.isIOS;
  Stream<AudioInputRoute> get changes => supported
      ? _events.receiveBroadcastStream().map(
          (event) =>
              AudioInputRoute.fromMap(Map<Object?, Object?>.from(event as Map)),
        )
      : const Stream.empty();
  Future<AudioInputRoute> snapshot() async => AudioInputRoute.fromMap(
    supported
        ? (await _methods.invokeMapMethod<Object?, Object?>('snapshot') ?? {})
        : {},
  );
}
