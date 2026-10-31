import 'package:flutter_test/flutter_test.dart';
import 'package:yanshu/features/meeting/minutes/meeting_minutes_data.dart';
import 'package:yanshu/features/home/models/schedule_item.dart';
import 'package:yanshu/features/home/views/task_checklist_widget.dart';

void main() {
  test(
    'minutes action and home task use the same resolved date and clock time',
    () {
      final raw = {
        'id': 'a',
        'text': '提交报告',
        'evidence_ids': ['u1'],
        'deadline': '下周一下午三点',
        'deadlineAt': '2030-11-04T15:00:00+08:00',
        'deadlineHasTime': true,
      };
      final action = MinutesEntry.fromJson(raw);
      final date = DateTime.parse(raw['deadlineAt'] as String).toLocal();
      final item = ScheduleItem(
        id: 'a',
        title: '提交报告',
        startsAt: date,
        kind: ScheduleKind.task,
        deadlineHasTime: true,
      );
      expect(
        action.deadlineLabel,
        taskDeadlineLabel(ScheduleEntry(item, ScheduleStatus.upcoming, date)),
      );
    },
  );
  test('date-only action never displays an invented 23:59 deadline', () {
    final action = MinutesEntry.fromJson({
      'deadline': '明天',
      'deadlineAt': '2030-11-01T23:59:00+08:00',
      'deadlineHasTime': false,
    });
    final date = DateTime.parse(action.deadlineAt!).toLocal();
    final item = ScheduleItem(
      id: 'a',
      title: '提交报告',
      startsAt: date,
      kind: ScheduleKind.task,
      deadlineHasTime: false,
    );
    expect(
      action.deadlineLabel,
      taskDeadlineLabel(ScheduleEntry(item, ScheduleStatus.upcoming, date)),
    );
    expect(action.deadlineLabel, isNot(contains('23:59')));
  });
}
