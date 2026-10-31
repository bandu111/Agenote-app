import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yanshu/core/network/api_client.dart';
import 'package:yanshu/core/network/api_config.dart';
import 'package:yanshu/features/knowledge/models/knowledge_models.dart';
import 'package:yanshu/features/knowledge/repositories/dio_knowledge_repository.dart';
import 'package:yanshu/features/notifications/knowledge_assistance.dart';
import 'package:yanshu/features/notifications/notification_model.dart';
import 'package:yanshu/features/progress/repositories/dio_progress_repository.dart';

void main() {
  test(
    'Dio云端：资料→Skill候选→通知确认→进展→引用→撤权',
    () async {
      final report = <String, dynamic>{
        'synthetic_only': true,
        'base_url': ApiEnvironment.cloudUrl,
        'accounts_for_cleanup': <Map<String, dynamic>>[],
        'checks': <String, bool>{},
      };
      final file = File('build/three-skills-dio-live.json');
      final checks = report['checks'] as Map<String, bool>;
      Future<void> save() => file.writeAsString(
        const JsonEncoder.withIndent('  ').convert(report),
      );
      final api = ApiClient(baseUrl: ApiEnvironment.cloudUrl);
      final random = Random.secure();
      String nonce() =>
          List.generate(16, (_) => random.nextInt(16).toRadixString(16)).join();
      try {
        const resumeEmail = String.fromEnvironment(
          'YANSHU_SKILLS_RESUME_EMAIL',
        );
        const resumePassword = String.fromEnvironment(
          'YANSHU_SKILLS_RESUME_PASSWORD',
        );
        const resume = resumeEmail != '';
        final email = resume
            ? resumeEmail
            : 'cloud-deploy-${nonce()}@example.com';
        final auth =
            (await api.post(
                  resume ? 'auth/login' : 'auth/register',
                  data: {
                    if (!resume) 'name': '云部署验证',
                    'email': email,
                    'password': resume
                        ? resumePassword
                        : '${nonce()}${nonce()}',
                  },
                ))['data']
                as Map;
        final owner = auth['user']['id'] as String;
        (report['accounts_for_cleanup'] as List).add({
          'id': owner,
          'email': email,
        });
        await save();
        api.accountId = (() => owner);
        api.accessToken = (() async => auth['access_token'] as String);
        final kb = DioKnowledgeRepository(api);
        await kb.load();
        const text =
            '我方承诺于2026年11月15日提交双端测试报告。\n\n客户建议增加Windows桌面端，尚未批准，不属于当前正式范围。';
        final stamp = DateTime.now().toUtc().toIso8601String();
        final data = KnowledgeSnapshot.fromJson({
          'schema': 1,
          'audit': <Map<String, dynamic>>[],
          'folders': [
            {'id': 'inbox', 'name': '收件箱'},
          ],
          'projects': [
            {'id': 'p1', 'name': 'Dio合成联调', 'allowed': true},
          ],
          'documents': [
            {
              'id': 'dio-document',
              'folderId': 'inbox',
              'projectId': 'p1',
              'kind': 'markdown',
              'source': '合成接口联调',
              'createdAt': stamp,
              'selectedVersionId': 'v1',
              'allowed': true,
              'tags': <String>[],
              'versions': [
                {
                  'id': 'v1',
                  'number': 1,
                  'title': 'Dio合成合同',
                  'content': text,
                  'hash': sha256.convert(utf8.encode(text)).toString(),
                  'createdAt': stamp,
                  'state': 'current',
                },
              ],
            },
          ],
        });
        if (!resume) await kb.save(data);
        final progress = DioProgressRepository(api);
        if (!resume) expect((await progress.load()).commitments, isEmpty);
        final notifications = NotificationModel();
        var refreshes = 0;
        final bridge = KnowledgeAssistance(
          api,
          notifications,
          onRecorded: () async {
            await progress.load();
            refreshes++;
          },
        );
        addTearDown(bridge.dispose);
        addTearDown(notifications.dispose);
        bridge.refreshAccount();
        final deadline = DateTime.now().add(const Duration(seconds: 100));
        while (!notifications.items.any(
              (n) => n.id.contains('document-action:'),
            ) &&
            DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(seconds: 2));
          await bridge.refresh();
        }
        final notice = notifications.items.firstWhere(
          (n) =>
              n.id.contains('document-action:') && n.title.contains('双端测试报告'),
        );
        expect(notifications.pendingCount, greaterThanOrEqualTo(1));
        if (!resume) {
          expect(await notifications.decide(notice.id, allow: true), isTrue);
          expect(refreshes, 1);
        } else {
          expect(notice.state, NoticeState.allowed);
          report['resumed_same_candidates_without_model_rerun'] = true;
        }
        final recorded = (await progress.load()).commitments.single;
        expect(recorded.evidence.isDocument, isTrue);
        expect(recorded.evidence.documentId, 'dio-document');
        expect(recorded.evidence.uri, isNull);
        checks.addAll({
          'dio_knowledge_upload': true,
          'real_skill_notification': true,
          'consent_to_progress': true,
          'document_provenance_not_fake_voice': true,
        });
        await save();
        final hits = await kb.search('新增电脑端交付是否已经获得同意？');
        expect(hits, isNotEmpty);
        expect(hits.first['retriever'], 'qmd-hybrid');
        expect(await kb.resolve(hits.first), isTrue);
        checks['qmd_search_and_source_resolution'] = true;
        await save();
        final saved = await kb.load();
        await kb.save(
          saved.copyWith(
            projects: [for (final p in saved.projects) p.withAllowed(false)],
          ),
        );
        await bridge.refresh();
        expect(notifications.items, isEmpty);
        expect(await kb.search('Windows'), isEmpty);
        expect(await kb.resolve(hits.first), isFalse);
        checks['revocation_removes_notices_and_evidence'] = true;
        report['passed'] = true;
        await save();
      } catch (error) {
        report['passed'] = false;
        report['failure_type'] = error.runtimeType.toString();
        await save();
        rethrow;
      } finally {
        api.dio.close(force: true);
      }
    },
    skip: !const bool.fromEnvironment('YANSHU_SKILLS_LIVE'),
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
