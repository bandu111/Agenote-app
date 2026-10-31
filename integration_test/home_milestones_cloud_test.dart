import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:provider/provider.dart';
import 'package:go_router/go_router.dart';
import 'package:yanshu/app/app.dart';
import 'package:yanshu/core/network/api_client.dart';
import 'package:yanshu/core/network/api_config.dart';
import 'package:yanshu/features/auth/repositories/dio_auth_repository.dart';
import 'package:yanshu/features/auth/services/session_store.dart';
import 'package:yanshu/features/home/viewmodels/home_view_model.dart';
import 'package:yanshu/features/knowledge/repositories/dio_knowledge_repository.dart';
import 'package:yanshu/features/meeting/meeting_models.dart';
import 'package:yanshu/features/meeting/meeting_remote.dart';
import 'package:yanshu/features/meeting/meeting_store.dart';
import 'package:yanshu/features/notifications/notification_model.dart';
import 'package:yanshu/features/profile/models/profile_data.dart';
import 'package:yanshu/features/profile/repositories/profile_repository.dart';
import 'package:yanshu/features/progress/repositories/dio_progress_repository.dart';
import 'package:yanshu/features/progress/viewmodels/progress_view_model.dart';
import 'package:yanshu/features/progress/widgets/goal_topology.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('真机云端：真实增量提取、会后拓扑、跨会议续接与到期隐藏', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: Center(child: Text('里程碑云端联调准备中'))),
      ),
    );
    final api = ApiClient(baseUrl: ApiConfig.baseUrl);
    final store = SecureSessionStore(
      '${ApiConfig.baseUrl}#device-goal-20261025',
    );
    final auth = DioAuthRepository(api, store);
    final remote = DioMeetingRepository(api);
    final progress = DioProgressRepository(api);
    final checks = <String, bool>{};
    final report = <String, dynamic>{
      'syntheticOnly': true,
      'microphoneUsed': false,
      'asrAccuracyMeasured': false,
      'realCloud': true,
      'realModel': true,
      'checks': checks,
      'latencyMs': <String, int>{},
    };
    void save() => binding.reportData = report;
    Future<void> waitUi(bool Function() ready) async {
      for (var i = 0; i < 100; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        if (ready()) return;
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      fail('界面等待超时');
    }

    Future<Map<String, dynamic>> read(String path) async =>
        Map<String, dynamic>.from(
          (await api.get(
            path,
            authenticated: true,
            accountId: auth.accountId,
          ))['data'],
        );

    final suffix = DateTime.now().microsecondsSinceEpoch;
    const password = 'Synthetic-Goal-Device-20261025!';
    var registered = false, surfaceConverted = false;
    HomeViewModel? home;
    ProgressViewModel? progressVm;
    NotificationModel? notices;
    Future<void> refreshUi() async {
      await home!.refresh();
      await progressVm!.load(silent: true);
      notices!.dismissPrompt();
      await tester.pump(const Duration(milliseconds: 500));
    }

    Future<void> screenshot(String name) async {
      if (!surfaceConverted) {
        await binding.convertFlutterSurfaceToImage();
        surfaceConverted = true;
      }
      await tester.pump(const Duration(milliseconds: 300));
      final graph = find.byType(GoalTopology);
      if (graph.evaluate().isNotEmpty) await tester.ensureVisible(graph.first);
      await tester.pump(const Duration(seconds: 1));
      await binding.takeScreenshot(name);
    }

    try {
      await store.clear();
      final identity = await auth.register(
        '里程碑真机合成测试',
        'device-goal-$suffix@example.com',
        password,
      );
      registered = true;
      report['syntheticAccountId'] = identity.id;
      save();
      expect(
        (await api.dio.get(
          Uri.parse(ApiConfig.baseUrl).resolve('/health').toString(),
        )).statusCode,
        200,
      );
      checks['nativeHttps'] = true;
      final started = DateTime.now();
      MeetingUtterance utterance(
        String id,
        String text,
        int seconds, {
        String speaker = 'A',
      }) => MeetingUtterance(
        id: id,
        speaker: '发言人 $speaker',
        speakerId: speaker,
        speakerSeparated: true,
        raw: text,
        at: Duration(seconds: seconds),
      );
      final first = MeetingRecord(
        id: 'device-goal-$suffix-first',
        title: '工单上线推进会（合成真机）',
        startedAt: started,
        demo: false,
        ownerId: identity.id,
        syncRevision: 1,
        elapsed: const Duration(seconds: 90),
        utterances: [
          utterance(
            'g',
            '这次项目的交付目标是完成工单系统上线验收。当前阶段是项目一期，目前还没有约定最终交期。里程碑包括需求范围确认、核心模块开发、双端联调、上线验收。',
            0,
          ),
          utterance(
            'p',
            '需求范围确认已经完成，核心模块开发正在进行，双端联调尚未开始，上线验收尚未开始。',
            30,
            speaker: 'B',
          ),
          utterance('c', '我方负责核心模块开发，交期还未确定。现在不创建日历，也不执行新的任务。', 60),
        ],
      );
      await remote.sync(first, paused: false);
      final watch = Stopwatch()..start();
      var published = false;
      await remote.updateBusiness(first, (event) {
        published |= event['business_updated'] == true;
        save();
      });
      (report['latencyMs'] as Map)['firstRealtime'] = watch.elapsedMilliseconds;
      expect(published, isTrue);
      final before = await read('progress');
      final goals = before['goals'] as List;
      expect(goals, hasLength(1));
      final goal = Map<String, dynamic>.from(goals.single);
      report['goalId'] = goal['id'];
      report['firstMilestones'] = goal['milestones'];
      expect(goal['deadline'], isNull);
      final firstStatuses = {
        for (final m in goal['milestones']) m['title']: m['status'],
      };
      expect(firstStatuses['需求范围确认'], 'completed');
      expect(firstStatuses['核心模块开发'], 'active');
      expect(firstStatuses['双端联调'], 'pending');
      expect(firstStatuses['上线验收'], 'pending');
      checks['realModelExtractsMilestonesDuringMeeting'] = true;
      checks['missingDeadlineDoesNotHideGoal'] = true;
      save();

      await tester.pumpWidget(
        YanShuApp(
          authRepository: auth,
          apiClient: api,
          profileRepository: ProfileRepository(
            MemoryProfileStore(
              value: jsonEncode(
                ProfileData(
                  accountId: identity.id,
                  name: identity.name,
                  email: 'device-goal-$suffix@example.com',
                  language: 'zh',
                ).toJson(),
              ),
            ),
          ),
          knowledgeRepository: DioKnowledgeRepository(api),
          progressRepository: progress,
          meetingRemote: remote,
          meetingStore: MemoryMeetingStore(),
        ),
      );
      await waitUi(() => find.byType(NavigationBar).evaluate().isNotEmpty);
      final ctx = tester.element(find.byType(NavigationBar));
      home = ctx.read<HomeViewModel>();
      progressVm = ctx.read<ProgressViewModel>();
      notices = ctx.read<NotificationModel>();
      final router = GoRouter.of(ctx);
      await refreshUi();
      expect(find.byType(GoalTopology), findsNothing);
      expect(home.situationGoal!.id, goal['id']);
      expect(home.situationGoal!.milestones.length, 4);
      checks['homeKeepsOriginalSituationLayout'] = true;
      await screenshot('home-work-situation');
      router.go('/progress/goals/${goal['id']}');
      await waitUi(() => find.byType(GoalTopology).evaluate().isNotEmpty);
      checks['goalDetailRendersTopology'] = true;
      await screenshot('first-meeting-milestones');
      router.go('/home');
      await waitUi(() => find.byType(NavigationBar).evaluate().isNotEmpty);
      save();

      await remote.sync(
        first.copy(syncRevision: 2, ended: true),
        paused: false,
      );
      await refreshUi();
      expect(home.situationGoal!.id, goal['id']);
      checks['endingMeetingKeepsMilestones'] = true;

      final second = MeetingRecord(
        id: 'device-goal-$suffix-second',
        title: '工单上线复盘（合成真机）',
        startedAt: started.add(const Duration(minutes: 2)),
        demo: false,
        ownerId: identity.id,
        syncRevision: 1,
        elapsed: const Duration(seconds: 60),
        utterances: [
          utterance('s', '继续推进完成工单系统上线验收这个目标。核心模块开发已经完成，双端联调正在进行，上线验收尚未开始。', 0),
        ],
      );
      await remote.sync(second, paused: false);
      watch.reset();
      await remote.updateBusiness(second, (_) => save());
      (report['latencyMs'] as Map)['secondRealtime'] =
          watch.elapsedMilliseconds;
      final after = await read('progress');
      expect(after['goals'], hasLength(1));
      final continued = Map<String, dynamic>.from(
        (after['goals'] as List).single,
      );
      expect(continued['id'], goal['id']);
      report['secondMilestones'] = continued['milestones'];
      final secondStatuses = {
        for (final m in continued['milestones']) m['title']: m['status'],
      };
      expect(secondStatuses['需求范围确认'], 'completed');
      expect(secondStatuses['核心模块开发'], 'completed');
      expect(secondStatuses['双端联调'], 'active');
      checks['nextMeetingContinuesSameGoal'] = true;
      await refreshUi();
      expect(home.situationGoal!.id, goal['id']);
      expect(home.situationGoal!.progress, .5);
      router.go('/progress/goals/${goal['id']}');
      await waitUi(() => find.byType(GoalTopology).evaluate().isNotEmpty);
      await screenshot('continued-meeting-milestones');
      router.go('/home');
      await waitUi(() => find.byType(NavigationBar).evaluate().isNotEmpty);
      save();

      final unrelated = MeetingRecord(
        id: 'device-goal-$suffix-unrelated',
        title: first.title,
        startedAt: started.add(const Duration(minutes: 4)),
        demo: false,
        ownerId: identity.id,
        syncRevision: 1,
        elapsed: const Duration(seconds: 10),
        utterances: [utterance('other', '今天讨论仓库排班，与工单系统上线验收无关，不推进那个项目。', 0)],
      );
      await remote.sync(unrelated, paused: false);
      await refreshUi();
      expect(home.situationGoal, isNull);
      expect(find.byType(GoalTopology), findsNothing);
      checks['similarMeetingTitleDoesNotMixProjects'] = true;

      await remote.sync(
        second.copy(syncRevision: 2, ended: true),
        paused: false,
      );
      await refreshUi();
      expect(home.situationGoal!.id, goal['id']);
      final current = Map<String, dynamic>.from(
        ((await read('progress'))['goals'] as List).single,
      );
      await api.post(
        'progress/goals/${goal['id']}',
        authenticated: true,
        accountId: identity.id,
        data: {
          'version': current['version'],
          'note': '专用合成目标到期显示验证',
          'goal': {
            'title': current['title'],
            'condition': current['condition'],
            'acceptance': current['acceptance'],
            'phase': current['phase'],
            'deadline': '2020-01-01T00:00:00Z',
            'status': current['status'],
            'milestones': [
              for (final m in current['milestones'])
                {
                  'title': m['title'],
                  'weight': m['weight'],
                  'status': m['status'],
                },
            ],
          },
        },
      );
      await refreshUi();
      expect(home.situationGoal, isNull);
      expect(find.byType(GoalTopology), findsNothing);
      expect(progressVm.goal(goal['id']), isNotNull);
      checks['expiredHomeHiddenHistoryPreserved'] = true;
      expect(tester.takeException(), isNull);
      report['passed'] = true;
      save();
    } catch (error) {
      report['passed'] = false;
      report['failureType'] = error.runtimeType.toString();
      save();
      rethrow;
    } finally {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: Center(child: Text('自动化测试结束'))),
        ),
      );
      await tester.pump();
      if (registered) {
        try {
          await auth.deleteAccount(password);
          report['syntheticAccountDeleted'] = true;
        } catch (_) {
          report['syntheticAccountDeleted'] = false;
        }
      }
      await store.clear();
      save();
      api.dio.close(force: true);
    }
  }, timeout: const Timeout(Duration(minutes: 12)));
}
