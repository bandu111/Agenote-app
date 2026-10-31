import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:yanshu/features/home/models/schedule_item.dart';
import 'package:yanshu/features/home/repositories/schedule_repository.dart';
import 'package:yanshu/features/home/viewmodels/schedule_view_model.dart';
import 'package:yanshu/features/home/views/schedule_section.dart';
import 'test_schedule_clock.dart';

void main() {
  testWidgets(
    'calendar filters days and shows task above meeting, completion persists',
    (t) async {
      final clock = TestScheduleClock(DateTime.utc(2030, 10, 28, 0));
      final repo = HomeMockScheduleRepository([
        ScheduleItem(
          id: 'task',
          title: '提交报告',
          startsAt: DateTime.utc(2030, 10, 29, 9),
          kind: ScheduleKind.task,
        ),
        ScheduleItem(
          id: 'meeting',
          title: 'ERP评审',
          startsAt: DateTime.utc(2030, 10, 29, 6),
          endsAt: DateTime.utc(2030, 10, 29, 7),
          kind: ScheduleKind.meeting,
        ),
        ScheduleItem(
          id: 'expired',
          title: '昨日会议',
          startsAt: DateTime.utc(2030, 10, 27, 6),
          endsAt: DateTime.utc(2030, 10, 27, 7),
          kind: ScheduleKind.meeting,
        ),
        ScheduleItem(
          id: 'undated',
          title: '来源会议没有指定交期的任务',
          startsAt: DateTime.utc(2030, 10, 26, 3),
          kind: ScheduleKind.task,
          hasDeadline: false,
        ),
      ]);
      final vm = ScheduleViewModel(
        repo,
        clock: clock,
        taskChecklist: true,
        listenToTime: false,
      );
      addTearDown(vm.dispose);
      await vm.refresh();
      vm.selectDate(DateTime(2030, 10, 29));
      await t.pumpWidget(
        ChangeNotifierProvider.value(
          value: vm,
          child: MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(child: ScheduleSection()),
            ),
          ),
        ),
      );
      expect(find.text('来源会议没有指定交期的任务'), findsNothing);
      expect(find.byKey(const ValueKey('undated-task-section')), findsNothing);
      expect(find.text('ERP评审'), findsOneWidget);
      expect(find.text('提交报告'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('timeline-task-dot-2030-10-29')),
        findsOneWidget,
      );
      final meetingTile = t.widget<ListTile>(
        find.byKey(const ValueKey('timeline-meeting-meeting')),
      );
      expect(meetingTile.onTap, isNull);
      expect(
        t.getTopLeft(find.text('提交报告')).dy,
        lessThan(t.getTopLeft(find.text('ERP评审')).dy),
      );
      await t.tap(find.byKey(const ValueKey('complete-task-task')));
      await t.pumpAndSettle();
      expect((await repo.load()).first.completed, true);
      expect(find.text('提交报告'), findsOneWidget);
      expect(
        t.widget<Text>(find.text('提交报告')).style?.decoration,
        TextDecoration.lineThrough,
      );
      expect(find.text('1项待完成'), findsOneWidget);
      final previousDay = vm.selectedDate;
      await t.drag(
        find.byKey(const ValueKey('timeline-weeks')),
        const Offset(-650, 0),
      );
      await t.pumpAndSettle();
      expect(vm.selectedDate.difference(previousDay).inDays, 7);
      vm.selectDate(DateTime(2030, 10, 27));
      await t.pumpAndSettle();
      expect(find.text('已过期'), findsOneWidget);
      expect(find.text('来源会议没有指定交期的任务'), findsNothing);
      vm.selectDate(DateTime(2030, 10, 26));
      await t.pumpAndSettle();
      expect(find.text('来源会议没有指定交期的任务'), findsOneWidget);
      expect(find.text('交期待明确'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('timeline-task-dot-2030-10-26')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('timeline-task-dot-2030-10-25')),
        findsNothing,
      );
      expect(
        vm.entriesOn(DateTime(2030, 10, 26)).single.status,
        ScheduleStatus.upcoming,
      );
      expect(find.text('已归档'), findsNothing);
      expect(t.takeException(), isNull);
    },
  );

  testWidgets('权威未来会议仅由独立校验 CTA 打开会前准备，旧会议 tile 不可点击', (tester) async {
    final clock = TestScheduleClock(DateTime.utc(2030, 10, 28));
    final repo = HomeMockScheduleRepository([
      ScheduleItem(
        id: 'prepared',
        title: '已核验项目会',
        startsAt: DateTime.utc(2030, 10, 29, 6),
        endsAt: DateTime.utc(2030, 10, 29, 7),
        kind: ScheduleKind.meeting,
        authority: 'authenticated_device_receipt_fields_matched',
        preparationId: 'prep-1',
        preparationStatus: 'succeeded',
        preparationSummary: '核对客户范围与历史决定。',
        preparationRoute: '/outcomes/prep-1',
      ),
      ScheduleItem(
        id: 'queued',
        title: '准备中会议',
        startsAt: DateTime.utc(2030, 10, 29, 8),
        kind: ScheduleKind.meeting,
        authority: 'authenticated_device_receipt_fields_matched',
        preparationId: 'prep-2',
        preparationStatus: 'queued',
        preparationSummary: '这段未完成内容不应展示',
        preparationRoute: '/outcomes/prep-2',
      ),
      ScheduleItem(
        id: 'unsafe',
        title: '危险入口会议',
        startsAt: DateTime.utc(2030, 10, 29, 10),
        kind: ScheduleKind.meeting,
        authority: 'authenticated_device_receipt_fields_matched',
        preparationId: 'prep-3',
        preparationStatus: 'succeeded',
        preparationRoute: 'https://evil.example/outcomes/prep-3',
      ),
    ]);
    final vm = ScheduleViewModel(
      repo,
      clock: clock,
      taskChecklist: true,
      listenToTime: false,
    );
    addTearDown(vm.dispose);
    await vm.refresh();
    vm.selectDate(DateTime(2030, 10, 29));
    final router = GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => const Scaffold(
            body: SingleChildScrollView(child: ScheduleSection()),
          ),
        ),
        GoRoute(
          path: '/outcomes/:id',
          builder: (_, state) =>
              Scaffold(body: Text('opened:${state.pathParameters['id']}')),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: vm,
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
    final tile = tester.widget<ListTile>(
      find.byKey(const ValueKey('timeline-meeting-prepared')),
    );
    expect(tile.onTap, isNull);
    await tester.tap(find.byKey(const ValueKey('timeline-meeting-prepared')));
    await tester.pumpAndSettle();
    expect(find.text('opened:prep-1'), findsNothing);
    expect(find.text('核对客户范围与历史决定。'), findsOneWidget);
    expect(find.text('会前准备已排队'), findsOneWidget);
    expect(find.text('这段未完成内容不应展示'), findsNothing);
    expect(find.byKey(const ValueKey('open-preparation-unsafe')), findsNothing);
    await tester.ensureVisible(
      find.byKey(const ValueKey('open-preparation-prepared')),
    );
    await tester.tap(find.byKey(const ValueKey('open-preparation-prepared')));
    await tester.pumpAndSettle();
    expect(find.text('opened:prep-1'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
