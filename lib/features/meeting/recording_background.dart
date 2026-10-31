import 'dart:io';
import 'package:flutter/services.dart';

/// 只在用户从前台发起录音后维持系统录音服务，不自动打开麦克风。
class RecordingBackground {
  static const _channel = MethodChannel('yanshu/recording_background');
  Future<void> start({bool externalDevice = false}) async {
    if (Platform.isAndroid) {
      await _channel.invokeMethod<void>('start', {
        'externalDevice': externalDevice,
      });
    }
  }

  Future<void> stop() async {
    if (Platform.isAndroid) await _channel.invokeMethod<void>('stop');
  }
}
