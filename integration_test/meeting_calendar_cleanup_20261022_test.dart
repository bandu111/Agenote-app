import 'package:device_calendar/device_calendar.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('只清理本轮日志记载的空测试日历，不触及已有日程', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: Center(child: Text('清理本轮测试日历'))),
      ),
    );
    final plugin = DeviceCalendarPlugin();
    expect((await plugin.requestPermissions()).data, isTrue);
    final before = await plugin.retrieveCalendars();
    expect(before.isSuccess, isTrue);
    var deleted = 0;
    // 这些 ID 来自本轮失败/成功测试日志，不按日历名称批量删除。
    const ids = ['9', '10', '11', '12'];
    for (final calendar in before.data!) {
      if (!ids.contains(calendar.id) || calendar.name != '言枢') continue;
      deleted +=
          (await const MethodChannel(
            'yanshu/calendar_compat',
          ).invokeMethod<int>('deleteEmptyTestCalendar', {
            'calendarId': calendar.id,
            'marker': '[yanshu:test-cleanup:empty]',
          })) ??
          0;
    }
    final after = await plugin.retrieveCalendars();
    expect(after.isSuccess, isTrue);
    expect(after.data!.where((c) => ids.contains(c.id)), isEmpty);
    binding.reportData = {
      'knownTestCalendarsAbsent': true,
      'deletedEmptyCalendars': deleted,
    };
    debugPrint('CALENDAR_CLEANUP_REPORT ${binding.reportData}');
  });
}
