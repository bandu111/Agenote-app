import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yanshu/features/progress/models/progress_models.dart';
import 'package:yanshu/features/progress/repositories/progress_repository.dart';
import 'package:yanshu/features/progress/viewmodels/progress_view_model.dart';
import 'package:yanshu/features/progress/views/progress_completion_sheet.dart';
import 'package:yanshu/features/notifications/notification_model.dart';

class CompletionRepository extends MockProgressRepository
    implements ProgressCompletionRepository {
  CompletionRepository(this.item);
  PendingProgressItem? item;
  CommitmentSide? savedSide;
  DateTime? savedDeadline;
  @override
  Future<ProgressSnapshot> load() async =>
      ProgressSnapshot(demo: false, pending: [?item]);
  @override
  Future<void> completeMissing(
    PendingProgressItem item, {
    CommitmentSide? side,
    DateTime? deadline,
  }) async {
    savedSide = side;
    savedDeadline = deadline;
    this.item = null;
  }
}

const pending = PendingProgressItem(
  id: 'p1',
  kind: 'commitment',
  title: '提交测试报告',
  version: 1,
);

void main() {
  test('尚在模型复核的候选保留在进展，但不催促用户补全', () async {
    final repo = CompletionRepository(
      const PendingProgressItem(
        id: 'preview',
        kind: 'commitment',
        title: '提交报告',
        version: 1,
        reviewPending: true,
      ),
    );
    final vm = ProgressViewModel(repo);
    final notices = NotificationModel()..bind(vm);
    await vm.load();
    expect(vm.data.pending, hasLength(1));
    expect(notices.items, isEmpty);
    repo.item = const PendingProgressItem(
      id: 'preview',
      kind: 'commitment',
      title: '提交报告',
      version: 2,
    );
    await vm.load();
    expect(notices.items, hasLength(1));
    notices.dispose();
    vm.dispose();
  });
  test('稍后和取消不会丢失待补记录，已补全后移除通知', () async {
    final repo = CompletionRepository(pending);
    final vm = ProgressViewModel(repo);
    final notices = NotificationModel()..bind(vm);
    await vm.load();
    final id = notices.items.single.id;
    expect(notices.items.single.allowLabel, '补全');
    expect(await notices.decide(id, allow: false), isTrue);
    expect(notices.pendingCount, 1);
    notices.onCompleteProgress = (_) async => false;
    await notices.decide(id, allow: true);
    expect(notices.error(id), isNull);
    expect(vm.data.pending, hasLength(1));
    notices.onCompleteProgress = (item) => vm.completeMissing(
      item,
      side: CommitmentSide.ours,
      deadline: DateTime(2026, 11, 1),
    );
    await notices.decide(id, allow: true);
    expect(notices.items, isEmpty);
    expect(repo.savedSide, CommitmentSide.ours);
    notices.dispose();
    vm.dispose();
  });

  testWidgets('补全只选我方或对方，不要求具体角色；保存缺失的日期', (tester) async {
    final repo = CompletionRepository(pending);
    final vm = ProgressViewModel(repo);
    await vm.load();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ProgressCompletionSheet(model: vm, item: pending),
        ),
      ),
    );
    expect(find.text('我方履约项'), findsOneWidget);
    expect(find.text('对方履约项'), findsOneWidget);
    expect(find.textContaining('技术负责人'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('complete-save')));
    await tester.pump();
    expect(find.text('请补全履约方和交期中的缺失项'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('complete-side-theirs')));
    await tester.tap(find.byKey(const ValueKey('complete-deadline')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('complete-save')));
    await tester.pumpAndSettle();
    expect(repo.savedSide, CommitmentSide.theirs);
    expect(repo.savedDeadline, isNotNull);
    expect(repo.savedDeadline!.hour, 23);
    vm.dispose();
  });

  testWidgets('只缺履约方时不展示日期输入', (tester) async {
    final item = PendingProgressItem(
      id: 'p2',
      kind: 'commitment',
      title: '交付',
      version: 1,
      deadline: DateTime(2026, 11, 1),
    );
    final vm = ProgressViewModel(CompletionRepository(item));
    await vm.load();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ProgressCompletionSheet(model: vm, item: item),
        ),
      ),
    );
    expect(find.byKey(const ValueKey('complete-deadline')), findsNothing);
    vm.dispose();
  });
}
