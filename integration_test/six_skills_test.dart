import 'dart:convert';
import 'package:yanshu/features/profile/models/profile_data.dart';
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
import 'package:yanshu/features/knowledge/models/knowledge_models.dart';
import 'package:yanshu/features/meeting/meeting_models.dart';
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
      final checks = <String, bool>{};
      final runtimes = <String, dynamic>{};
      final report = <String, dynamic>{
        'synthetic_only': true,
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
      Future<List<Map<String, dynamic>>> notices() async => [
        for (final n
            in (await api.get(
                  'knowledge/assistance',
                  authenticated: true,
                  accountId: auth.accountId,
                ))['data']
                as List)
          Map<String, dynamic>.from(n),
      ];
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

      Future<Map<String, dynamic>> followup(String kind) async {
        final requested =
            (await api.post(
                  'knowledge/followup',
                  authenticated: true,
                  accountId: auth.accountId,
                  data: {'kind': kind},
                ))['data']
                as Map;
        Map<String, dynamic>? result;
        await waitUntil(() async {
          final all =
              (await api.get(
                    'knowledge/followup',
                    authenticated: true,
                    accountId: auth.accountId,
                  ))['data']
                  as List;
          result = all
              .where((r) => r['id'] == requested['id'])
              .map((r) => Map<String, dynamic>.from(r))
              .firstOrNull;
          if (result?['status'] == 'failed' || result?['status'] == 'stale') {
            fail('Skill $kind 未成功：${result?['status']} ${result?['error']}');
          }
          return result?['status'] == 'succeeded';
        });
        runtimes[kind] = {
          'skill': result!['skill'],
          'runtime': result!['runtime'],
        };
        save();
        return result!;
      }

      Future<void> acknowledge(String id) async {
        await waitUntil(() async {
          await bridge.refresh();
          return notifications.items.any((n) => n.id.contains(id));
        }, seconds: 25);
        final notice = notifications.items.firstWhere((n) => n.id.contains(id));
        expect(await notifications.decide(notice.id, allow: true), isTrue);
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
        final email =
            'cloud-app-${DateTime.now().microsecondsSinceEpoch}@example.com';
        final identity = await auth.register(
          '云端APP联调',
          email,
          'Cloud-App-Synthetic-2026!',
        );
        report['test_account'] = {'id': identity.id, 'email': email};
        save();
        await knowledge.load();
        final documentId = await knowledge.addDocument(
          title: '六项Skill合成合同',
          content:
              '我方承诺于2030年11月15日提交Android与iOS双端测试报告。\n\n对方承诺提交兼容性评估报告，交期尚未确定。\n\n一期只包含Android与iOS，Windows属于待评估新增范围，尚未批准，交付周期为30天。',
          folderId: 'inbox',
          projectId: 'personal',
          kind: KnowledgeKind.markdown,
          allowed: true,
        );
        expect(documentId, isNotNull, reason: knowledge.actionError);

        List<Map<String, dynamic>> latest = [];
        await waitUntil(() async {
          latest = await notices();
          return latest.any((n) => n['kind'] == 'document_action');
        });
        final docAction = latest.firstWhere(
          (n) =>
              n['kind'] == 'document_action' &&
              n['title'].toString().contains('双端测试报告'),
        );
        expect(docAction['skill']['name'], 'document-to-action-items');
        runtimes['document'] = docAction['skill'];
        final question = latest.firstWhere(
          (n) => n['kind'] == 'question' && n['skillApplied'] == true,
        );
        expect(question['skill']['name'], 'decision-questionnaire');
        runtimes['questionnaire'] = question['skill'];
        bridge.refreshAccount();
        await tester.pump(const Duration(milliseconds: 100));
        await acknowledge(docAction['id']);
        expect(
          (await progress.load()).commitments.single.evidence.isDocument,
          isTrue,
        );
        checks['document_action_requires_consent_and_keeps_document_source'] =
            true;
        checks['decision_questionnaire_missing_date_is_not_a_fact'] = true;
        save();
        final hits = await kb.search('电脑桌面端是否已经正式同意加入交付？');
        expect(hits, isNotEmpty);
        expect(hits.first['retriever'], 'qmd-hybrid');
        expect(await kb.resolve(hits.first), isTrue);
        runtimes['qmd'] = {'retriever': hits.first['retriever']};
        checks['qmd_real_chinese_search_and_citation'] = true;
        save();
        final record = MeetingRecord(
          id: 'six-skills-${DateTime.now().microsecondsSinceEpoch}',
          ownerId: auth.accountId,
          demo: false,
          ended: true,
          syncRevision: 1,
          startedAt: DateTime.now(),
          title: '六项Skill合成会议',
          elapsed: const Duration(minutes: 3),
          utterances: [
            for (final (index, raw) in <String>[
              '交付目标是完成Android与iOS双端测试。验收要求是通过双方确认的测试清单。交期2030年11月15日。',
              '客户提出Windows桌面端也一起交付，而且还要保持30天的交付周期。',
              '这个新增范围尚未批准，我们需要比较维持双端、扩大范围和分期交付三种方案的代价和验收风险，暂时没有做决定。',
              '我方承诺提交技术评估报告，具体交期还需要补充。',
            ].indexed)
              MeetingUtterance(
                id: 'u$index',
                speaker: index == 1 ? '发言人 B' : '发言人 A',
                speakerId: index == 1 ? 'fixture-b' : 'fixture-a',
                speakerSeparated: true,
                raw: raw,
                at: Duration(seconds: index * 20),
              ),
          ],
        );
        await remote.sync(record, paused: false);
        final analysis = await remote.analyze(record);
        report['meeting_runtime'] = analysis['runtime'];
        save();
        expect(
          (analysis['runtime']['skills'] as List).any(
            (s) => s['name'] == 'meeting-action-items',
          ),
          isTrue,
        );
        checks['meeting_action_items_original_skill_still_connected'] = true;
        final decision = await followup('decision');
        expect(decision['needed'], isTrue);
        expect(decision['skill']['name'], 'one-three-one-rule');
        await acknowledge('followup:${decision['id']}');
        await knowledge.load();
        final decisionDoc = knowledge.data.documents.firstWhere(
          (d) => d.source == 'assistant:${decision['id']}',
        );
        expect(decisionDoc.selected.content, contains('## 三种备选方案'));
        expect(decisionDoc.allowed, isTrue);
        checks['one_three_one_real_options_archived_as_unapproved_advice'] =
            true;
        save();
        final goal =
            (await api.post(
                  'progress/goals',
                  authenticated: true,
                  accountId: auth.accountId,
                  data: {
                    'title': '六项Skill交付准备（合成）',
                    'condition': '核对双端测试准备',
                    'deadline': DateTime.now()
                        .add(const Duration(hours: 2))
                        .toUtc()
                        .toIso8601String(),
                  },
                ))['data']
                as Map;
        final proactive = await followup('proactive');
        expect(proactive['skill']['name'], 'proactive-agent');
        await acknowledge('followup:${proactive['id']}');
        final after = (await progress.load()).goals.firstWhere(
          (g) => g.id == goal['id'],
        );
        expect(
          after.deadline!.toUtc().toIso8601String(),
          DateTime.parse(goal['deadline']).toUtc().toIso8601String(),
        );
        checks['proactive_real_followup_does_not_reschedule'] = true;
        save();
        final weekly = await followup('weekly');
        expect(weekly['skill']['name'], 'weekly-review-planning');
        await knowledge.load();
        final weeklyDoc = knowledge.data.documents.firstWhere(
          (d) => d.id == weekly['documentId'],
        );
        expect(weeklyDoc.selected.state, KnowledgeValidity.review);
        expect(weeklyDoc.selected.content, contains('未读取手机完整日历'));
        expect(weeklyDoc.allowed, isTrue);
        checks['weekly_real_review_archived_with_coverage_gaps'] = true;
        save();
        await remote.archive(record);
        await knowledge.load();
        expect(knowledge.document('meeting-${record.id}'), isNotNull);
        checks['meeting_to_progress_to_knowledge_archive'] = true;
        save();
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
