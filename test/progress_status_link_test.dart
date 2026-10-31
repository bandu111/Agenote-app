import 'package:flutter_test/flutter_test.dart';
import 'package:yanshu/features/progress/models/progress_models.dart';
import 'package:yanshu/features/progress/repositories/progress_repository.dart';
import 'package:yanshu/features/progress/viewmodels/progress_view_model.dart';
import 'package:yanshu/features/notifications/notification_model.dart';

class TwoStageRepository extends MockProgressRepository
    implements ProgressCompletionRepository {
  TwoStageRepository(ProgressSnapshot superSeed) : super(seed: superSeed);
  bool filled = false;
  @override
  Future<ProgressSnapshot> load() async => filled
      ? super.load()
      : const ProgressSnapshot(
          demo: false,
          pending: [
            PendingProgressItem(
              id: 'candidate',
              kind: 'commitment',
              title: '提交报告',
              version: 1,
            ),
          ],
        );
  @override
  Future<void> completeMissing(
    PendingProgressItem item, {
    CommitmentSide? side,
    DateTime? deadline,
  }) async {
    if (side == null || deadline == null) throw StateError('missing');
    filled = true;
  }
}

class DelayedConfirmationRepository extends MockProgressRepository {
  DelayedConfirmationRepository(ProgressSnapshot seed) : super(seed: seed);
  int writes = 0;
  @override
  Future<void> updateCommitment(
    String id,
    CommitmentStatus status,
    String note,
  ) async {
    writes++;
  }
}

