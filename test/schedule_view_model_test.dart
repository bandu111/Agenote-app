import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yanshu/features/home/models/schedule_item.dart';
import 'package:yanshu/features/home/repositories/schedule_repository.dart';
import 'package:yanshu/features/home/viewmodels/schedule_view_model.dart';
import 'test_schedule_clock.dart';

DateTime instant(int hour, [int minute = 0, int day = 14]) =>
    DateTime.utc(2026, 10, day, hour - 8, minute);
List<ScheduleItem> sample() => [
  ScheduleItem(
    id: 'progress',
    title: '项目进度对齐',
    startsAt: instant(14),
    endsAt: instant(15),
    kind: ScheduleKind.meeting,
  ),
  ScheduleItem(
    id: 'review',
    title: '产品方案评审',
    startsAt: instant(16),
    endsAt: instant(17),
    kind: ScheduleKind.meeting,
  ),
  ScheduleItem(
    id: 'login',
    title: '登录模块开发截止',
    startsAt: instant(18),
    kind: ScheduleKind.task,
  ),
];
Future<ScheduleViewModel> modelAt(int hour, [int minute = 0]) async {
  final model = ScheduleViewModel(
    HomeMockScheduleRepository(sample()),
    clock: TestScheduleClock(instant(hour, minute)),
    listenToTime: false,
  );
  await model.refresh();
  return model;
}

