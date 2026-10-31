import 'package:yanshu/features/progress/widgets/voice_evidence_player.dart';
import 'package:go_router/go_router.dart';
import 'dart:async';
import 'package:yanshu/features/profile/repositories/profile_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:yanshu/app/app.dart';
import 'package:yanshu/features/progress/models/progress_models.dart';
import 'package:yanshu/features/progress/repositories/progress_repository.dart';
import 'package:yanshu/features/progress/viewmodels/progress_view_model.dart';
import 'package:yanshu/features/progress/views/progress_page.dart';
import 'package:yanshu/features/progress/widgets/goal_topology.dart';
import 'package:yanshu/features/knowledge/repositories/knowledge_repository.dart';
import 'package:yanshu/features/knowledge/viewmodels/knowledge_view_model.dart';
import 'package:yanshu/features/knowledge/widgets/knowledge_components.dart';
import 'progress_view_model_test.dart' show FailingProgressRepository;

Future<void> openProgress(
  WidgetTester tester, {
  ProgressRepository? repository,
  String initialLocation = '/affairs',
}) async {
  await tester.pumpWidget(
    YanShuApp(
      profileRepository: ProfileRepository(MemoryProfileStore()),
      knowledgeRepository: KnowledgeRepository(
        MemoryKnowledgeStore(),
        seedExamples: true,
      ),
      initialLocation: initialLocation,
      progressRepository: repository ?? MockProgressRepository(),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> jump(WidgetTester tester, int index) async {
  await tester.ensureVisible(find.byKey(ValueKey('progress-section-$index')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(ValueKey('progress-section-$index')));
  await tester.pumpAndSettle();
}

Future<void> tapVisible(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

class FailedCommitmentConfirmationRepository extends MockProgressRepository {
  @override
  Future<void> updateCommitment(
    String id,
    CommitmentStatus status,
    String note,
  ) async => throw StateError('offline');
}

class FailedGoalRemovalRepository extends MockProgressRepository {
  @override
  Future<void> removeGoal(String id) async => throw StateError('offline');
}

class DelayedCommitmentConfirmationRepository extends MockProgressRepository {
  final gate = Completer<void>();
  int writes = 0;
  @override
  Future<void> updateCommitment(
    String id,
    CommitmentStatus status,
    String note,
  ) async {
    writes++;
    await gate.future;
    await super.updateCommitment(id, status, note);
  }
}

void main() {
  testWidgets(
    'failed goal removal retains detail and offers retry without hiding the goal',
    (tester) async {
      final repo = FailedGoalRemovalRepository();
      await openProgress(
        tester,
        repository: repo,
        initialLocation: '/progress/goals/goal-delivery',
      );
      await tapVisible(tester, find.byKey(const ValueKey('remove-goal')));
      await tester.tap(find.byKey(const ValueKey('remove-goal-submit')));
      await tester.pumpAndSettle();
      expect(find.text('目标详情'), findsOneWidget);
      expect(find.byKey(const ValueKey('remove-goal')), findsOneWidget);
      expect(
        (await repo.load()).goals.any((g) => g.id == 'goal-delivery'),
        isTrue,
      );
      expect(find.text('更新未完成，请重试并核对当前状态'), findsOneWidget);
    },
  );
  testWidgets(
    'goal removal uses bottom sheet, cancelling keeps data and confirmation preserves commitments',
    (tester) async {
      final repo = MockProgressRepository();
      final before = await repo.load();
      await openProgress(
        tester,
        repository: repo,
        initialLocation: '/progress/goals/goal-delivery',
      );
      await tapVisible(tester, find.byKey(const ValueKey('remove-goal')));
      expect(find.text('移除这个目标？'), findsOneWidget);
      expect(find.byType(BottomSheet), findsOneWidget);
      expect(find.byType(Dialog), findsNothing);
      expect(
        find.text('移除后不再出现在目标列表与本周统计里。对应的承诺、依据和会议原话仍保留在记录中。'),
        findsOneWidget,
      );
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect((await repo.load()).goals.length, before.goals.length);
      await tapVisible(tester, find.byKey(const ValueKey('remove-goal')));
      await tester.tap(find.byKey(const ValueKey('remove-goal-submit')));
      await tester.pumpAndSettle();
      final after = await repo.load();
      expect(after.goals.any((g) => g.id == 'goal-delivery'), isFalse);
      expect(after.commitments.length, before.commitments.length);
      expect(after.artifacts.length, before.artifacts.length);
      expect(find.text('目标详情'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  for (final id in ['commitment-1', 'commitment-0', 'commitment-2']) {
    testWidgets('$id待履行或进行中可直接声明完成，保留移除并自动隐藏提示', (tester) async {
      await openProgress(tester, initialLocation: '/progress/commitments/$id');
      final complete = find.byKey(const ValueKey('complete-commitment'));
      final remove = find.byKey(const ValueKey('remove-commitment'));
      final model = tester.element(complete).read<ProgressViewModel>();
      expect(find.byKey(const ValueKey('confirm-commitment')), findsNothing);
      final left = tester.getRect(complete);
      final right = tester.getRect(remove);
      expect(left.center.dy, closeTo(right.center.dy, 1));
      expect(left.width, closeTo(right.width, 1));
      await tapVisible(tester, complete);
      expect(find.byType(Dialog), findsNothing);
      expect(find.text('承诺详情'), findsOneWidget);
      expect(model.commitment(id)!.status, CommitmentStatus.claimed);
      expect(
        model.commitment(id)!.history.last.description,
        contains('用户声明承诺已完成，待核实'),
      );
      expect(find.text('声称完成'), findsOneWidget);
      expect(complete, findsNothing);
      expect(remove, findsOneWidget);
      expect(find.text('已标记为声称完成'), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(find.text('已标记为声称完成'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('逾期但底层待履行的承诺仍可补报完成', (tester) async {
    final data = await MockProgressRepository().load();
    final repo = MockProgressRepository(
      seed: ProgressSnapshot(
        demo: true,
        commitments: data.commitments
            .map(
              (c) => c.id == 'commitment-1'
                  ? c.revised(
                      at: DateTime.now(),
                      note: '测试逾期',
                      deadline: DateTime.now().subtract(
                        const Duration(days: 1),
                      ),
                    )
                  : c,
            )
            .toList(),
      ),
    );
    await openProgress(
      tester,
      repository: repo,
      initialLocation: '/progress/commitments/commitment-1',
    );
    expect(find.text('已逾期'), findsOneWidget);
    final complete = find.byKey(const ValueKey('complete-commitment'));
    final model = tester.element(complete).read<ProgressViewModel>();
    await tapVisible(tester, complete);
    expect(model.commitment('commitment-1')!.status, CommitmentStatus.claimed);
    expect(find.text('声称完成'), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
  testWidgets('声明完成请求期间阻止重复提交', (tester) async {
    final repo = DelayedCommitmentConfirmationRepository();
    await openProgress(
      tester,
      repository: repo,
      initialLocation: '/progress/commitments/commitment-1',
    );
    final complete = find.byKey(const ValueKey('complete-commitment'));
    await tester.ensureVisible(complete);
    await tester.pumpAndSettle();
    await tester.tap(complete);
    await tester.pump();
    expect(find.text('正在提交…'), findsOneWidget);
    expect(tester.widget<FilledButton>(complete).onPressed, isNull);
    expect(
      tester
          .widget<OutlinedButton>(
            find.byKey(const ValueKey('remove-commitment')),
          )
          .onPressed,
      isNull,
    );
    await tester.tap(complete);
    expect(repo.writes, 1);
    repo.gate.complete();
    await tester.pumpAndSettle();
    expect(complete, findsNothing);
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
  testWidgets('声明完成失败保留原状态及按钮供重试', (tester) async {
    await openProgress(
      tester,
      repository: FailedCommitmentConfirmationRepository(),
      initialLocation: '/progress/commitments/commitment-1',
    );
    final complete = find.byKey(const ValueKey('complete-commitment'));
    final model = tester.element(complete).read<ProgressViewModel>();
    await tapVisible(tester, complete);
    expect(model.commitment('commitment-1')!.status, CommitmentStatus.planned);
    expect(complete, findsOneWidget);
    expect(find.text('已标记为声称完成'), findsNothing);
    expect(tester.takeException(), isNull);
  });
  testWidgets('已声称完成不再提供完成按钮', (tester) async {
    await openProgress(
      tester,
      initialLocation: '/progress/commitments/commitment-4',
    );
    expect(find.byKey(const ValueKey('complete-commitment')), findsNothing);
    expect(find.byKey(const ValueKey('confirm-commitment')), findsNothing);
    expect(find.byKey(const ValueKey('remove-commitment')), findsOneWidget);
  });

  for (final scale in [1.0, 2.2]) {
    testWidgets('320宽度与字号$scale下直接确认，顶部提示两秒消失且原页刷新', (tester) async {
      tester.view.physicalSize = const Size(320, 740);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await openProgress(
        tester,
        initialLocation: '/progress/commitments/commitment-3',
      );
      final button = find.byKey(const ValueKey('confirm-commitment'));
      final model = tester.element(button).read<ProgressViewModel>();
      await tapVisible(tester, button);
      expect(find.byType(Dialog), findsNothing);
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('承诺详情'), findsOneWidget);
      expect(
        model.commitment('commitment-3')!.status,
        CommitmentStatus.planned,
      );
      expect(find.text('待履行'), findsOneWidget);
      expect(button, findsNothing);
      expect(find.byKey(const ValueKey('complete-commitment')), findsOneWidget);
      expect(find.byKey(const ValueKey('remove-commitment')), findsOneWidget);
      final notice = find.byKey(const ValueKey('commitment-confirm-notice'));
      expect(notice, findsOneWidget);
      expect(
        find.ancestor(of: notice, matching: find.byType(AppBar)),
        findsOneWidget,
      );
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(notice, findsNothing);
      expect(find.text('承诺详情'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('待确认同时显示确认与移除，取消无变更，移除写撤回并返回列表', (tester) async {
    tester.view.physicalSize = const Size(320, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await openProgress(
      tester,
      initialLocation: '/progress/commitments/commitment-3',
    );
    final remove = find.byKey(const ValueKey('remove-commitment'));
    final model = tester.element(remove).read<ProgressViewModel>();
    expect(find.byKey(const ValueKey('confirm-commitment')), findsOneWidget);
    final confirmBounds = tester.getRect(
      find.byKey(const ValueKey('confirm-commitment')),
    );
    final removeBounds = tester.getRect(remove);
    expect(confirmBounds.center.dy, closeTo(removeBounds.center.dy, 1));
    expect(confirmBounds.width, closeTo(removeBounds.width, 1));
    expect(confirmBounds.right, lessThan(removeBounds.left));
    await tapVisible(tester, remove);
    expect(find.textContaining('当前不支持恢复'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(model.commitment('commitment-3')!.status, CommitmentStatus.pending);
    await tapVisible(tester, remove);
    await tester.tap(find.byKey(const ValueKey('remove-commitment-submit')));
    await tester.pumpAndSettle();
    expect(find.text('承诺详情'), findsNothing);
    expect(
      model.commitment('commitment-3')!.status,
      CommitmentStatus.withdrawn,
    );
    expect(model.listedCommitments.any((c) => c.id == 'commitment-3'), isFalse);
    expect(
      model
          .search('接口')
          .any((hit) => hit.path == '/progress/commitments/commitment-3'),
      isFalse,
    );
    expect(tester.takeException(), isNull);
  });
  testWidgets('移除失败不退出详情、不隐藏记录并保留重试', (tester) async {
    await openProgress(
      tester,
      repository: FailedCommitmentConfirmationRepository(),
      initialLocation: '/progress/commitments/commitment-0',
    );
    final remove = find.byKey(const ValueKey('remove-commitment'));
    final model = tester.element(remove).read<ProgressViewModel>();
    expect(find.byKey(const ValueKey('confirm-commitment')), findsNothing);
    await tapVisible(tester, remove);
    await tester.tap(find.byKey(const ValueKey('remove-commitment-submit')));
    await tester.pumpAndSettle();
    expect(find.text('承诺详情'), findsOneWidget);
    expect(remove, findsOneWidget);
    expect(model.commitment('commitment-0')!.status, CommitmentStatus.active);
    expect(find.text('更新未完成，请重试并核对当前状态'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  for (final status in [
    CommitmentStatus.verified,
    CommitmentStatus.withdrawn,
  ]) {
    testWidgets('$status不提供确认或移除入口', (tester) async {
      final data = await MockProgressRepository().load();
      final repo = MockProgressRepository(
        seed: ProgressSnapshot(
          demo: true,
          commitments: data.commitments
              .map(
                (c) => c.id == 'commitment-3'
                    ? c.revised(
                        at: DateTime(2026),
                        note: '测试终止状态',
                        status: status,
                      )
                    : c,
              )
              .toList(),
        ),
      );
      await openProgress(
        tester,
        repository: repo,
        initialLocation: '/progress/commitments/commitment-3',
      );
      expect(find.byKey(const ValueKey('confirm-commitment')), findsNothing);
      expect(find.byKey(const ValueKey('remove-commitment')), findsNothing);
      expect(find.byKey(const ValueKey('complete-commitment')), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('直接确认请求期间禁用两个按钮，防重复提交且离页清理提示计时器', (tester) async {
    final repo = DelayedCommitmentConfirmationRepository();
    await openProgress(
      tester,
      repository: repo,
      initialLocation: '/progress/commitments/commitment-3',
    );
    final button = find.byKey(const ValueKey('confirm-commitment'));
    await tester.ensureVisible(button);
    await tester.pumpAndSettle();
    await tester.tap(button);
    await tester.pump();
    expect(find.byType(Dialog), findsNothing);
    expect(find.text('正在确认…'), findsOneWidget);
    expect(tester.widget<FilledButton>(button).onPressed, isNull);
    expect(
      tester
          .widget<OutlinedButton>(
            find.byKey(const ValueKey('remove-commitment')),
          )
          .onPressed,
      isNull,
    );
    await tester.tap(button);
    expect(repo.writes, 1);
    repo.gate.complete();
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('commitment-confirm-notice')),
      findsOneWidget,
    );
    GoRouter.of(tester.element(find.text('承诺详情'))).go('/affairs');
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 2));
    expect(
      find.byKey(const ValueKey('commitment-confirm-notice')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });
  testWidgets('确认承诺失败保留待确认状态和重试入口', (tester) async {
    await openProgress(
      tester,
      repository: FailedCommitmentConfirmationRepository(),
      initialLocation: '/progress/commitments/commitment-3',
    );
    final button = find.byKey(const ValueKey('confirm-commitment'));
    await tapVisible(tester, button);
    expect(button, findsOneWidget);
    expect(find.byType(Dialog), findsNothing);
    expect(
      find.byKey(const ValueKey('commitment-confirm-notice')),
      findsNothing,
    );
    expect(
      tester
          .element(button)
          .read<ProgressViewModel>()
          .commitment('commitment-3')!
          .status,
      CommitmentStatus.pending,
    );
    expect(find.text('更新未完成，请重试并核对当前状态'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('进展搜索在页内展开，空结果和收起后恢复原列表', (tester) async {
    await openProgress(tester);
    await tester.tap(find.byKey(const ValueKey('progress-search')));
    await tester.pumpAndSettle();
    final input = find.byKey(const ValueKey('progress-search-input'));
    expect(input, findsOneWidget);
    expect(find.byType(NavigationBar), findsOneWidget);
    await tester.enterText(input, '不存在的进展关键词');
    await tester.pumpAndSettle();
    expect(find.text('没有找到相关进展'), findsOneWidget);
    await tester.tap(find.byTooltip('收起搜索'));
    await tester.pumpAndSettle();
    expect(input, findsNothing);
    expect(find.byKey(const ValueKey('goal-goal-delivery')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'goal details use the topology for delivery, acceptance, phase and all milestones',
    (tester) async {
      await openProgress(tester);
      await tapVisible(
        tester,
        find.byKey(const ValueKey('goal-goal-delivery')),
      );
      expect(find.text('目标详情'), findsOneWidget);
      expect(find.byType(GoalTopology), findsOneWidget);
      final graph = tester.widget<GoalTopology>(find.byType(GoalTopology));
      expect(graph.goal.milestones.length, 5);
      expect(
        find.byKey(const ValueKey('goal-topology-node-milestone-4')),
        findsOneWidget,
      );
      expect(find.text(graph.goal.code), findsNothing);
      expect(find.text('关联成果'), findsNothing);
      expect(find.text('最近状态变化'), findsNothing);
      expect(find.byType(KnowledgeReferenceCard), findsNWidgets(2));
      expect(find.byType(KnowledgeDocumentCard), findsNothing);
      expect(find.textContaining(RegExp(r'\d+% 匹配')), findsNWidgets(2));
      expect(
        find.byKey(const ValueKey('goal-commitment-commitment-0')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('goal-commitment-commitment-2')),
        findsNothing,
      );
      await tapVisible(tester, find.text('全部承诺'));
      expect(
        find.byKey(const ValueKey('goal-commitment-commitment-4')),
        findsOneWidget,
      );
      expect(find.text('1.0x'), findsNothing);
      expect(find.byIcon(Icons.more_horiz), findsNothing);
      final firstCommitment = tester
          .element(find.byType(GoalTopology))
          .read<ProgressViewModel>()
          .commitmentsFor(graph.goal.id)
          .first;
      await tapVisible(tester, find.text(firstCommitment.title));
      expect(find.text('目标详情'), findsOneWidget);
      expect(find.text('承诺详情'), findsNothing);
      await tapVisible(tester, find.byKey(const ValueKey('play-voice-0')));
      expect(find.text('示例音频未提供'), findsWidgets);
      final kb = tester
          .element(find.byType(GoalTopology))
          .read<KnowledgeViewModel>();
      await tapVisible(
        tester,
        find.byKey(const ValueKey('goal-knowledge-demo-scope')),
      );
      expect(find.text('资料详情'), findsOneWidget);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      await kb.delete('demo-scope');
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('goal-knowledge-demo-scope')),
        findsNothing,
      );
      await kb.delete('demo-guide');
      await tester.pumpAndSettle();
      expect(find.byType(KnowledgeReferenceCard), findsNothing);
      expect(find.text('暂无匹配资料'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('section shortcuts scroll and side switch and Tab retain state', (
    tester,
  ) async {
    await openProgress(tester);
    await jump(tester, 1);
    await tester.tap(find.byKey(const ValueKey('commitment-side-1')));
    await tester.pumpAndSettle();
    expect(find.text('提供预发环境访问方式与测试账号'), findsOneWidget);
    final model = tester
        .element(find.byType(ProgressPage))
        .read<ProgressViewModel>();
    expect(model.side, CommitmentSide.theirs);
    for (final tab in ['首页', '进展']) {
      await tester.tap(
        find.descendant(
          of: find.byType(NavigationBar),
          matching: find.text(tab),
        ),
      );
      await tester.pumpAndSettle();
    }
    expect(model.side, CommitmentSide.theirs);
    expect(find.byKey(const ValueKey('progress-section-2')), findsNothing);
    await jump(tester, 0);
    expect(
      find.byKey(const ValueKey('goal-goal-delivery')).hitTestable(),
      findsOneWidget,
    );
    expect(model.side, CommitmentSide.theirs);
    expect(tester.takeException(), isNull);
  });
  testWidgets('manual scrolling updates selected section', (tester) async {
    await openProgress(tester);
    final side = find.byKey(const ValueKey('commitment-side-0'));
    await tester.ensureVisible(side);
    await tester.pumpAndSettle();
    final selected = find
        .ancestor(
          of: find.byKey(const ValueKey('progress-section-1')),
          matching: find.byType(Semantics),
        )
        .first;
    expect(tester.widget<Semantics>(selected).properties.selected, isTrue);
  });
  testWidgets(
    'commitment detail restores LYZ evidence, goal and source meeting layout',
    (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await openProgress(tester);
      final topPill = find.byKey(const ValueKey('progress-section-0'));
      expect(tester.getSize(topPill).height, greaterThanOrEqualTo(48));
      final visual = find
          .descendant(of: topPill, matching: find.byType(DecoratedBox))
          .first;
      expect(tester.getSize(visual).height, lessThanOrEqualTo(33));
      await jump(tester, 1);
      expect(find.text('相关会话'), findsNothing);
      expect(find.text('关联目标'), findsNothing);
      expect(find.text('更新进展'), findsNothing);
      await tapVisible(tester, find.byKey(const ValueKey('play-voice-0')));
      expect(find.text('示例音频未提供'), findsWidgets);
      expect(find.byIcon(Icons.pause_circle_filled), findsNothing);
      await tapVisible(
        tester,
        find.byKey(const ValueKey('commitment-commitment-0')),
      );
      expect(find.text('承诺详情'), findsOneWidget);
      expect(find.text('承诺信息'), findsOneWidget);
      expect(find.byType(VoiceEvidencePlayer), findsWidgets);
      expect(find.text('关联目标'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('commitment-source-meeting')),
        findsOneWidget,
      );
      expect(find.byTooltip('查看语音证据'), findsNothing);
      expect(find.byType(NavigationBar), findsNothing);
      for (final removed in ['历史状态变化', '相关成果与附件', '履行进展', '查看来源信息', '更新进展']) {
        expect(find.text(removed), findsNothing);
      }
      expect(find.byType(KnowledgeReferenceCard), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('search opens a short notification instead of artifact details', (
    tester,
  ) async {
    await openProgress(tester);
    await tester.tap(find.byKey(const ValueKey('progress-search')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Windows');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Windows 需求影响评估'));
    await tester.pumpAndSettle();
    expect(find.text('通知'), findsOneWidget);
    expect(find.text('成果预览'), findsNothing);
    expect(find.text('内容预览'), findsNothing);
    await tapVisible(
      tester,
      find.byKey(const ValueKey('allow-artifact:artifact-0:v1.2')),
    );
    expect(find.text('已确认'), findsOneWidget);
    expect(find.text('已验证'), findsNothing);
    expect(tester.takeException(), isNull);
  });
  testWidgets('failed load retries into honest empty sections', (tester) async {
    final repo = FailingProgressRepository();
    await openProgress(tester, repository: repo);
    expect(find.text('进展暂时加载失败，请重试'), findsOneWidget);
    repo.fail = false;
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('还没有持续目标'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('progress-notifications')));
    await tester.pumpAndSettle();
    expect(find.text('暂无通知'), findsOneWidget);
  });
  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    testWidgets(
      'progress small phone large text on $platform',
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
        await openProgress(tester);
        expect(tester.takeException(), isNull);
        await tapVisible(
          tester,
          find.byKey(const ValueKey('progress-section-1')),
        );
        await tapVisible(
          tester,
          find.byKey(const ValueKey('commitment-side-1')),
        );
        await tapVisible(
          tester,
          find.byKey(const ValueKey('commitment-commitment-2')),
        );
        expect(find.text('承诺详情'), findsOneWidget);
        expect(find.byTooltip('查看语音证据'), findsNothing);
        final source = find.byKey(const ValueKey('commitment-source-meeting'));
        await tester.ensureVisible(source);
        await tester.pumpAndSettle();
        expect(find.text('关联目标'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tap(find.byType(BackButton));
        await tester.pumpAndSettle();
        await jump(tester, 0);
        await tapVisible(
          tester,
          find.byKey(const ValueKey('goal-goal-delivery')),
        );
        expect(find.text('目标详情'), findsOneWidget);
        expect(find.byType(KnowledgeReferenceCard), findsNWidgets(2));
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant({platform}),
    );
  }
}
