import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:yanshu/features/profile/services/system_access.dart';
import 'profile_page_test.dart' as helpers;

class ManagedAccess extends helpers.FakeSystemAccess
    implements SystemAccessSettingsService {
  bool granted = false;
  SystemSetting? opened;
  int calendarRequests = 0;
  @override
  Future<Map<SystemAccess, PermissionStatus>> read() async => {
    for (final access in SystemAccess.values)
      access: access == SystemAccess.photos
          ? PermissionStatus.limited
          : granted
          ? PermissionStatus.granted
          : PermissionStatus.denied,
  };
  @override
  Future<void> request(SystemAccess access) async {
    if (access == SystemAccess.calendar) calendarRequests++;
  }

  @override
  Future<Map<SystemSetting, bool?>> readSettings() async => {
    SystemSetting.liveActivities: granted,
    SystemSetting.lockScreen: null,
  };
  @override
  Future<bool> settingsFor({
    SystemAccess? access,
    SystemSetting? setting,
  }) async {
    opened = setting;
    return true;
  }
}

void main() {
  testWidgets(
    'all managed permissions show real states and refresh after settings return',
    (t) async {
      helpers.profilePhone(t);
      final s = ManagedAccess();
      await helpers.openProfile(t, permissions: s);
      await helpers.profileTap(
        t,
        find.byKey(const ValueKey('profile-permissions')),
      );
      for (final access in SystemAccess.values) {
        expect(
          find.byKey(ValueKey('system-permission-${access.name}')),
          findsOneWidget,
        );
      }
      expect(find.text('仅允许部分照片'), findsOneWidget);
      await helpers.profileTap(
        t,
        find.byKey(const ValueKey('system-setting-liveActivities')),
      );
      expect(s.opened, SystemSetting.liveActivities);
      expect(find.text('由系统管理，点击查看'), findsOneWidget);
      s.granted = true;
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await t.pumpAndSettle();
      expect(find.text('未允许，前往系统设置开启'), findsNothing);
      await helpers.profileTap(
        t,
        find.byKey(const ValueKey('system-permission-calendar')),
      );
      expect(
        s.calendarRequests,
        0,
      ); // Already granted: settings, no new calendar or permission request.
      expect(t.takeException(), isNull);
    },
  );
  testWidgets('calendar authorization is explicit and never creates an event', (
    t,
  ) async {
    helpers.profilePhone(t);
    final s = ManagedAccess();
    await helpers.openProfile(t, permissions: s);
    await helpers.profileTap(
      t,
      find.byKey(const ValueKey('profile-permissions')),
    );
    await helpers.profileTap(
      t,
      find.byKey(const ValueKey('system-permission-calendar')),
    );
    expect(s.calendarRequests, 0);
    await helpers.profileTap(t, find.text('取消'));
    expect(s.calendarRequests, 0);
    await helpers.profileTap(
      t,
      find.byKey(const ValueKey('system-permission-calendar')),
    );
    await helpers.profileTap(t, find.text('继续'));
    expect(s.calendarRequests, 1);
    expect(t.takeException(), isNull);
  });
}
