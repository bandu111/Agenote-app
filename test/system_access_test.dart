import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:yanshu/features/profile/services/system_access.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/permissions');
  late Map<String, dynamic> caps;
  late List<String> calls;
  late List<Permission> requested;
  late Map<Permission, PermissionStatus> states;
  setUp(() {
    caps = {
      'androidApi': 36,
      'liveActivitiesSupported': true,
      'liveActivitiesAllowed': false,
    };
    calls = [];
    requested = [];
    states = {};
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call.method);
          return call.method == 'permissionSettings' ? caps : true;
        });
  });
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null),
  );
  DeviceSystemAccessService service(
    TargetPlatform platform, {
    Future<bool> Function()? settings,
  }) => DeviceSystemAccessService(
    platform: platform,
    channel: channel,
    status: (p) async => states[p] ?? PermissionStatus.granted,
    requestPermissions: (ps) async {
      requested.addAll(ps);
    },
    openSettings: settings ?? () async => true,
  );
  test(
    'Android 12+ requires both nearby permissions, read never requests or records',
    () async {
      states[Permission.bluetoothConnect] = PermissionStatus.denied;
      final s = service(TargetPlatform.android);
      final values = await s.read();
      expect(
        values.keys,
        containsAll([
          SystemAccess.microphone,
          SystemAccess.notifications,
          SystemAccess.bluetooth,
          SystemAccess.calendar,
        ]),
      );
      expect(values[SystemAccess.bluetooth], PermissionStatus.denied);
      expect(values, isNot(contains(SystemAccess.photos)));
      expect(requested, isEmpty);
      expect(calls, everyElement('permissionSettings'));
      await s.request(SystemAccess.bluetooth);
      expect(requested, [
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
      ]);
    },
  );
  test(
    'legacy Android requests location for BLE and not modern nearby permissions',
    () async {
      caps['androidApi'] = 30;
      await service(TargetPlatform.android).request(SystemAccess.bluetooth);
      expect(requested, [Permission.locationWhenInUse]);
    },
  );
  test(
    'iOS exposes limited photos and full calendar authorization truthfully',
    () async {
      states[Permission.photos] = PermissionStatus.limited;
      states[Permission.calendarFullAccess] =
          PermissionStatus.permanentlyDenied;
      final s = service(TargetPlatform.iOS);
      final values = await s.read();
      expect(values[SystemAccess.photos], PermissionStatus.limited);
      expect(values[SystemAccess.calendar], PermissionStatus.permanentlyDenied);
      expect(values[SystemAccess.camera], PermissionStatus.granted);
      await s.request(SystemAccess.calendar);
      expect(requested, [Permission.calendarFullAccess]);
    },
  );
  test(
    'OEM lockscreen has unknown status; unsupported live activities are omitted',
    () async {
      final s = service(TargetPlatform.android);
      expect(await s.readSettings(), {
        SystemSetting.liveActivities: false,
        SystemSetting.lockScreen: null,
      });
      caps['liveActivitiesSupported'] = false;
      expect(await s.readSettings(), {SystemSetting.lockScreen: null});
      caps['lockScreenAllowed'] = true;
      expect(
        (await service(
          TargetPlatform.iOS,
        ).readSettings())[SystemSetting.lockScreen],
        true,
      );
    },
  );
  test(
    'settings are targeted with safe fallback and no permission prompts',
    () async {
      var fallback = 0;
      final s = service(
        TargetPlatform.android,
        settings: () async {
          fallback++;
          return true;
        },
      );
      expect(await s.settingsFor(setting: SystemSetting.liveActivities), true);
      expect(await s.settingsFor(setting: SystemSetting.lockScreen), true);
      expect(calls, ['requestLiveUpdates', 'openNotificationSettings']);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            channel,
            (_) async => throw PlatformException(code: 'unsupported'),
          );
      expect(await s.settingsFor(access: SystemAccess.notifications), true);
      expect(fallback, 1);
      expect(requested, isEmpty);
    },
  );
  test(
    'restricted or partially denied multi-permission groups are never granted',
    () {
      expect(
        DeviceSystemAccessService.mergePermissionStates([
          PermissionStatus.granted,
          PermissionStatus.permanentlyDenied,
        ]),
        PermissionStatus.permanentlyDenied,
      );
      expect(
        DeviceSystemAccessService.mergePermissionStates([
          PermissionStatus.denied,
          PermissionStatus.restricted,
        ]),
        PermissionStatus.restricted,
      );
      expect(
        DeviceSystemAccessService.mergePermissionStates([]),
        PermissionStatus.denied,
      );
    },
  );
}
