import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yanshu/features/home/models/schedule_item.dart';
import 'package:yanshu/features/home/repositories/schedule_repository.dart';
import 'package:yanshu/features/home/viewmodels/schedule_view_model.dart';
import 'package:yanshu/features/home/views/task_checklist_widget.dart';
import 'package:yanshu/app/theme/app_theme.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:yanshu/features/home/views/schedule_section.dart';

ScheduleItem task(String id, DateTime date, {bool dated = true}) =>
    ScheduleItem(
      id: id,
      title: '会议任务$id',
      startsAt: date,
      kind: ScheduleKind.task,
      hasDeadline: dated,
    );

void main() {
  testWidgets(
    'task tap opens its minutes action directly without the old detail sheet',
    (tester) async {
      const route = '/meetings/session/minutes?action=action-key';
      final item = ScheduleItem(
        id: 'minutes:session:action-key',
        title: '完成接口兼容性验证并提交测试结果',
        startsAt: DateTime.utc(2040),
        kind: ScheduleKind.task,
        sourceRoute: route,
      );
      final model = ScheduleViewModel(
        HomeMockScheduleRepository([item]),
        taskChecklist: true,
        listenToTime: false,
      );
      addTearDown(model.dispose);
      await model.refresh();
      model.selectDate(item.startsAt);
      final router = GoRouter(
        initialLocation: '/',
        routes: [
          GoRoute(
            path: '/',
            builder: (_, _) => const Scaffold(body: ScheduleSection()),
          ),
          GoRoute(
            path: '/meetings/:id/minutes',
            builder: (_, state) => Scaffold(
              body: Text('定位行动：${state.uri.queryParameters['action']}'),
            ),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: model,
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text(item.title));
      await tester.pumpAndSettle();
      expect(find.text('定位行动：action-key'), findsOneWidget);
      expect(find.byType(BottomSheet), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  test('清单隐藏逾期任务，保留未来与无交期任务，完成后刷新不复活', () async {
    final repo = HomeMockScheduleRepository([
      task('past', DateTime.utc(2020)),
      task('future', DateTime.utc(2040)),
      task('undated', DateTime.utc(1970), dated: false),
    ]);
    final vm = ScheduleViewModel(
      repo,
      taskChecklist: true,
      listenToTime: false,
    );
    addTearDown(vm.dispose);
    await vm.refresh();
    expect(vm.entries.map((e) => e.item.id), ['future', 'undated']);
    expect(await vm.complete('past'), isFalse);
    expect(await vm.complete('future'), isTrue);
    expect(vm.entries.first.item.completed, isTrue);
    vm.dismissCompleted('future');
    await vm.refresh();
    expect(vm.entries.map((e) => e.item.id), ['future', 'undated']);
    expect(await vm.complete('future'), isTrue);
    expect(vm.entries.first.item.completed, isFalse);
    await vm.refresh();
    expect(vm.entries.first.item.completed, isFalse);
  });

  testWidgets('后端确认后划线，再消失；失败不划线、不移除', (tester) async {
    final saved = Completer<bool>();
    var removed = false;
    var item = task('1', DateTime.utc(2030));
    Widget page(Future<bool> Function(String) submit) => MaterialApp(
      theme: AppTheme.light(),
      home: Scaffold(
        body: TaskChecklistWidget(
          entries: [
            ScheduleEntry(item, ScheduleStatus.upcoming, item.startsAt),
          ],
          expanded: true,
          savingId: null,
          onComplete: submit,
          onDismissed: (_) => removed = true,
          onOpen: (_) {},
        ),
      ),
    );
    await tester.pumpWidget(page((_) => saved.future));
    expect(tester.widget<Text>(find.text('会议任务1')).maxLines, 1);
    expect(
      tester.widget<Text>(find.text('会议任务1')).overflow,
      TextOverflow.ellipsis,
    );
    await tester.tap(find.byKey(const ValueKey('complete-task-1')));
    await tester.pump();
    expect(removed, isFalse);
    expect(find.text('已完成'), findsNothing);
    saved.complete(true);
    await tester.pump();
    item = item.complete();
    await tester.pumpWidget(page((_) async => true));
    await tester.pump();
    expect(
      tester.widget<Text>(find.text('会议任务1')).style!.decoration,
      TextDecoration.lineThrough,
    );
    expect(removed, isFalse);
    await tester.pump(const Duration(milliseconds: 420));
    await tester.pump(const Duration(milliseconds: 321));
    expect(removed, isFalse);
    // 换一个 key 重置本次任务的动画状态。
    await tester.pumpWidget(const SizedBox());
    removed = false;
    item = item.complete(completed: false);
    await tester.pumpWidget(page((_) async => false));
    await tester.tap(find.byKey(const ValueKey('complete-task-1')));
    await tester.pumpAndSettle();
    expect(removed, isFalse);
    expect(
      tester.widget<Text>(find.text('会议任务1')).style!.decoration,
      TextDecoration.none,
    );
  });
}