void main() {
  test('确认成功后旧 pending 回读不复活，旧内容不能再次确认', () async {
    final seed = await MockProgressRepository().load();
    final item = seed.commitments.first.revised(
      at: DateTime.now(),
      note: 'test',
      status: CommitmentStatus.pending,
      deadline: DateTime.now().add(const Duration(days: 2)),
    );
    final repo = DelayedConfirmationRepository(
      ProgressSnapshot(commitments: [item]),
    );
    final vm = ProgressViewModel(repo);
    final notices = NotificationModel()..bind(vm);
    addTearDown(vm.dispose);
    addTearDown(notices.dispose);
    await vm.load();
    final id = notices.items.single.id;
    expect(await notices.decide(id, allow: true), isTrue);
    await vm.load();
    expect(notices.stateOf(id), NoticeState.allowed);
    expect(await notices.decide(id, allow: true), isFalse);
    expect(repo.writes, 1);
    await vm.reschedule(
      item.id,
      item.deadline.add(const Duration(days: 1)),
      'test',
    );
    expect(await vm.confirmCommitment(item), isFalse);
    expect(repo.writes, 1);
  });
  test('待复核承诺不能在通知或详情确认，旧版本不能确认新内容', () async {
    final seed = await MockProgressRepository().load();
    final item = seed.commitments.first.revised(
      at: DateTime.now(),
      note: 'test',
      status: CommitmentStatus.pending,
      deadline: DateTime.now().add(const Duration(days: 2)),
    );
    final repo = MockProgressRepository(
      seed: ProgressSnapshot(
        commitments: [item],
        pending: [
          PendingProgressItem(
            id: item.id,
            kind: 'commitment',
            title: item.title,
            version: item.version,
            reviewPending: true,
          ),
        ],
      ),
    );
    final vm = ProgressViewModel(repo);
    final notices = NotificationModel()..bind(vm);
    addTearDown(vm.dispose);
    addTearDown(notices.dispose);
    await vm.load();
    expect(vm.canConfirm(item), isFalse);
    expect(notices.items, isEmpty);
    expect(await vm.confirmCommitment(item), isFalse);
  });

  test('确认通知暂不处理有反馈，清除后到期不复活', () async {
    final seed = await MockProgressRepository().load();
    final item = seed.commitments.first.revised(
      at: DateTime.now(),
      note: 'test',
      status: CommitmentStatus.pending,
      deadline: DateTime.now().add(const Duration(days: 2)),
    );
    final vm = ProgressViewModel(
      MockProgressRepository(seed: ProgressSnapshot(commitments: [item])),
    );
    final notices = NotificationModel()..bind(vm);
    addTearDown(vm.dispose);
    addTearDown(notices.dispose);
    await vm.load();
    expect(notices.pendingCount, 1);
    notices.postpone(notices.items.single.id);
    expect(notices.items, isEmpty);
    expect(vm.commitment(item.id)!.status, CommitmentStatus.pending);
    await vm.load();
    expect(notices.items, isEmpty);
    await vm.reschedule(
      item.id,
      DateTime.now().subtract(const Duration(days: 1)),
      'test',
    );
    expect(notices.items, isEmpty);
  });
  test('补全不等于确认，通知与进展在两阶段分别同步', () async {
    final seed = await MockProgressRepository().load();
    final item = seed.commitments.first.revised(
      at: DateTime.now(),
      note: 'test',
      status: CommitmentStatus.pending,
      deadline: DateTime.now().add(const Duration(days: 2)),
    );
    final vm = ProgressViewModel(
      TwoStageRepository(ProgressSnapshot(demo: false, commitments: [item])),
    );
    final notices = NotificationModel()..bind(vm);
    addTearDown(vm.dispose);
    addTearDown(notices.dispose);
    notices.onCompleteProgress = (pending) => vm.completeMissing(
      pending,
      side: CommitmentSide.ours,
      deadline: item.deadline,
    );
    await vm.load();
    expect(notices.items.single.allowLabel, '补全');
    expect(await notices.decide(notices.items.single.id, allow: true), isTrue);
    expect(vm.data.pending, isEmpty);
    expect(vm.commitment(item.id)!.status, CommitmentStatus.pending);
    expect(notices.items.single.allowLabel, '确认承诺');
    expect(await notices.decide(notices.items.single.id, allow: true), isTrue);
    expect(vm.commitment(item.id)!.status, CommitmentStatus.planned);
    expect(notices.items, isEmpty);
  });
  test('云端清空标记使无交期目标过期，不伪造交期或完成状态', () {
    const goal = ProgressGoal(
      id: 'cleared',
      title: '目标',
      code: '',
      phase: '',
      condition: '',
      acceptance: '',
      deadline: null,
      status: GoalStatus.pending,
      milestones: [],
      history: [],
      expiredByClear: true,
    );
    expect(goal.statusLabelAt(DateTime.now()), '已过期');
    expect(goal.deadlineLabel(DateTime.now()), '已过期');
    expect(goal.status, GoalStatus.pending);
    expect(goal.deadline, isNull);
  });

  test('云端已过期待补项不能从通知补全', () async {
    const pending = PendingProgressItem(
      id: 'cleared',
      kind: 'goal',
      title: '目标',
      version: 2,
      expiredByClear: true,
    );
    final vm = ProgressViewModel(
      MockProgressRepository(
        seed: const ProgressSnapshot(demo: false, pending: [pending]),
      ),
    );
    final notices = NotificationModel()..bind(vm);
    addTearDown(vm.dispose);
    addTearDown(notices.dispose);
    await vm.load();
    expect(notices.items.single.state, NoticeState.unavailable);
    expect(notices.pendingCount, 0);
    expect(await notices.decide(notices.items.single.id, allow: true), isFalse);
  });
  test('未确认承诺到期展示逾期，确认通知失效，原始确认状态不变', () async {
    final seed = await MockProgressRepository().load();
    final old = seed.commitments.first;
    final item = old.revised(
      at: DateTime.now(),
      note: 'test',
      status: CommitmentStatus.pending,
      deadline: DateTime.now().subtract(const Duration(days: 1)),
    );
    final vm = ProgressViewModel(
      MockProgressRepository(
        seed: ProgressSnapshot(demo: false, commitments: [item]),
      ),
    );
    final notices = NotificationModel()..bind(vm);
    addTearDown(vm.dispose);
    addTearDown(notices.dispose);
    await vm.load();
    expect(item.status, CommitmentStatus.pending);
    expect(item.statusAt(DateTime.now()), CommitmentStatus.overdue);
    expect(notices.items.single.state, NoticeState.unavailable);
    expect(await notices.decide(notices.items.single.id, allow: true), isFalse);
  });

  test('完整承诺确认后进入待履行并移除确认通知，保留待补数据', () async {
    final seed = await MockProgressRepository().load();
    final item = seed.commitments.first.revised(
      at: DateTime.now(),
      note: 'test',
      status: CommitmentStatus.pending,
      deadline: DateTime.now().add(const Duration(days: 1)),
    );
    const pending = PendingProgressItem(
      id: 'other',
      kind: 'goal',
      title: '另一目标',
      version: 1,
    );
    final vm = ProgressViewModel(
      MockProgressRepository(
        seed: ProgressSnapshot(
          demo: false,
          commitments: [item],
          pending: [pending],
        ),
      ),
    );
    final notices = NotificationModel()..bind(vm);
    addTearDown(vm.dispose);
    addTearDown(notices.dispose);
    await vm.load();
    final confirm = notices.items.firstWhere((n) => n.allowLabel == '确认承诺');
    expect(await notices.decide(confirm.id, allow: true), isTrue);
    expect(vm.commitment(item.id)!.status, CommitmentStatus.planned);
    expect(vm.data.pending.single.id, 'other');
    expect(vm.data.demo, isFalse);
    expect(notices.items.any((n) => n.allowLabel == '确认承诺'), isFalse);
  });
}
