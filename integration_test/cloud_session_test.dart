import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yanshu/app/app.dart';
import 'package:provider/provider.dart';
import 'package:yanshu/features/home/viewmodels/home_view_model.dart';
import 'package:yanshu/features/home/viewmodels/schedule_view_model.dart';
import 'package:yanshu/core/network/api_client.dart';
import 'package:yanshu/core/network/api_config.dart';
import 'package:yanshu/features/auth/repositories/dio_auth_repository.dart';
import 'package:yanshu/features/auth/services/session_store.dart';
import 'package:yanshu/features/knowledge/repositories/dio_knowledge_repository.dart';
import 'package:yanshu/features/meeting/meeting_remote.dart';
import 'package:yanshu/features/meeting/meeting_store.dart';
import 'package:yanshu/features/profile/repositories/profile_repository.dart';
import 'package:yanshu/features/progress/repositories/dio_progress_repository.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('云端既有合成账户：页面读回、退出与重新登录', (tester) async {
    const email = String.fromEnvironment('YANSHU_TEST_EMAIL');
    expect(
      RegExp(r'^cloud-app-\d{15,20}@example\.com$').hasMatch(email),
      isTrue,
    );
    final api = ApiClient(baseUrl: ApiConfig.baseUrl);
    final store = SecureSessionStore('${ApiConfig.baseUrl}#cloud-session-test');
    final local = SecureSessionStore(
      '${ApiEnvironment.localUrl}#cloud-session-test',
    );
    await store.clear();
    await local.write('local-test-sentinel');
    final auth = DioAuthRepository(api, store);
    final progress = DioProgressRepository(api);
    final checks = <String, bool>{};
    final report = <String, dynamic>{
      'synthetic_only': true,
      'base_url': ApiConfig.baseUrl,
      'reuses_existing_synthetic_account': true,
      'new_model_calls': 0,
      'checks': checks,
    };
    void save() => binding.reportData = report;
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

    Future<void> login() async {
      await waitFor(find.byKey(const ValueKey('login-page')));
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
    }

    try {
      await tester.pumpWidget(const MaterialApp(home: Scaffold()));
      final health = await api.dio.get(
        Uri.parse(ApiConfig.baseUrl).resolve('/health').toString(),
      );
      expect(health.statusCode, 200);
      checks['native_https_health'] = true;
      await tester.pumpWidget(
        YanShuApp(
          initialLocation: '/login',
          authRepository: auth,
          profileRepository: ProfileRepository(
            MemoryProfileStore(),
            initialSessionActive: false,
          ),
          apiClient: api,
          meetingRemote: DioMeetingRepository(api),
          meetingStore: MemoryMeetingStore(),
          knowledgeRepository: DioKnowledgeRepository(api),
          progressRepository: progress,
        ),
      );
      await login();
      report['test_account'] = {'id': auth.accountId, 'email': email};
      checks['existing_ui_login'] = true;
      expect(
        tester
            .widget<NavigationBar>(find.byType(NavigationBar))
            .destinations
            .length,
        4,
      );
      checks['four_tabs_unchanged'] = true;
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
      checks['home_ui_reads_real_account_schedule'] = true;
      final data = await progress.load();
      expect(data.goals, isNotEmpty);
      await tap(find.text('进展').last);
      await waitFor(find.text(data.goals.first.title));
      checks['progress_ui_reads_persisted_goal'] = true;
      await tap(find.text('知识库').last);
      await waitFor(find.text('云端APP联调合同（合成测试）'));
      checks['knowledge_ui_reads_persisted_document'] = true;
      await tap(find.text('我的').last);
      final profileScroll = find.descendant(
        of: find.byKey(const PageStorageKey('profile-scroll')),
        matching: find.byType(Scrollable),
      );
      await waitFor(profileScroll);
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('profile-logout')),
        300,
        scrollable: profileScroll,
        maxScrolls: 15,
      );
      await tap(find.byKey(const ValueKey('profile-logout')));
      await waitFor(find.widgetWithText(FilledButton, '退出'));
      await tap(find.widgetWithText(FilledButton, '退出'));
      await waitFor(find.byKey(const ValueKey('login-page')));
      expect(await store.read(), isNull);
      expect(await local.read(), 'local-test-sentinel');
      checks['ui_logout_clears_cloud_only'] = true;
      await login();
      checks['ui_relogin_after_logout'] = true;
      report['status'] = 'passed';
      save();
    } catch (error) {
      report['status'] = 'failed';
      report['failure_type'] = error.runtimeType.toString();
      save();
      rethrow;
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await auth.logout();
      await store.clear();
      await local.clear();
      save();
    }
  }, semanticsEnabled: false, timeout: const Timeout(Duration(minutes: 5)));
}
