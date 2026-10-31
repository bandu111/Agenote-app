import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:yanshu/features/home/viewmodels/home_view_model.dart';
import 'package:yanshu/features/home/viewmodels/schedule_view_model.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yanshu/app/app.dart';
import 'package:yanshu/app/router/destinations.dart';
import 'package:yanshu/core/network/api_client.dart';
import 'package:yanshu/core/network/api_config.dart';
import 'package:yanshu/features/auth/repositories/dio_auth_repository.dart';
import 'package:yanshu/features/auth/services/session_store.dart';
import 'package:yanshu/features/knowledge/models/knowledge_models.dart';
import 'package:yanshu/features/knowledge/repositories/dio_knowledge_repository.dart';
import 'package:yanshu/features/knowledge/viewmodels/knowledge_view_model.dart';
import 'package:yanshu/features/meeting/meeting_models.dart';
import 'package:yanshu/features/meeting/meeting_remote.dart';
import 'package:yanshu/features/meeting/meeting_store.dart';
import 'package:yanshu/features/profile/repositories/profile_repository.dart';
import 'package:yanshu/features/progress/repositories/dio_progress_repository.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('云端独立包：真实注册、会议、进展和知识库', (tester) async {
    expect(ApiConfig.current.environment, AppEnvironment.cloud);
    expect(ApiConfig.baseUrl, ApiEnvironment.cloudUrl);
    final api = ApiClient(baseUrl: ApiConfig.baseUrl);
    final store = SecureSessionStore(
      '${ApiConfig.baseUrl}#cloud-app-integration',
    );
    final localSentinel = SecureSessionStore(
      '${ApiEnvironment.localUrl}#cloud-app-integration',
    );
    await store.clear();
    await localSentinel.write('local-test-sentinel');
    final auth = DioAuthRepository(api, store);
    final profiles = ProfileRepository(
      MemoryProfileStore(),
      initialSessionActive: false,
    );
    final knowledgeRepo = DioKnowledgeRepository(api);
    final meetingRepo = DioMeetingRepository(api);
    final progressRepo = DioProgressRepository(api);
    final checks = <String, bool>{};
    final report = <String, dynamic>{
      'synthetic_only': true,
      'environment': 'cloud',
      'base_url': ApiConfig.baseUrl,
      'real_device': 'Android PLQ110',
      'real_backend': true,
      'transcript_input': 'controlled_text_not_microphone_asr',
      'checks': checks,
    };
    void save() => binding.reportData = report;
    api.dio.interceptors.add(
      InterceptorsWrapper(
        onResponse: (response, handler) {
          if (response.requestOptions.path.endsWith('auth/register')) {
            final user = (response.data as Map)['data']['user'] as Map;
            report['test_account'] = {'id': user['id'], 'email': user['email']};
            report['server_test_account_retained'] = true;
            save();
          }
          handler.next(response);
        },
        onError: (error, handler) {
          report['network_error'] = {
            'type': error.type.name,
            'status': error.response?.statusCode,
            'cause': error.error.toString(),
          };
          save();
          handler.next(error);
        },
      ),
    );
    Future<void> waitFor(Finder finder) async {
      final watch = Stopwatch()..start();
      while (finder.evaluate().isEmpty &&
          watch.elapsed < const Duration(seconds: 40)) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      expect(finder, findsWidgets);
    }

    Future<void> tap(Finder finder) async {
      await tester.ensureVisible(finder);
      await tester.tap(finder);
      await tester.pump(const Duration(milliseconds: 300));
    }

    Widget app(String location) => YanShuApp(
      key: UniqueKey(),
      initialLocation: location,
      authRepository: auth,
      profileRepository: profiles,
      apiClient: api,
      meetingRemote: meetingRepo,
      meetingStore: MemoryMeetingStore(),
      knowledgeRepository: knowledgeRepo,
      progressRepository: progressRepo,
    );
    KnowledgeViewModel? knowledge;
    try {
      await tester.pumpWidget(const MaterialApp(home: Scaffold()));
      final health = await api.dio.get(
        Uri.parse(ApiConfig.baseUrl).resolve('/health').toString(),
      );
      expect(health.statusCode, 200);
      checks['device_dio_https_health'] = true;
      save();
      await tester.pumpWidget(app('/register'));
      await waitFor(find.byKey(const ValueKey('register-page')));
      final email =
          'cloud-app-${DateTime.now().microsecondsSinceEpoch}@example.com';
      await tester.enterText(
        find.byKey(const ValueKey('auth-name')),
        '云端APP联调',
      );
      await tester.enterText(find.byKey(const ValueKey('auth-email')), email);
      await tester.enterText(
        find.byKey(const ValueKey('auth-password')),
        'Cloud-App-Synthetic-2026!',
      );
      await tester.enterText(
        find.byKey(const ValueKey('auth-confirmation')),
        'Cloud-App-Synthetic-2026!',
      );
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump(const Duration(milliseconds: 500));
      await tap(find.byKey(const ValueKey('auth-submit')));
      await waitFor(find.byType(NavigationBar));
      checks['registration_through_existing_ui'] = auth.authenticated;
      report['test_account'] = {'id': auth.accountId, 'email': email};
      report['server_test_account_retained'] = true;
      save();
      final nav = tester.widget<NavigationBar>(find.byType(NavigationBar));
      expect(nav.destinations.length, 4);
      checks['four_tabs_unchanged'] = true;
      final restored = DioAuthRepository(
        ApiClient(baseUrl: ApiConfig.baseUrl),
        store,
      );
      expect((await restored.restore())?.id, auth.accountId);
      checks['native_secure_session_restore'] = true;
      expect(
        (jsonDecode((await store.read())!) as Map).containsKey('password'),
        isFalse,
      );
      knowledge = KnowledgeViewModel(
        knowledgeRepo,
        accountId: () => auth.accountId,
      );
      await knowledge.load();
      expect(knowledge.data.documents, isEmpty);
      final document = await knowledge.addDocument(
        title: '云端APP联调合同（合成测试）',
        content: '一期仅交付Android与iOS双端，Windows新增需求尚未批准，需要单独评估。',
        folderId: 'inbox',
        projectId: 'personal',
        kind: KnowledgeKind.markdown,
        allowed: true,
      );
      expect(document, isNotNull, reason: knowledge.actionError);

      expect(
        (await knowledgeRepo.search(
          'Windows Android 合同',
        )).any((h) => h['documentId'] == document),
        isTrue,
      );
      checks['cloud_knowledge_write_and_search'] = true;
      final record = MeetingRecord(
        id: 'cloud-app-${DateTime.now().microsecondsSinceEpoch}',
        demo: false,
        ownerId: auth.accountId,
        syncRevision: 1,
        ended: true,
        startedAt: DateTime.now(),
        title: '云端APP合成会议',
        utterances: [
          for (final (index, raw) in <String>[
            '交付目标是完成 Android 与 iOS 双端测试并部署至预发环境。交期2030年11月5日。验收要求是通过双方确认的测试清单。',
            '我方负责2030年10月28日提交双端测试报告。',
            '可以考虑改为2030年10月30日提交，但还没确定。',
            '请不要改成Windows。',
          ].indexed)
            MeetingUtterance(
              id: 'u$index',
              speaker: '发言人 A',
              speakerId: 'fixture-a',
              speakerSeparated: true,
              raw: raw,
              at: Duration(seconds: index * 10),
            ),
        ],
      );
      await meetingRepo.sync(record, paused: false);
      final watch = Stopwatch()..start();
      final analysis = await meetingRepo.analyze(record);
      report['analysis_seconds'] = watch.elapsedMilliseconds / 1000;
      report['runtime'] = analysis['runtime'];
      expect(
        (analysis['runtime']['skills'] as List).first['name'],
        'meeting-action-items',
      );
      checks['pinned_official_skill_in_real_analysis'] = true;
      expect((analysis['withdrawals'] as List), isEmpty);
      final progress = await progressRepo.load();
      expect(progress.goals, isNotEmpty);
      expect(
        progress.commitments.any(
          (c) => c.title.contains('测试报告') && c.deadline.day == 28,
        ),
        isTrue,
      );
      checks['real_dio_meeting_analysis_progress_and_deadline_guard'] = true;
      await meetingRepo.archive(record);
      await knowledge.load();
      expect(knowledge.document('meeting-${record.id}'), isNotNull);
      checks['meeting_minutes_saved_to_cloud_knowledge'] = true;
      // 由真实账户写入明确日程，验证首页不再使用固定演示条目。
      final due = DateTime.now().add(const Duration(minutes: 5));
      await api.post(
        'progress/goals',
        authenticated: true,
        accountId: auth.accountId,
        data: {
          'title': '首页日程联调（合成）',
          'condition': '验证真实账户日程',
          'deadline': due.toUtc().toIso8601String(),
        },
      );
      final homeResult =
          (await api.get(
                'home',
                authenticated: true,
                accountId: auth.accountId,
              ))['data']
              as Map;
      expect(homeResult['modelCallsOnRead'], 0);
      expect(
        (homeResult['schedules'] as List).any(
          (s) => s['title'] == '首页日程联调（合成）',
        ),
        true,
      );
      checks['home_reads_persisted_schedule_without_model_calls'] = true;
      final homeContext = tester.element(find.byType(NavigationBar));
      await homeContext.read<HomeViewModel>().refresh();
      await homeContext.read<ScheduleViewModel>().refresh();
      await tester.pump(const Duration(milliseconds: 500));
      await waitFor(find.text('首页日程联调（合成）'));
      expect(find.text('言枢 · 演示数据'), findsNothing);
      expect(
        homeContext.read<ScheduleViewModel>().entries.any(
          (e) => e.item.title == '首页日程联调（合成）',
        ),
        true,
      );
      checks['home_ui_real_data_preserves_existing_cards'] = true;
      save();
      // 重新创建页面，验证真实服务器数据可在正常页面中恢复展示。
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(app(AppRoutes.affairs));
      final latestProgress = await progressRepo.load();
      await waitFor(find.text(latestProgress.goals.first.title));
      checks['progress_ui_displays_cloud_goal'] = true;
      await tap(find.text('知识库').last);
      await waitFor(find.text('云端APP联调合同（合成测试）'));
      checks['knowledge_ui_displays_cloud_document'] = true;
      await tap(find.text('我的').last);
      await waitFor(find.byKey(const PageStorageKey('profile-scroll')));
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('profile-logout')),
        300,
        scrollable: find.descendant(
          of: find.byKey(const PageStorageKey('profile-scroll')),
          matching: find.byType(Scrollable),
        ),
        maxScrolls: 15,
      );
      await waitFor(find.byKey(const ValueKey('profile-logout')));
      await tap(find.byKey(const ValueKey('profile-logout')));
      await tap(find.widgetWithText(FilledButton, '退出'));
      await waitFor(find.byKey(const ValueKey('login-page')));
      expect(await store.read(), isNull);
      expect(await localSentinel.read(), 'local-test-sentinel');
      checks['cloud_logout_leaves_local_session_namespace_intact'] = true;
      save();
      await tester.enterText(find.byKey(const ValueKey('auth-email')), email);
      await tester.enterText(
        find.byKey(const ValueKey('auth-password')),
        'Cloud-App-Synthetic-2026!',
      );
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump(const Duration(milliseconds: 500));
      await tap(find.byKey(const ValueKey('auth-submit')));
      await waitFor(find.byType(NavigationBar));
      expect(auth.authenticated, isTrue);
      checks['login_through_existing_ui'] = true;
      report['status'] = 'passed';
      save();
    } catch (error) {
      report['status'] = 'failed';
      report['failure_type'] = error.runtimeType.toString();
      final authError = find.byKey(const ValueKey('auth-error'));
      if (authError.evaluate().isNotEmpty) {
        report['auth_ui_error'] = tester.widget<Text>(authError).data;
      }
      report['validation_messages'] = tester
          .widgetList<Text>(find.byType(Text))
          .map((w) => w.data ?? '')
          .where((s) => s.contains('请输入') || s.contains('不一致'))
          .toList();
      if (error is ApiFailure) {
        report['failure'] = {'message': error.message, 'status': error.status};
      }
      save();
      rethrow;
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      knowledge?.dispose();
      await auth.logout();
      await store.clear();
      await localSentinel.clear();
      save();
    }
  }, semanticsEnabled: false, timeout: const Timeout(Duration(minutes: 10)));
}