void main() {
  test(
    'failed completion does not report success or change current data',
    () async {
      final repository = _FailingWriteRepository(sample());
      final model = ScheduleViewModel(
        repository,
        clock: TestScheduleClock(instant(13)),
        listenToTime: false,
      );
      addTearDown(model.dispose);
      await model.refresh();
      expect(await model.complete('progress'), isFalse);
      expect(model.entries.first.item.completed, isFalse);
      expect(model.error, isNotNull);
      repository.failWrite = false;
      expect(await model.complete('progress'), isTrue);
      expect(model.entries.last.item.id, 'progress');
      expect(model.error, isNull);
    },
  );
  test(
    'upcoming starts sort ascending regardless repository ordering',
    () async {
      final model = ScheduleViewModel(
        HomeMockScheduleRepository(sample().reversed.toList()),
        clock: TestScheduleClock(instant(13)),
        listenToTime: false,
      );
      addTearDown(model.dispose);
      await model.refresh();
      expect(model.entries.map((e) => e.item.id), [
        'progress',
        'review',
        'login',
      ]);
      expect(
        model.entries.every((e) => e.status == ScheduleStatus.upcoming),
        isTrue,
      );
    },
  );
  test('ongoing first and exact end instant moves meeting to tail', () async {
    final model = await modelAt(14, 30);
    addTearDown(model.dispose);
    expect(model.entries.first.status, ScheduleStatus.ongoing);
    (model.clock as TestScheduleClock).value = instant(15);
    model.checkTime();
    expect(model.entries.map((e) => e.item.id), [
      'review',
      'login',
      'progress',
    ]);
    expect(model.entries.last.status, ScheduleStatus.ended);
  });
  test('manual completion moves item behind ended items', () async {
    final model = await modelAt(15);
    addTearDown(model.dispose);
    expect(await model.complete('review'), isTrue);
    expect(model.entries.map((e) => e.item.id), [
      'login',
      'progress',
      'review',
    ]);
    expect(model.entries.last.status, ScheduleStatus.completed);
    model.toggleExpanded();
    model.toggleExpanded();
    expect(model.entries.last.item.completed, isTrue);
  });
  test('deadline elapsed is overdue, never auto-completed', () async {
    final model = await modelAt(18);
    addTearDown(model.dispose);
    final task = model.entries.singleWhere((e) => e.item.id == 'login');
    expect(task.status, ScheduleStatus.overdue);
    expect(task.item.completed, isFalse);
  });
  test(
    'meeting without end needs review and cannot become completed',
    () async {
      final model = ScheduleViewModel(
        HomeMockScheduleRepository([
          ScheduleItem(
            id: 'unknown',
            title: '待确认时长',
            startsAt: instant(12),
            kind: ScheduleKind.meeting,
          ),
        ]),
        clock: TestScheduleClock(instant(19)),
        listenToTime: false,
      );
      addTearDown(model.dispose);
      await model.refresh();
      expect(model.entries.single.status, ScheduleStatus.needsReview);
      expect(model.entries.single.item.completed, isFalse);
    },
  );
  test(
    'resume reevaluates current time while retaining expanded state',
    () async {
      final model = await modelAt(14, 30);
      addTearDown(model.dispose);
      model.toggleExpanded();
      model.pause();
      (model.clock as TestScheduleClock).value = instant(15, 10);
      model.resume();
      expect(model.entries.first.item.id, 'review');
      expect(model.expanded, isTrue);
    },
  );
  test(
    'midnight shows new day without duplicating or inventing events',
    () async {
      final model = ScheduleViewModel(
        HomeMockScheduleRepository([
          ...sample(),
          ScheduleItem(
            id: 'tomorrow',
            title: '次日安排',
            startsAt: instant(9, 0, 15),
            endsAt: instant(10, 0, 15),
            kind: ScheduleKind.meeting,
          ),
        ]),
        clock: TestScheduleClock(instant(23, 59)),
        listenToTime: false,
      );
      addTearDown(model.dispose);
      await model.refresh();
      expect(model.entries.length, 3);
      (model.clock as TestScheduleClock).value = instant(0, 0, 15);
      model.checkTime();
      expect(model.entries.map((e) => e.item.id), ['tomorrow']);
    },
  );
  test('timezone-bearing instants filter by device calendar day', () async {
    final item = ScheduleItem(
      id: 'other-zone',
      title: '跨时区会议',
      startsAt: DateTime.parse('2026-10-15T00:30:00+09:00'),
      endsAt: DateTime.parse('2026-10-15T01:00:00+09:00'),
      sourceTimeZone: 'Asia/Tokyo',
      kind: ScheduleKind.meeting,
    );
    final clock = TestScheduleClock(instant(23, 40));
    final model = ScheduleViewModel(
      HomeMockScheduleRepository([item]),
      clock: clock,
      listenToTime: false,
    );
    addTearDown(model.dispose);
    await model.refresh();
    expect(model.entries.single.timeLabel, '23:30');
    expect(model.entries.single.status, ScheduleStatus.ongoing);
  });
  test(
    'cross-midnight ongoing meeting is shown on the intersecting day',
    () async {
      final model = ScheduleViewModel(
        HomeMockScheduleRepository([
          ScheduleItem(
            id: 'overnight',
            title: '跨日会议',
            startsAt: instant(23, 0, 13),
            endsAt: instant(1),
            kind: ScheduleKind.meeting,
          ),
        ]),
        clock: TestScheduleClock(instant(0, 30)),
        listenToTime: false,
      );
      addTearDown(model.dispose);
      await model.refresh();
      expect(model.entries.single.status, ScheduleStatus.ongoing);
    },
  );
  test('device timezone changes are respected when resuming', () async {
    final clock = TestScheduleClock(instant(23, 30));
    final model = ScheduleViewModel(
      HomeMockScheduleRepository(sample()),
      clock: clock,
      listenToTime: false,
    );
    addTearDown(model.dispose);
    await model.refresh();
    clock.offset = const Duration(hours: 10);
    model.resume();
    expect(model.entries, isEmpty);
  });
  test(
    'automatic boundary timer, no unnecessary notifications, and disposal',
    () {
      fakeAsync((async) {
        final anchor = instant(14, 59);
        final clock = _ElapsedClock(() => anchor.add(async.elapsed));
        final model = ScheduleViewModel(
          HomeMockScheduleRepository(sample()),
          clock: clock,
        );
        var updates = 0;
        model.addListener(() => updates++);
        model.refresh();
        async.flushMicrotasks();
        final initial = updates;
        async.elapse(const Duration(seconds: 30));
        expect(updates, initial);
        async.elapse(const Duration(seconds: 30));
        expect(model.entries.first.item.id, 'review');
        expect(updates, initial + 1);
        model.pause();
        expect(async.nonPeriodicTimerCount, 0);
        model.resume();
        expect(async.nonPeriodicTimerCount, 1);
        model.dispose();
        expect(async.nonPeriodicTimerCount, 0);
      });
    },
  );
  test('empty repository, one item, and two items preserve data', () async {
    for (final count in [0, 1, 2]) {
      final model = ScheduleViewModel(
        HomeMockScheduleRepository(sample().take(count).toList()),
        clock: TestScheduleClock(instant(13)),
        listenToTime: false,
      );
      await model.refresh();
      expect(model.entries.length, count);
      model.dispose();
    }
  });
}

class _FailingWriteRepository extends HomeMockScheduleRepository {
  _FailingWriteRepository(super.items);
  bool failWrite = true;
  @override
  Future<void> markCompleted(String id) async {
    if (failWrite) throw StateError('simulated local write failure');
    await super.markCompleted(id);
  }
}

class _ElapsedClock implements ScheduleClock {
  _ElapsedClock(this.read);
  final DateTime Function() read;
  @override
  DateTime get now => read();
  @override
  DateTime toLocal(DateTime instant) =>
      instant.toUtc().add(const Duration(hours: 8));
  @override
  DateTime get nextMidnight {
    final date = toLocal(now);
    return DateTime.utc(
      date.year,
      date.month,
      date.day + 1,
    ).subtract(const Duration(hours: 8));
  }
}
