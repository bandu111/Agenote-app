import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:yanshu/features/progress/models/progress_models.dart';
import 'package:yanshu/features/progress/repositories/progress_repository.dart';
import 'package:yanshu/features/progress/viewmodels/progress_view_model.dart';
import 'package:yanshu/features/progress/viewmodels/voice_evidence_controller.dart';

void main() {
  test('撤回记录刷新后仍保留数据，但列表搜索和目标关联统一隐藏', () async {
    final model = ProgressViewModel(MockProgressRepository());
    addTearDown(model.dispose);
    await model.load();
    final item = model.commitment('commitment-3')!;
    expect(
      await model.updateCommitment(item.id, CommitmentStatus.withdrawn, '用户移除'),
      isTrue,
    );
    await model.load();
    expect(model.commitment(item.id)!.status, CommitmentStatus.withdrawn);
    expect(
      model.commitment(item.id)!.history.last.description,
      contains('用户移除'),
    );
    expect(model.listedCommitments.any((c) => c.id == item.id), isFalse);
    expect(
      model.commitmentsFor(item.goalId).any((c) => c.id == item.id),
      isFalse,
    );
    model.selectSide(item.side);
    expect(model.selectedCommitments.any((c) => c.id == item.id), isFalse);
    expect(
      model
          .search(item.title)
          .any((hit) => hit.path == '/progress/commitments/${item.id}'),
      isFalse,
    );
  });

  test(
    'milestone weights produce 68%, empty milestones produce zero',
    () async {
      final data = await MockProgressRepository().load();
      expect(data.goals.first.progress, .68);
      final goal = data.goals.first;
      final empty = ProgressGoal(
        id: 'empty',
        title: '',
        code: '',
        phase: '',
        condition: '',
        acceptance: '',
        deadline: goal.deadline,
        status: GoalStatus.active,
        milestones: [],
        history: [],
      );
      expect(empty.progress, 0);
      expect(goal.status, GoalStatus.active);
    },
  );
  test(
    'side and artifact counts, filters and search are data driven',
    () async {
      final vm = ProgressViewModel(MockProgressRepository());
      addTearDown(vm.dispose);
      await vm.load();
      expect(vm.followUpCount(CommitmentSide.ours), 2);
      expect(vm.followUpCount(CommitmentSide.theirs), 3);
      expect(ArtifactFilter.values.map(vm.artifactCount), [6, 1, 3, 2]);
      vm.selectSide(CommitmentSide.theirs);
      expect(
        vm.selectedCommitments.every((c) => c.side == CommitmentSide.theirs),
        isTrue,
      );
      vm.selectArtifacts(ArtifactFilter.accepted);
      expect(vm.visibleArtifacts.length, 2);
      expect(
        vm.visibleArtifacts.every((a) => a.status == ArtifactStatus.verified),
        isTrue,
      );
      expect(vm.search('Windows').single.kind, '通知');
      expect(vm.search('技术评估').any((h) => h.kind == '承诺'), isTrue);
      expect(vm.search('不存在').isEmpty, isTrue);
    },
  );
  test(
    'claim is distinct from verification and verification requires separate change',
    () async {
      final vm = ProgressViewModel(MockProgressRepository());
      addTearDown(vm.dispose);
      await vm.load();
      expect(
        await vm.updateCommitment(
          'commitment-0',
          CommitmentStatus.verified,
          '跳过声明',
        ),
        isFalse,
      );
      expect(vm.commitment('commitment-0')!.status, CommitmentStatus.active);
      expect(
        await vm.updateCommitment(
          'commitment-0',
          CommitmentStatus.claimed,
          '自报提交',
        ),
        isTrue,
      );
      expect(vm.commitment('commitment-0')!.status, CommitmentStatus.claimed);
      expect(
        await vm.updateCommitment(
          'commitment-0',
          CommitmentStatus.verified,
          '',
        ),
        isFalse,
      );
      expect(
        await vm.updateCommitment(
          'commitment-0',
          CommitmentStatus.verified,
          '模拟核对交付清单',
        ),
        isTrue,
      );
      expect(vm.commitment('commitment-0')!.history.length, 3);
      expect(vm.followUpCount(CommitmentSide.ours), 1);
    },
  );
  test('deadline changes and withdrawal preserve old records', () async {
    final vm = ProgressViewModel(MockProgressRepository());
    addTearDown(vm.dispose);
    await vm.load();
    final original = vm.commitment('commitment-0')!;
    final next = original.deadline.add(const Duration(days: 2));
    expect(await vm.reschedule(original.id, next, '双方另行约定'), isTrue);
    final changed = vm.commitment(original.id)!;
    expect(changed.deadline, next);
    expect(
      changed.history.last.description,
      contains(progressDate(original.deadline)),
    );
    expect(
      await vm.updateCommitment(
        original.id,
        CommitmentStatus.withdrawn,
        '范围取消',
      ),
      isTrue,
    );
    expect(vm.commitment(original.id)!.withdrawalReason, contains('范围取消'));
    expect(vm.commitment(original.id)!.history.length, 3);
  });
  test(
    'overdue is derived, claims do not automatically expire or verify',
    () async {
      final data = await MockProgressRepository(
        now: DateTime(2026, 10, 16),
      ).load();
      expect(
        data.commitments.first.statusAt(DateTime(2026, 11)),
        CommitmentStatus.overdue,
      );
      expect(
        data.commitments.last.statusAt(DateTime(2026, 11)),
        CommitmentStatus.claimed,
      );
    },
  );
  test(
    'approval records current version and does not verify or externally execute',
    () async {
      final vm = ProgressViewModel(MockProgressRepository());
      addTearDown(vm.dispose);
      await vm.load();
      expect(await vm.approveArtifact('artifact-0', '同意当前草稿'), isTrue);
      expect(vm.artifact('artifact-0')!.status, ArtifactStatus.approved);
      expect(vm.artifact('artifact-0')!.approvalNote, contains('v1.2'));
      expect(vm.artifactCount(ArtifactFilter.accepted), 2);
      expect(await vm.approveArtifact('artifact-0', '重复批准'), isFalse);
    },
  );
  test('empty, retry and failed update preserve current data', () async {
    final repo = FailingProgressRepository();
    final vm = ProgressViewModel(repo);
    addTearDown(vm.dispose);
    await vm.load();
    expect(vm.error, isNotNull);
    repo.fail = false;
    await vm.load();
    expect(vm.error, isNull);
    expect(vm.data.goals, isEmpty);
    expect(
      await vm.updateCommitment('missing', CommitmentStatus.claimed, '测试'),
      isFalse,
    );
    expect(vm.data.commitments, isEmpty);
    expect(vm.actionError, isNotNull);
  });
  test('disposed model ignores pending load', () async {
    final repo = DelayedProgressRepository();
    final vm = ProgressViewModel(repo);
    final future = vm.load();
    vm.dispose();
    repo.result.complete(const ProgressSnapshot());
    await future;
  });
  test(
    'missing or unauthorized evidence never starts a simulated recording',
    () async {
      final player = FakeEvidencePlayer();
      final controller = VoiceEvidenceController(player: player);
      addTearDown(controller.dispose);
      final data = await MockProgressRepository().load();
      await controller.toggle(data.commitments.first.evidence);
      expect(controller.state, VoicePlaybackState.unavailable);
      expect(controller.message, '示例音频未提供');
      expect(player.plays, 0);
      await controller.toggle(
        evidence('private', access: EvidenceAccess.denied),
      );
      expect(controller.message, contains('授权'));
      expect(player.plays, 0);
    },
  );
  test(
    'one player handles pause, seek, switch, completion and release',
    () async {
      final player = FakeEvidencePlayer();
      final controller = VoiceEvidenceController(player: player);
      await controller.toggle(evidence('a'));
      expect(controller.state, VoicePlaybackState.playing);
      await controller.seek(const Duration(seconds: 15));
      expect(controller.position.inSeconds, 15);
      await controller.toggle(evidence('a'));
      expect(controller.state, VoicePlaybackState.paused);
      await controller.toggle(evidence('a'));
      expect(controller.state, VoicePlaybackState.playing);
      await controller.toggle(evidence('b'));
      expect(player.opened, ['a', 'b']);
      expect(player.stops, 2);
      player.completed.add(null);
      await Future<void>.delayed(Duration.zero);
      expect(controller.position, Duration.zero);
      expect(controller.state, VoicePlaybackState.idle);
      await controller.suspend();
      expect(controller.state, VoicePlaybackState.idle);
      controller.dispose();
      await Future<void>.delayed(Duration.zero);
      expect(player.disposed, isTrue);
    },
  );
  test('backgrounding during audio open prevents late playback', () async {
    final player = FakeEvidencePlayer()..pendingOpen = Completer<void>();
    final controller = VoiceEvidenceController(player: player);
    addTearDown(controller.dispose);
    final opening = controller.toggle(evidence('a'));
    await Future<void>.delayed(Duration.zero);
    await controller.suspend();
    player.pendingOpen!.complete();
    await opening;
    expect(player.plays, 0);
    expect(controller.state, VoicePlaybackState.idle);
  });
}

