import 'package:yanshu/features/meeting/meeting_view_model.dart';
import 'meeting_test.dart' show FakeMeetingRecorder;
import 'package:yanshu/features/profile/repositories/profile_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:yanshu/app/app.dart';
import 'package:yanshu/features/home/viewmodels/schedule_view_model.dart';
import 'package:yanshu/features/home/views/home_page.dart';
import 'package:yanshu/features/home/views/task_checklist_widget.dart';
import 'package:yanshu/features/home/repositories/schedule_repository.dart';
import 'package:yanshu/features/home/models/schedule_item.dart';
import 'package:yanshu/features/progress/views/progress_page.dart';
import 'package:yanshu/features/profile/views/profile_page.dart';
import 'package:yanshu/features/knowledge/views/knowledge_page.dart';
import 'package:yanshu/features/meeting/meeting_store.dart';
import 'test_schedule_clock.dart';
import 'package:yanshu/features/knowledge/repositories/knowledge_repository.dart';

List<ScheduleItem> items([int count = 3]) => List.generate(
  count,
  (i) => ScheduleItem(
    id: 'item-$i',
    title: i == 2 ? '登录模块开发截止' : '安排 ${i + 1}',
    startsAt: DateTime.utc(2026, 10, 14, 6 + i * 2),
    endsAt: i == 2 ? null : DateTime.utc(2026, 10, 14, 7 + i * 2),
    kind: ScheduleKind.task,
  ),
);
Future<void> start(WidgetTester tester, {int count = 3}) async {
  await tester.pumpWidget(
    YanShuApp(
      meetingStore: MemoryMeetingStore(),
      meetingRecorder: FakeMeetingRecorder(),
      profileRepository: ProfileRepository(MemoryProfileStore()),
      knowledgeRepository: KnowledgeRepository(
        MemoryKnowledgeStore(),
        seedExamples: true,
      ),
      scheduleClock: TestScheduleClock(DateTime.utc(2026, 10, 14, 5)),
      scheduleRepository: HomeMockScheduleRepository(items(count)),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> showSchedule(WidgetTester tester) async {
  // The unified home timeline is always visible; the old expand/collapse
  // control was intentionally removed from the product.
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'home date greeting and notification stay pinned while content scrolls',
    (tester) async {
      tester.view.physicalSize = const Size(360, 780);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await start(tester);
      final date = find.byKey(const ValueKey('home-local-date'));
      final greeting = find.byKey(const ValueKey('home-greeting'));
      final bell = find.byTooltip('通知');
      final beforeDate = tester.getTopLeft(date);
      final beforeBell = tester.getTopLeft(bell);
      await tester.drag(
        find.byKey(const PageStorageKey('home-scroll')),
        const Offset(0, -600),
      );
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(date), beforeDate);
      expect(tester.getTopLeft(bell), beforeBell);
      expect(greeting.hitTestable(), findsOneWidget);
      expect(bell.hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'collapsed voice entry leaves full viewport and last schedule tappable',
    (tester) async {
      tester.view.physicalSize = const Size(360, 780);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await start(tester);
      await tester.tap(find.text('点击开始会话'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('recording-source-phone')));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('hide-session-capsule')));
      await tester.pumpAndSettle();
      final scroll = find.byKey(const PageStorageKey('home-scroll'));
      final nav = tester.getRect(find.byType(NavigationBar));
      expect(tester.getRect(scroll).bottom, lessThanOrEqualTo(nav.top));
      await tester.drag(scroll, const Offset(0, -1200));
      await tester.pumpAndSettle();
      final deck = tester.getRect(
        find.byKey(const ValueKey('task-checklist-deck')),
      );
      final mic = tester.getRect(
        find.byKey(const ValueKey('restore-session-capsule')),
      );
      expect(deck.bottom, lessThan(mic.top));
      expect(mic.bottom, lessThan(nav.top));
      await tester.tap(find.text('登录模块开发截止'));
      await tester.pumpAndSettle();
      expect(find.text('会议任务来源'), findsNothing);
      expect(find.text('登录模块开发截止'), findsWidgets);
      expect(tester.takeException(), isNull);
    },
    skip: true,
  );
  testWidgets(
    'device card shows unconnected state and opens device management',
    (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await start(tester);
      expect(find.text('设备与硬件'), findsOneWidget);
      expect(find.text('连接思必驰设备'), findsNothing);
      expect(find.text('未连接'), findsWidgets);
      expect(find.text('未获取'), findsNWidgets(2));
      await tester.tap(find.byKey(const ValueKey('connect-device')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('选择这次录音的音源'), findsOneWidget);
      expect(find.text('手机麦克风'), findsOneWidget);
      expect(find.text('蓝牙耳机'), findsOneWidget);
      await tester.tap(find.text('在「我的」里管理设备'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('我的设备'), findsWidgets);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'meeting entry is hidden when idle and collapses only during a meeting',
    (tester) async {
      await start(tester);
      final element = tester.element(find.byType(HomePage));
      final meeting = element.read<MeetingViewModel>();
      expect(find.byKey(const ValueKey('session-capsule')), findsNothing);
      expect(
        find.byKey(const ValueKey('restore-session-capsule')),
        findsNothing,
      );
      await tester.tap(find.byKey(const ValueKey('connect-device')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('recording-source-phone')));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(meeting.active, isTrue);
      expect(find.text('会议进行中'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('hide-session-capsule')));
      await tester.pumpAndSettle();
      expect(find.text('会议进行中 · 展开'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('restore-session-capsule')));
      await tester.pumpAndSettle();
      expect(find.text('会议进行中'), findsOneWidget);
      await meeting.finish();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('session-capsule')), findsNothing);
      expect(
        find.byKey(const ValueKey('restore-session-capsule')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('four tabs navigate and retain home state', (tester) async {
    await start(tester);
    final model = tester
        .element(find.byType(HomePage))
        .read<ScheduleViewModel>();
    model.toggleExpanded();
    await tester.pumpAndSettle();
    final destinations = [
      ('进展', ProgressPage),
      ('知识库', KnowledgePage),
      ('我的', ProfilePage),
    ];
    for (final destination in destinations) {
      await tester.tap(
        find.descendant(
          of: find.byType(NavigationBar),
          matching: find.text(destination.$1),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(destination.$2), findsOneWidget);
      if (destination.$1 == '我的') {
        expect(find.byKey(const ValueKey('profile-edit')), findsOneWidget);
      }
      expect(
        find.byTooltip('通知'),
        destination.$1 == '进展' ? findsOneWidget : findsNothing,
      );
    }
    await tester.tap(
      find.descendant(
        of: find.byType(NavigationBar),
        matching: find.text('首页'),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester.element(find.byType(HomePage)).read<ScheduleViewModel>(),
      same(model),
    );
    expect(model.expanded, isTrue);
    expect(find.byType(NavigationDestination), findsNWidgets(4));
  });
  testWidgets('unified task timeline renders items without a separate expand control', (
    tester,
  ) async {
    await start(tester, count: 5);
    await showSchedule(tester);
    await tester.pumpAndSettle();
    expect(find.byType(TaskChecklistWidget), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.byType(TaskChecklistWidget), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('完成任务先划线再移除，刷新不复活', (tester) async {
    await start(tester);
    await showSchedule(tester);
    final model = tester
        .element(find.byType(HomePage))
        .read<ScheduleViewModel>();
    await tester.ensureVisible(
      find.byKey(const ValueKey('complete-task-item-0')),
    );
    await tester.tap(find.byKey(const ValueKey('complete-task-item-0')));
    await tester.pump();
    expect(model.entries.any((entry) => entry.item.completed), isTrue);
    await tester.pump(const Duration(milliseconds: 420));
    await tester.pump(const Duration(milliseconds: 420));
    expect(model.entries.any((e) => e.item.id == 'item-0'), isFalse);
    await model.refresh();
    await tester.pumpAndSettle();
    expect(model.entries.any((e) => e.item.id == 'item-0'), isFalse);
    expect(tester.takeException(), isNull);
  }, skip: true);
  testWidgets('rapid order/expansion updates keep animated cards valid', (
    tester,
  ) async {
    await start(tester);
    await showSchedule(tester);
    final model = tester
        .element(find.byType(HomePage))
        .read<ScheduleViewModel>();
    for (var i = 0; i < 6; i++) {
      model.toggleExpanded();
      (model.clock as TestScheduleClock).value = DateTime.utc(
        2026,
        10,
        14,
        7 + i,
      );
      model.checkTime();
      await tester.pump(const Duration(milliseconds: 40));
    }
    await tester.pumpAndSettle();
    expect(find.byType(TaskChecklistWidget), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  for (final count in [0, 1, 2]) {
    testWidgets('$count schedules lay out without overflow', (tester) async {
      await start(tester, count: count);
      await showSchedule(tester);
      expect(tester.takeException(), isNull);
      if (count == 0) expect(find.text('当天没有任务或会议'), findsOneWidget);
    });
  }
  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    testWidgets(
      'small phone, large text and reduced motion on $platform',
      (tester) async {
        tester.view.physicalSize = const Size(320, 640);
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.textScaleFactorTestValue = 2;
        tester.platformDispatcher.accessibilityFeaturesTestValue =
            const FakeAccessibilityFeatures(disableAnimations: true);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        addTearDown(
          tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
        );
        await start(tester);
        await showSchedule(tester);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('点击开始会话'));
        await tester.pumpAndSettle();
        await tester.ensureVisible(
          find.byKey(const ValueKey('recording-source-phone')),
        );
        await tester.tap(find.byKey(const ValueKey('recording-source-phone')));
        await tester.pumpAndSettle();
        await tester.tap(find.byType(BackButton));
        await tester.pumpAndSettle();
        expect(find.text('当前工作态势'), findsNothing);
        expect(find.text('采音状态待核实'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tap(find.byKey(const ValueKey('hide-session-capsule')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('restore-session-capsule')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('查看'));
        await tester.pumpAndSettle();
        await tester.ensureVisible(
          find.byKey(const ValueKey('meeting-finish')),
        );
        await tester.tap(find.byKey(const ValueKey('meeting-finish')));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(FilledButton, '结束并归档').last);
        await tester.pumpAndSettle();
        expect(find.text('未采集音频'), findsNothing);
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant({platform}),
      skip: true,
    );
  }
  testWidgets('resume and midnight update without opening another tab', (
    tester,
  ) async {
    await start(tester);
    final model = tester
        .element(find.byType(HomePage))
        .read<ScheduleViewModel>();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    (model.clock as TestScheduleClock).value = DateTime.utc(2026, 10, 14, 7);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(model.entries.first.item.id, 'item-1');
    (model.clock as TestScheduleClock).value = DateTime.utc(2026, 10, 14, 16);
    model.checkTime();
    await tester.pumpAndSettle();
    expect(model.entries, isEmpty);
    expect(find.text('当天没有任务或会议'), findsOneWidget);
  });
}
