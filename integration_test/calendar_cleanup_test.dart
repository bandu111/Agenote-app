import 'package:device_calendar/device_calendar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('核对并清理本次临时日历', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold()));
    final plugin = DeviceCalendarPlugin();
    expect((await plugin.requestPermissions()).data, isTrue);
    final before = await plugin.retrieveCalendars();
    expect(before.isSuccess, isTrue);
    final temporary = before.data!.where((c) => c.name == '言枢临时联调日历');
    var deleted = 0;
    for (final calendar in temporary) {
      final result = await plugin.deleteCalendar(calendar.id!);
      expect(result.isSuccess && result.data == true, isTrue);
      deleted++;
    }
    final after = await plugin.retrieveCalendars();
    expect(after.isSuccess, isTrue);
    final absent = !after.data!.any((c) => c.name == '言枢临时联调日历');
    expect(absent, isTrue);
    binding.reportData = {
      'synthetic_only': true,
      'temporary_calendar_absent_verified': absent,
      'temporary_calendars_deleted': deleted,
      'calendar_count_after_cleanup': after.data!.length,
      'calendar_event_created_in_failed_chain': false,
    };
  });
}
