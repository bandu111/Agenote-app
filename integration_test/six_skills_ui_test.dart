import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:provider/provider.dart';
import 'package:yanshu/app/app.dart';
import 'package:yanshu/core/network/api_client.dart';
import 'package:yanshu/core/network/api_config.dart';
import 'package:yanshu/features/auth/repositories/dio_auth_repository.dart';
import 'package:yanshu/features/auth/services/session_store.dart';
import 'package:yanshu/features/knowledge/repositories/dio_knowledge_repository.dart';
import 'package:yanshu/features/knowledge/viewmodels/knowledge_view_model.dart';
import 'package:yanshu/features/profile/models/profile_data.dart';
import 'package:yanshu/features/meeting/meeting_remote.dart';
import 'package:yanshu/features/meeting/meeting_store.dart';
import 'package:yanshu/features/notifications/knowledge_assistance.dart';
import 'package:yanshu/features/notifications/notification_model.dart';
import 'package:yanshu/features/profile/repositories/profile_repository.dart';
import 'package:yanshu/features/progress/repositories/dio_progress_repository.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    '真机六项Skill：真实模型、合成资料、业务隔离及原有界面',
    (tester) async {
      final previous =
          jsonDecode(
                r'''{"synthetic_only": true, "resumes_failed_fixture": true, "first_proactive_attempt": "failed:ValidationError", "real_model": true, "synthetic_transcript_not_asr_accuracy": true, "base_url": "https://124.220.169.122/api/v1/", "checks": {"native_https_dio": true, "document_action_requires_consent_and_keeps_document_source": true, "decision_questionnaire_missing_date_is_not_a_fact": true, "qmd_real_chinese_search_and_citation": true, "meeting_action_items_original_skill_still_connected": true, "one_three_one_real_options_archived_as_unapproved_advice": true, "proactive_real_followup_does_not_reschedule": true, "weekly_real_review_archived_with_coverage_gaps": true, "meeting_to_progress_to_knowledge_archive": true}, "skills": {"document": {"name": "document-to-action-items", "commit": "c49fa88b80753071e7b7bb83e2882232e43e87c0", "sha256": "8a7556754aca2a7d04d38847131fb4db8d6705fa2106fcb154279e26117b41ee", "adapter": "yanshu-document-to-action-items-v1"}, "questionnaire": {"name": "decision-questionnaire", "commit": "b1ff8722a53ee223485ac9804945acf07ef5c601", "sha256": "84a781708b86a797e41d4a0b9234d4da48f95d14fc9cee23a0eb2cf8574e8ca2", "adapter": "yanshu-decision-questionnaire-v1"}, "qmd": {"retriever": "qmd-hybrid"}, "decision": {"skill": {"name": "one-three-one-rule", "commit": "1c9433897c7b8a3b2754a84875e8f86d0a42991a", "sha256": "31ae7d7c5fc127d7f49d3282c3f93e3e3c3afa295f9bbd6660cc88ca9248248b", "adapter": "yanshu-one-three-one-rule-v1"}, "runtime": {"model": "deepseek-flash", "provider": "HermesProvider"}}, "proactive": {"skill": {"name": "proactive-agent", "commit": "registry:3.1.0", "sha256": "571521d9f6f38b3ec9f073d7bdec47170a35e9c78556954ac7f0f860ab12873b", "adapter": "yanshu-proactive-agent-v1"}, "runtime": {"model": "deepseek-flash", "provider": "HermesProvider"}}, "weekly": {"skill": {"name": "weekly-review-planning", "commit": "99fa93035dd5c50a8f6312f2172de1593b453cd7", "sha256": "a689257facb937cfca9bc5507dd9e729f287f0cd3f6abbf73448eb25f73fbaab", "adapter": "yanshu-weekly-review-planning-v1"}, "runtime": {"model": "deepseek-flash", "provider": "HermesProvider"}}}, "test_account": {"id": "b9688565-3826-457b-b835-91740f2b73e6", "email": "cloud-app-1792474022783864@example.com"}, "meeting_runtime": {"provider": "HermesProvider", "model": "deepseek-flash", "orchestrator": "langgraph", "skills": [{"name": "meeting-action-items", "commit": "a6ede70c2ad2e39cead64113a2fa26ae770f24ff", "sha256": "1902f782551da96ee1f9b34d6f13af627f06150a498d874b0cc2a75d06d35aa8", "adapter": "yanshu-meeting-actions-v1"}, {"name": "decision-questionnaire", "commit": "b1ff8722a53ee223485ac9804945acf07ef5c601", "sha256": "84a781708b86a797e41d4a0b9234d4da48f95d14fc9cee23a0eb2cf8574e8ca2", "adapter": "yanshu-decision-questionnaire-v1"}]}, "passed": false, "failure_type": "TestFailure"}''',
              )
              as Map<String, dynamic>;
      final checks = Map<String, bool>.from(previous['checks']);
      final runtimes = Map<String, dynamic>.from(previous['skills']);
      final report = <String, dynamic>{
        'synthetic_only': true,
        'resumes_failed_fixture': true,
        'first_proactive_attempt': 'failed:ValidationError',
        'ui_resume_only_no_new_model_calls': true,
        'real_model': true,
        'synthetic_transcript_not_asr_accuracy': true,
        'base_url': ApiConfig.baseUrl,
        'checks': checks,
        'skills': runtimes,
      };
      void save() => binding.reportData = report;
      final api = ApiClient(baseUrl: ApiConfig.baseUrl);
      final store = SecureSessionStore('${ApiConfig.baseUrl}#six-skills-qa');
      final auth = DioAuthRepository(api, store);
      final kb = DioKnowledgeRepository(api);
      final progress = DioProgressRepository(api);
      final remote = DioMeetingRepository(api);
      final notifications = NotificationModel();
      final bridge = KnowledgeAssistance(api, notifications);
      final knowledge = KnowledgeViewModel(kb, accountId: () => auth.accountId);
      Future<void> waitUntil(
        Future<bool> Function() ready, {
        int seconds = 150,
      }) async {
        final until = DateTime.now().add(Duration(seconds: seconds));
        while (DateTime.now().isBefore(until)) {
          if (await ready()) return;
          await tester.pump(const Duration(milliseconds: 300));
          await Future<void>.delayed(const Duration(seconds: 1));
        }
        fail('等待业务结果超时');
      }

      try {
        await tester.pumpWidget(
          const MaterialApp(home: Scaffold(body: Text('六项 Skill 真机联调'))),
        );
        expect(
          (await api.dio.get(
            Uri.parse(ApiConfig.baseUrl).resolve('/health').toString(),
          )).statusCode,
          200,
        );
        checks['native_https_dio'] = true;
        save();
        final email = previous['test_account']['email'] as String;
        final identity = await auth.login(email, 'Cloud-App-Synthetic-2026!');
        report['test_account'] = {'id': identity.id, 'email': email};
        report['meeting_runtime'] = previous['meeting_runtime'];
        save();
        await knowledge.load();
        final hits = await kb.search('电脑桌面端是否已经正式同意加入交付？');
        final weeklyDoc = knowledge.data.documents.firstWhere(
          (d) =>
              d.source.startsWith('assistant:') &&
              d.selected.title.contains('复盘'),
        );
        await tester.pumpWidget(
          YanShuApp(
            initialLocation: '/affairs',
            authRepository: auth,
            apiClient: api,
            profileRepository: ProfileRepository(
              MemoryProfileStore(
                value: jsonEncode(
                  ProfileData(
                    accountId: identity.id,
                    name: identity.name,
                    email: email,
                  ).toJson(),
                ),
              ),
            ),
            knowledgeRepository: kb,
            meetingRemote: remote,
            meetingStore: MemoryMeetingStore(),
            progressRepository: progress,
          ),
        );
        await waitUntil(() async {
          await tester.pump(const Duration(milliseconds: 200));
          return find.byType(NavigationBar).evaluate().isNotEmpty;
        }, seconds: 40);
        expect(
          tester
              .widget<NavigationBar>(find.byType(NavigationBar))
              .destinations
              .length,
          4,
        );
        final ctx = tester.element(find.byType(NavigationBar));
        ctx.read<NotificationModel>().dismissPrompt();
        await tester.pump(const Duration(milliseconds: 200));
        checks['existing_four_tab_ui_preserved'] = true;
        save();
        await tester.tap(find.text('知识库').last);
        await tester.pump(const Duration(seconds: 2));
        expect(
          ctx.read<KnowledgeViewModel>().data.documents.any(
            (d) => d.id == weeklyDoc.id,
          ),
          isTrue,
        );
        checks['original_knowledge_ui_reads_generated_reviews'] = true;
        save();
        await tester.pumpWidget(const MaterialApp(home: Scaffold()));
        await knowledge.load();
        for (final document
            in knowledge.data.documents
                .where((d) => d.projectId == 'personal')
                .toList()) {
          expect(await knowledge.delete(document.id), isTrue);
        }
        expect(await kb.search('Windows'), isEmpty);
        expect(await kb.resolve(hits.first), isFalse);
        checks['deletion_blocks_old_citations'] = true;
        save();
        report['passed'] = true;
        save();
      } catch (error) {
        report['passed'] = false;
        report['failure_type'] = error.runtimeType.toString();
        save();
        rethrow;
      } finally {
        bridge.dispose();
        knowledge.dispose();
        notifications.dispose();
        await store.clear();
        await tester.pumpWidget(const SizedBox());
        api.dio.close(force: true);
      }
    },
    semanticsEnabled: false,
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
