import 'package:yanshu/features/home/viewmodels/schedule_view_model.dart';

class TestScheduleClock implements ScheduleClock {
  TestScheduleClock(this.value, {this.offset = const Duration(hours: 8)});
  DateTime value;
  Duration offset;
  @override
  DateTime get now => value;
  @override
  DateTime toLocal(DateTime instant) => instant.toUtc().add(offset);
  @override
  DateTime get nextMidnight {
    final day = toLocal(now);
    return DateTime.utc(day.year, day.month, day.day + 1).subtract(offset);
  }
}
