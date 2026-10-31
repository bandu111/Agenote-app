import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:provider/provider.dart';
import 'package:go_router/go_router.dart';
import 'package:yanshu/app/app.dart';
import 'package:yanshu/core/network/api_client.dart';
import 'package:yanshu/core/network/api_config.dart';
import 'package:yanshu/features/knowledge/models/knowledge_models.dart';
import 'package:yanshu/features/knowledge/repositories/dio_knowledge_repository.dart';
import 'package:yanshu/features/knowledge/viewmodels/knowledge_view_model.dart';
import 'package:yanshu/features/knowledge/views/knowledge_detail_page.dart';
import 'package:yanshu/features/meeting/meeting_page.dart';
import 'package:yanshu/features/meeting/meeting_recorder_factory.dart';
import 'package:yanshu/features/meeting/meeting_store.dart';
import 'package:yanshu/features/meeting/meeting_view_model.dart';
import 'package:yanshu/features/profile/models/profile_data.dart';
import 'package:yanshu/features/profile/repositories/profile_repository.dart';
import 'package:yanshu/features/progress/repositories/dio_progress_repository.dart';
import 'package:yanshu/features/progress/views/progress_page.dart';

/// Isolated Android package and temporary account; real microphone and cloud API.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('真机会议返回持续采音与进展页内云端检索', (tester) async {
    final api = ApiClient(baseUrl: ApiEnvironment.cloudUrl);
    final checks = <String, dynamic>{
      'realMicrophone': true,
      'realCloudSearch': true,
      'iosTested': false,
    };
    const password = 'Navigation-Search-Device-QA-2026!';
    String? owner;
    MeetingViewModel? meeting;
    final directory = await Directory.systemTemp.createTemp('yanshu-nav-qa-');
    final recorder = createDeviceMeetingRecorder(
      directory: directory,
      apiClient: api,
      provider: 'tencent',
    );
    Future<void> waitFor(bool Function() condition, {int seconds = 40}) async {
      final limit = DateTime.now().add(Duration(seconds: seconds));
      while (DateTime.now().isBefore(limit)) {
        await tester.pump(const Duration(milliseconds: 60));
        if (condition()) return;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      fail('等待真机状态超时：${jsonEncode(checks)}');
    }

    Future<void> tap(Finder finder) async {
      await tester.ensureVisible(finder);
      await tester.pump(const Duration(milliseconds: 150));
      await tester.tap(finder);
      await tester.pump();
    }

    Finder searchInput() => find.byKey(const ValueKey('progress-search-input'));
    try {
      final data = (await api.post(
        'auth/register',
        data: {
          'name': '导航检索临时测试',
          'email':
              'nav-search-${DateTime.now().microsecondsSinceEpoch}@example.com',
          'password': password,
        },
      ))['data'];
      owner = data['user']['id'] as String;
      final token = data['access_token'] as String;
      api.accountId = () => owner;
      api.accessToken = () async => token;
      await tester.pumpWidget(
        YanShuApp(
          initialLocation: '/affairs',
          connectRecordingCardToMeetings: false,
          apiClient: api,
          profileRepository: ProfileRepository(
            MemoryProfileStore(
              value: jsonEncode(
                ProfileData(accountId: owner, name: '导航检索临时测试').toJson(),
              ),
            ),
          ),
          knowledgeRepository: DioKnowledgeRepository(api),
          progressRepository: DioProgressRepository(api),
          meetingStore: MemoryMeetingStore(),
          meetingRecorder: recorder,
        ),
      );
      await waitFor(() => find.byType(ProgressPage).evaluate().isNotEmpty);
      final pageContext = tester.element(find.byType(ProgressPage));
      final router = GoRouter.of(pageContext);
      final knowledge = pageContext.read<KnowledgeViewModel>();
      meeting = pageContext.read<MeetingViewModel>();
      await waitFor(() => !knowledge.loading);

      const title = '导航检索验收资料';
      final doc = await knowledge.addDocument(
        title: title,
        content: '导航检索验收：这是一份独立测试账号中的合成资料，用于验证真实搜索接口。',
        folderId: 'inbox',
        projectId: 'personal',
        kind: KnowledgeKind.text,
        allowed: true,
      );
      expect(doc, isNotNull);
      await tap(find.byKey(const ValueKey('progress-search')));
      await waitFor(() => searchInput().evaluate().isNotEmpty);
      expect(find.byType(NavigationBar), findsOneWidget);
      await tester.enterText(searchInput(), '导航检索验收');
      await waitFor(() => find.text(title).evaluate().isNotEmpty);
      checks['inlineSearchAndRealCloudResult'] = true;
      await tap(find.text(title));
      await waitFor(
        () => find.byType(KnowledgeDetailPage).evaluate().isNotEmpty,
      );
      checks['resultOpensSourceDetail'] = true;
      router.pop();
      await waitFor(() => searchInput().evaluate().isNotEmpty);
      expect(
        tester.widget<TextField>(searchInput()).controller!.text,
        '导航检索验收',
      );
      checks['queryRetainedAfterReturning'] = true;
      await tester.pumpAndSettle();
      await tap(searchInput());
      await tester.pumpAndSettle();
      await tester.enterText(searchInput(), '未命中词navqa987654321');
      await tester.pump();
      await waitFor(() => find.text('没有找到匹配来源').evaluate().isNotEmpty);
      checks['honestEmptySearch'] = true;
      await tap(find.byTooltip('收起搜索'));
      await waitFor(() => searchInput().evaluate().isEmpty);
      checks['collapseRestoresProgress'] = true;
      router.go('/home');
      await waitFor(() => find.text('点击开始会话').evaluate().isNotEmpty);
      await tap(find.text('点击开始会话'));
      await waitFor(() => find.byType(MeetingPage).evaluate().isNotEmpty);
      debugPrint('NAVIGATION_QA_MIC_START_NOW');
      await tap(find.text('开始真实会话'));
      final vm = meeting;
      await waitFor(() => vm.active || vm.error != null, seconds: 60);
      expect(vm.active, true, reason: vm.error);
      await waitFor(() => (recorder.diagnostics['samples'] as int) > 16000);
      final id = vm.record!.id;
      final before = recorder.diagnostics['samples'] as int;
      await tap(find.byType(BackButton));
      await waitFor(() => find.byType(MeetingPage).evaluate().isEmpty);
      await waitFor(
        () => (recorder.diagnostics['samples'] as int) > before + 32000,
      );
      expect(vm.active, true);
      expect(find.byType(NavigationBar), findsOneWidget);
      checks['toolbarBackKeepsRealPcmFlowing'] = true;
      await tap(find.text('返回录音会议'));
      await waitFor(() => find.byType(MeetingPage).evaluate().isNotEmpty);
      expect(vm.record!.id, id);
      checks['sameMeetingOnReentry'] = true;
      final second = recorder.diagnostics['samples'] as int;
      await tester.binding.handlePopRoute();
      await waitFor(() => find.byType(MeetingPage).evaluate().isEmpty);
      await waitFor(
        () => (recorder.diagnostics['samples'] as int) > second + 32000,
      );
      checks['systemBackKeepsRealPcmFlowing'] = true;
      expect(vm.active, true);
      checks['samplesObserved'] = recorder.diagnostics['samples'];
      await vm.finish();
      expect(vm.active, false);
      checks['recordingStoppedAtTestEnd'] = true;
      checks['passed'] = true;
    } catch (error) {
      checks['passed'] = false;
      checks['error'] = error.toString();
      rethrow;
    } finally {
      await recorder.stop();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      if (owner != null) {
        try {
          await api.post(
            'auth/delete-account',
            authenticated: true,
            accountId: owner,
            data: {'current_password': password, 'confirmation': 'DELETE'},
          );
          checks['temporaryAccountDeleted'] = true;
        } catch (_) {
          checks['temporaryAccountDeleted'] = false;
        }
      }
      await recorder.dispose();
      if (await directory.exists()) await directory.delete(recursive: true);
      binding.reportData = checks;
      debugPrint('NAVIGATION_SEARCH_PHONE_REPORT ${jsonEncode(checks)}');
      api.dio.close(force: true);
    }
  }, timeout: const Timeout(Duration(minutes: 5)));
}
