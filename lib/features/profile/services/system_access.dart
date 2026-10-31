import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

enum SystemAccess {
  microphone,
  notifications,
  bluetooth,
  calendar,
  photos,
  camera,
}

enum SystemSetting { liveActivities, lockScreen }

abstract interface class SystemAccessService {
  Future<Map<SystemAccess, PermissionStatus>> read();
  Future<void> request(SystemAccess access);
  Future<bool> settings();
}

/// Settings outside runtime permission dialogs. A null value means the OS does
/// not expose a reliable read API; it must never be displayed as granted.
abstract interface class SystemAccessSettingsService {
  Future<Map<SystemSetting, bool?>> readSettings();
  Future<bool> settingsFor({SystemAccess? access, SystemSetting? setting});
}

class DeviceSystemAccessService
    implements SystemAccessService, SystemAccessSettingsService {
  DeviceSystemAccessService({
    TargetPlatform? platform,
    Future<PermissionStatus> Function(Permission)? status,
    Future<void> Function(List<Permission>)? requestPermissions,
    Future<bool> Function()? openSettings,
    MethodChannel? channel,
  }) : _platform = platform ?? defaultTargetPlatform,
       _status = status ?? ((p) => p.status),
       _request =
           requestPermissions ??
           ((ps) async {
             await ps.request();
           }),
       _openSettings = openSettings ?? openAppSettings,
       _channel = channel ?? const MethodChannel('agenote/recording_activity');
  final TargetPlatform _platform;
  final Future<PermissionStatus> Function(Permission) _status;
  final Future<void> Function(List<Permission>) _request;
  final Future<bool> Function() _openSettings;
  final MethodChannel _channel;

  Future<Map<String, dynamic>> _capabilities() async =>
      Map<String, dynamic>.from(
        await _channel.invokeMapMethod('permissionSettings') ?? {},
      );

  Future<List<Permission>> _permissions(SystemAccess access) async {
    if (access == SystemAccess.bluetooth) {
      if (_platform == TargetPlatform.iOS) return [Permission.bluetooth];
      final api = (await _capabilities())['androidApi'] as int?;
      if (api == null) throw StateError('无法检测 Android 蓝牙权限版本');
      return api >= 31
          ? [Permission.bluetoothScan, Permission.bluetoothConnect]
          : [Permission.locationWhenInUse];
    }
    return [
      switch (access) {
        SystemAccess.microphone => Permission.microphone,
        SystemAccess.notifications => Permission.notification,
        SystemAccess.calendar => Permission.calendarFullAccess,
        SystemAccess.photos => Permission.photos,
        SystemAccess.camera => Permission.camera,
        SystemAccess.bluetooth => throw StateError('蓝牙权限需按系统版本解析'),
      },
    ];
  }

  @override
  Future<Map<SystemAccess, PermissionStatus>> read() async {
    final accesses = [
      SystemAccess.microphone, SystemAccess.notifications,
      if (_platform == TargetPlatform.android ||
          _platform == TargetPlatform.iOS) ...[
        SystemAccess.bluetooth,
        SystemAccess.calendar,
      ],
      // Android uses the system document picker and does not request broad media
      // or camera access. iOS SDK photo/camera access is declared in Info.plist.
      if (_platform == TargetPlatform.iOS) ...[
        SystemAccess.photos,
        SystemAccess.camera,
      ],
    ];
    final states = <SystemAccess, PermissionStatus>{};
    for (final access in accesses) {
      final values = await Future.wait(
        (await _permissions(access)).map(_status),
      );
      states[access] = mergePermissionStates(values);
    }
    return states;
  }

  static PermissionStatus mergePermissionStates(List<PermissionStatus> values) {
    if (values.contains(PermissionStatus.restricted)) {
      return PermissionStatus.restricted;
    }
    if (values.contains(PermissionStatus.permanentlyDenied)) {
      return PermissionStatus.permanentlyDenied;
    }
    if (values.contains(PermissionStatus.denied)) {
      return PermissionStatus.denied;
    }
    if (values.contains(PermissionStatus.limited)) {
      return PermissionStatus.limited;
    }
    if (values.contains(PermissionStatus.provisional)) {
      return PermissionStatus.provisional;
    }
    return values.isEmpty ? PermissionStatus.denied : PermissionStatus.granted;
  }

  @override
  Future<void> request(SystemAccess access) async {
    await _request(await _permissions(access));
  }

  @override
  Future<bool> settings() => _openSettings();

  @override
  Future<Map<SystemSetting, bool?>> readSettings() async {
    if (_platform != TargetPlatform.android &&
        _platform != TargetPlatform.iOS) {
      return {};
    }
    final caps = await _capabilities();
    return {
      if (caps['liveActivitiesSupported'] == true)
        SystemSetting.liveActivities: caps['liveActivitiesAllowed'] as bool?,
      SystemSetting.lockScreen: caps['lockScreenAllowed'] as bool?,
    };
  }

  @override
  Future<bool> settingsFor({
    SystemAccess? access,
    SystemSetting? setting,
  }) async {
    final notification =
        access == SystemAccess.notifications ||
        setting == SystemSetting.lockScreen;
    if (notification || setting == SystemSetting.liveActivities) {
      try {
        final opened = await _channel.invokeMethod<bool>(
          notification ? 'openNotificationSettings' : 'requestLiveUpdates',
        );
        if (opened == true) return true;
      } on MissingPluginException {
        /* App settings remain available. */
      } on PlatformException {
        /* OEM may not expose a dedicated screen. */
      }
    }
    return settings();
  }
}
