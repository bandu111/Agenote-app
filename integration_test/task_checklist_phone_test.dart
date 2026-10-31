import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:provider/provider.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:yanshu/app/app.dart';
import 'package:yanshu/core/network/api_client.dart';
import 'package:yanshu/features/home/repositories/dio_home_repository.dart';
import 'package:yanshu/features/home/views/home_page.dart';
import 'package:yanshu/features/home/viewmodels/schedule_view_model.dart';
import 'package:yanshu/features/profile/repositories/profile_repository.dart';
import 'package:yanshu/features/knowledge/repositories/knowledge_repository.dart';
import 'package:yanshu/features/meeting/meeting_store.dart';
import 'package:yanshu/features/notifications/notification_model.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('真机首页清单：真实接口、数据库、勾选动画与重新登录回读', (tester) async {
    final api = ApiClient(baseUrl: 'http://127.0.0.1:18861/api/v1/');
    const password = 'Checklist-device-qa-password-2026';
    final email =
        'checklist-device-${DateTime.now().microsecondsSinceEpoch}@example.com';
    final data = (await api.post(
      'auth/register',
      data: {'name': '清单真机测试', 'email': email, 'password': password},
    ))['data'];
    final owner = data['user']['id'] as String;
    var token = data['access_token'] as String;
    api.accountId = () => owner;
    api.accessToken = () async => token;
    final checks = <String, bool>{};
    try {
      await api.post(
        'meetings/sync',
        authenticated: true,
        accountId: owner,
        data: {
          'id': 'realtime-test',
          'revision': 1,
          'capabilities': ['turns_v1', 'tool_plans_v1'],
          'title': '任务清单真机联调',
          'startedAt': '2026-10-26T10:00:00+08:00',
          'elapsed': 30000,
          'utterances': [
            {
              'id': 'g',
              'speaker': '发言人 A',
              'speakerId': 'a',
              'speakerSeparated': true,
              'raw': '本期交付目标是完成双端测试，交期2030年10月30日。',
              'at': 0,
            },
            {
              'id': 'c',
              'speaker': '发言人 B',
              'speakerId': 'b',
              'speakerSeparated': true,
              'raw': '对方承诺周五提供测试账号。',
              'at': 1000,
            },
            {
              'id': 't',
              'speaker': '发言人 A',
              'speakerId': 'a',
              'speakerSeparated': true,
              'raw': '请创建任务提交评估报告。',
              'at': 2000,
            },
          ],
        },
      );
      await api
          .postEvents(
            'meetings/realtime-test/realtime',
            data: {'revision': 1},
            accountId: owner,
          )
          .drain<void>();
      await tester.pumpWidget(
        YanShuApp(
          scheduleRepository: DioHomeRepository(api),
          profileRepository: ProfileRepository(MemoryProfileStore()),
          knowledgeRepository: KnowledgeRepository(
            MemoryKnowledgeStore(),
            seedExamples: false,
          ),
          meetingStore: MemoryMeetingStore(),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('任务清单'));
      await tester.pumpAndSettle();
      expect(find.text('提供测试账号'), findsOneWidget);
      checks['liveMeetingTaskVisibleBeforeEnding'] = true;
      await binding.convertFlutterSurfaceToImage();
      await tester.pump();
      await binding.takeScreenshot('01-collapsed');
      await tester.tap(find.byKey(const ValueKey('toggle-schedule')));
      await tester.pumpAndSettle();
      checks['expandCollapse'] = find.text('收起').evaluate().isNotEmpty;
      final model = tester
          .element(find.byType(HomePage))
          .read<ScheduleViewModel>();
      final id = model.entries.single.item.id;
      await tester.tap(find.byKey(ValueKey('complete-task-$id')));
      for (
        var i = 0;
        i < 100 && !model.entries.any((e) => e.item.completed);
        i++
      ) {
        await tester.pump(const Duration(milliseconds: 20));
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(model.entries.single.item.completed, isTrue);
      expect(
        tester.widget<Text>(find.text('提供测试账号')).style!.decoration,
        TextDecoration.lineThrough,
      );
      checks['serverSavedThenStrikethrough'] = true;
      await binding.takeScreenshot('02-completed-strikethrough');
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(find.text('暂无待办任务'), findsOneWidget);
      checks['disappearedAfterAnimation'] = true;
      await binding.takeScreenshot('03-empty-after-completion');
      await model.refresh();
      await tester.pumpAndSettle();
      expect(model.entries, isEmpty);
      checks['refreshDoesNotRevive'] = true;
      final login = (await api.post(
        'auth/login',
        data: {'email': email, 'password': password},
      ))['data'];
      token = login['access_token'];
      final fresh = await DioHomeRepository(api).load();
      expect(fresh.single.completed, isTrue);
      checks['loginReadsPersistedCompletion'] = true;
      final homeContext = tester.element(find.byType(HomePage));
      final notifications = homeContext.read<NotificationModel>();
      final inboxScope = 'checklist-device-qa:$owner';
      await notifications.configureInbox(inboxScope);
      ActionNotice completion(int version) => ActionNotice(
        id: 'progress-pending:$owner:$version',
        title: '补全测试报告',
        instruction: '补充交期',
        kind: NoticeKind.completion,
      );
      final warning = ActionNotice(
        id: 'meeting:$owner:risk',
        title: '测试风险',
        instruction: '核对交付范围',
        kind: NoticeKind.warning,
      );
      notifications.receive(completion(1), onAllow: () async => true);
      notifications.receive(warning, onAllow: () async => true);
      expect(notifications.pendingCount, 2);
      GoRouter.of(homeContext).push('/notifications');
      await tester.pumpAndSettle();
      await tester.tap(find.text('清空'));
      await tester.pumpAndSettle();
      await notifications.flushInbox();
      expect(notifications.persistenceError, isNull);
      expect(find.text('暂无通知'), findsOneWidget);
      expect(notifications.pendingCount, 0);
      await binding.takeScreenshot('04-notifications-cleared');
      final relogin = (await api.post(
        'auth/login',
        data: {'email': email, 'password': password},
      ))['data'];
      token = relogin['access_token'];
      await notifications.configureInbox(null);
      await notifications.configureInbox(inboxScope);
      notifications.receive(completion(2), onAllow: () async => true);
      notifications.receive(warning, onAllow: () async => true);
      expect(notifications.items, isEmpty);
      expect(notifications.pendingCount, 0);
      expect(notifications.prompt, isNull);
      checks['notificationClearSurvivesReloginAndVersionChange'] = true;
      final recreated = NotificationModel(
        storage: const FlutterSecureStorage(),
      );
      await recreated.configureInbox(inboxScope);
      recreated.receive(completion(3), onAllow: () async => true);
      recreated.receive(warning, onAllow: () async => true);
      expect(recreated.items, isEmpty);
      expect(recreated.pendingCount, 0);
      checks['notificationClearReadFromRealAndroidSecureStorage'] = true;
      recreated.dispose();
      await notifications.configureInbox(null);
      await const FlutterSecureStorage().delete(
        key: 'notice-inbox:$inboxScope',
      );
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await api.post(
        'auth/delete-account',
        authenticated: true,
        accountId: owner,
        data: {'current_password': password, 'confirmation': 'DELETE'},
      );
      api.dio.close(force: true);
      final screenshots = binding.reportData?['screenshots'];
      binding.reportData = {
        'checks': checks,
        'realHttp': true,
        'realPostgresql': true,
        'modelOutputFixture': true,
        'microphoneUsed': false,
        'testAccountDeleted': true,
        'screenshots': ?screenshots,
      };
    }
  });
}