VoiceEvidence evidence(
  String id, {
  EvidenceAccess access = EvidenceAccess.authorized,
}) => VoiceEvidence(
  id: id,
  commitmentId: 'c',
  sessionId: 's',
  uri: Uri.parse('asset:///authorized.wav'),
  start: const Duration(seconds: 10),
  end: const Duration(seconds: 48),
  transcript: '测试素材',
  recordedAt: DateTime(2026, 10, 16),
  timeZone: 'Asia/Shanghai',
  source: EvidenceSource.provided,
  access: access,
);

class FailingProgressRepository extends MockProgressRepository {
  FailingProgressRepository() : super(seed: const ProgressSnapshot());
  bool fail = true;
  @override
  Future<ProgressSnapshot> load() async {
    if (fail) throw StateError('offline');
    return super.load();
  }
}

class DelayedProgressRepository extends MockProgressRepository {
  final result = Completer<ProgressSnapshot>();
  @override
  Future<ProgressSnapshot> load() => result.future;
}

class FakeEvidencePlayer implements EvidenceAudioPlayer {
  final updates = StreamController<Duration>.broadcast();
  final completed = StreamController<void>.broadcast();
  Completer<void>? pendingOpen;
  final opened = <String>[];
  int plays = 0, stops = 0;
  bool disposed = false;
  @override
  Stream<Duration> get positions => updates.stream;
  @override
  Stream<void> get completions => completed.stream;
  @override
  Future<void> open(VoiceEvidence value) async {
    opened.add(value.id);
    await pendingOpen?.future;
  }

  @override
  Future<void> play() async {
    plays++;
  }

  @override
  Future<void> pause() async {}
  @override
  Future<void> stop() async {
    stops++;
  }

  @override
  Future<void> seek(Duration value) async {
    updates.add(value);
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    await updates.close();
    await completed.close();
  }
}
