import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:provider/provider.dart';
import 'package:yanshu/app/app.dart';
import 'package:yanshu/core/network/api_client.dart';
import 'package:yanshu/features/knowledge/models/knowledge_models.dart';
import 'package:yanshu/features/knowledge/repositories/dio_knowledge_repository.dart';
import 'package:yanshu/features/knowledge/viewmodels/knowledge_view_model.dart';
import 'package:yanshu/features/knowledge/views/knowledge_page.dart';
import 'package:yanshu/features/profile/repositories/profile_repository.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('真机滑动删除、云端回读和会议重复归档', (tester) async {
    final api = ApiClient(baseUrl: 'http://127.0.0.1:18861/api/v1/');
    const password = 'Device-knowledge-delete-2026';
    String? owner;
    final checks = <String, bool>{};
    final report = <String, dynamic>{
      'realBackend': true,
      'isolatedTestAccount': true,
      'checks': checks,
    };
    Future<void> waitFor(bool Function() predicate, {int seconds = 30}) async {
      final until = DateTime.now().add(Duration(seconds: seconds));
      while (DateTime.now().isBefore(until)) {
        await tester.pump(const Duration(milliseconds: 50));
        if (predicate()) return;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      fail('等待资料页面超时');
    }

    try {
      final data = (await api.post(
        'auth/register',
        data: {
          'name': '删除联调',
          'email':
              'kb-delete-${DateTime.now().microsecondsSinceEpoch}@example.com',
          'password': password,
        },
      ))['data'];
      owner = data['user']['id'] as String;
      final token = data['access_token'] as String;
      api.accountId = () => owner;
      api.accessToken = () async => token;
      final repo = DioKnowledgeRepository(api);
      await tester.pumpWidget(
        YanShuApp(
          initialLocation: '/knowledge',
          profileRepository: ProfileRepository(MemoryProfileStore()),
          knowledgeRepository: repo,
        ),
      );
      await waitFor(() => find.byType(KnowledgePage).evaluate().isNotEmpty);
      final vm = tester
          .element(find.byType(KnowledgePage))
          .read<KnowledgeViewModel>();
      await waitFor(() => !vm.loading);
      final doc = await vm.addDocument(
        title: '测试上传文件',
        content: '仅用于验证删除的临时文本',
        folderId: 'inbox',
        projectId: 'personal',
        kind: KnowledgeKind.text,
        allowed: false,
      );
      expect(doc, isNotNull);
      await tester.pump();
      final card = find.byKey(ValueKey('knowledge-dismiss-$doc'));
      await tester.ensureVisible(card);
      await tester.pump();
      await tester.drag(card, const Offset(340, 0));
      await tester.pumpAndSettle();
      expect(find.text('从言枢移除这份资料？'), findsOneWidget);
      await tester.tap(find.text('移除').last);
      await waitFor(() => !vm.saving && vm.document(doc!) == null);
      expect((await repo.load()).documents.any((d) => d.id == doc), false);
      checks['swipeDeleteUploadedDocumentAndReadBack'] = true;
      await api.post(
        'meetings/sync',
        authenticated: true,
        accountId: owner,
        data: {
          'id': 'phone-delete-meeting',
          'revision': 1,
          'title': '测试会议',
          'startedAt': '2026-10-19T10:00:00+08:00',
          'elapsed': 1000,
          'ended': true,
          'utterances': [],
        },
      );
      await api.post(
        'meetings/phone-delete-meeting/archive',
        authenticated: true,
        accountId: owner,
        receiveTimeout: const Duration(seconds: 90),
      );
      await vm.load();
      final meetingId = 'meeting-phone-delete-meeting';
      expect(vm.document(meetingId), isNotNull);
      expect(await vm.delete(meetingId), true);
      await api.post(
        'meetings/phone-delete-meeting/archive',
        authenticated: true,
        accountId: owner,
        receiveTimeout: const Duration(seconds: 90),
      );
      await vm.load();
      expect(vm.document(meetingId), isNull);
      checks['meetingDeleteSurvivesRepeatedArchive'] = true;
      final after = DioKnowledgeRepository(api);
      final fresh = await after.load();
      expect(
        fresh.documents.any((d) => d.id == doc || d.id == meetingId),
        false,
      );
      checks['freshRepositoryDoesNotRestoreDeletedDocuments'] = true;
      report['passed'] = true;
    } catch (error) {
      report['passed'] = false;
      report['error'] = error.toString();
      rethrow;
    } finally {
      if (owner != null) {
        try {
          await api.post(
            'auth/delete-account',
            authenticated: true,
            accountId: owner,
            data: {'current_password': password, 'confirmation': 'DELETE'},
          );
          report['testAccountDeleted'] = true;
        } catch (_) {
          report['testAccountDeleted'] = false;
        }
      }
      binding.reportData = report;
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    }
  }, timeout: const Timeout(Duration(minutes: 5)));
}
