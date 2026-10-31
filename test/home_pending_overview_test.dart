import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:yanshu/features/home/models/schedule_item.dart';
import 'package:yanshu/features/home/repositories/schedule_repository.dart';
import 'package:yanshu/features/home/viewmodels/schedule_view_model.dart';
import 'package:yanshu/features/home/views/schedule_section.dart';
import 'test_schedule_clock.dart';

void main() {
  testWidgets(
    'global pending count opens other dates, completion stays visible for undo and date jump',
    (tester) async {
      final clock = TestScheduleClock(DateTime.utc(2026, 10, 31, 6));
      final repo = HomeMockScheduleRepository([
        for (var i = 0; i < 20; i++)
          ScheduleItem(
            id: 'task-$i',
            title: '历史会议行动 $i',
            startsAt: DateTime.utc(2026, 10, 22, 3),
            sourceMeetingDate: DateTime(2026, 10, 22),
            kind: ScheduleKind.task,
            hasDeadline: false,
          ),
      ]);
      final model = ScheduleViewModel(
        repo,
        clock: clock,
        listenToTime: false,
        taskChecklist: true,
      );
      addTearDown(model.dispose);
      await model.refresh();
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: model,
          child: const MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(child: ScheduleSection()),
            ),
          ),
        ),
      );
      expect(find.text('20项待完成'), findsOneWidget);
      expect(find.text('当天没有任务或会议'), findsOneWidget);
      expect(find.text('还有20项待办在其他日期'), findsOneWidget);
      expect(find.text('历史会议行动 0'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('timeline-pending-count')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('timeline-pending-overview')),
        findsOneWidget,
      );
      final complete = find
          .byKey(const ValueKey('complete-task-task-0'))
          .hitTestable();
      await tester.tap(complete);
      await tester.pumpAndSettle();
      expect(model.pendingTaskCount, 19);
      final title = find.text('历史会议行动 0').hitTestable();
      expect(title, findsOneWidget);
      expect(
        tester.widget<Text>(title).style?.decoration,
        TextDecoration.lineThrough,
      );
      await tester.tap(
        find.byKey(const ValueKey('complete-task-task-0')).hitTestable(),
      );
      await tester.pumpAndSettle();
      expect(model.pendingTaskCount, 20);
      expect(
        tester.widget<Text>(title).style?.decoration,
        isNot(TextDecoration.lineThrough),
      );
      await tester.tap(
        find.byKey(const ValueKey('timeline-locate-2026-10-22')),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('timeline-pending-overview')),
        findsNothing,
      );
      expect(model.selectedDate, DateTime(2026, 10, 22));
      expect(model.selectedEntries, hasLength(20));
      expect(
        find.byKey(const ValueKey('timeline-task-dot-2026-10-22')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'home vertical PageStorage offset cannot restore as calendar week after rebuilding',
    (tester) async {
      final clock = TestScheduleClock(DateTime.utc(2026, 10, 31, 6));
      final model = ScheduleViewModel(
        HomeMockScheduleRepository([]),
        clock: clock,
        listenToTime: false,
      );
      addTearDown(model.dispose);
      await model.refresh();
      final bucket = PageStorageBucket();
      var visible = true;
      late StateSetter rebuild;
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: model,
          child: MaterialApp(
            home: Scaffold(
              body: PageStorage(
                bucket: bucket,
                child: KeyedSubtree(
                  key: const PageStorageKey('home-scroll'),
                  child: StatefulBuilder(
                    builder: (_, update) {
                      rebuild = update;
                      return SingleChildScrollView(
                        child: visible
                            ? const ScheduleSection()
                            : const SizedBox(),
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      rebuild(() => visible = false);
      await tester.pumpAndSettle();
      bucket.writeState(
        tester.element(find.byKey(const PageStorageKey('home-scroll'))),
        962.0,
      );
      rebuild(() => visible = true);
      await tester.pumpAndSettle();
      final controller = tester
          .widget<PageView>(find.byKey(const ValueKey('timeline-weeks')))
          .controller!;
      expect(controller.page, 1000);
      expect(model.selectedDate.year, 2026);
      expect(model.selectedDate.month, 10);
      expect(model.selectedDate.day, 31);
      expect(tester.takeException(), isNull);
    },
  );

  test(
    'explicit home refresh returns to today while background refresh retains chosen day',
    () async {
      final clock = TestScheduleClock(DateTime.utc(2026, 10, 31, 6));
      final model = ScheduleViewModel(
        HomeMockScheduleRepository([]),
        clock: clock,
        listenToTime: false,
      );
      addTearDown(model.dispose);
      await model.refresh();
      model.selectDate(DateTime(2026, 10, 22));
      await model.refresh();
      expect(model.selectedDate, DateTime(2026, 10, 22));
      await model.refresh(resetDateToToday: true);
      expect(model.selectedDate.month, 10);
      expect(model.selectedDate.day, 31);
    },
  );
}
