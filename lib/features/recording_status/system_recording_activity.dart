import 'package:flutter/services.dart';

abstract interface class SystemRecordingActivity {
  Future<Map<String, dynamic>> capabilities();
  Future<Map<String, dynamic>> synchronize(Map<String, dynamic>? snapshot);
  Future<String?> takeOpenMeeting();
  Future<void> requestNotifications();
}

class NativeRecordingActivity implements SystemRecordingActivity {
  const NativeRecordingActivity();
  static const channel = MethodChannel('agenote/recording_activity');
  @override
  Future<Map<String, dynamic>> capabilities() async =>
      Map<String, dynamic>.from(
        await channel.invokeMapMethod('capabilities') ?? {},
      );
  @override
  Future<Map<String, dynamic>> synchronize(
    Map<String, dynamic>? snapshot,
  ) async => Map<String, dynamic>.from(
    await channel.invokeMapMethod('sync', snapshot) ?? {},
  );
  @override
  Future<String?> takeOpenMeeting() =>
      channel.invokeMethod<String>('takeOpenMeeting');
  @override
  Future<void> requestNotifications() =>
      channel.invokeMethod<void>('requestNotifications');
}
