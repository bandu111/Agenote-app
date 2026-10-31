import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yanshu/core/network/api_client.dart';
import 'package:yanshu/core/network/api_config.dart';
import 'package:yanshu/features/meeting/meeting_models.dart';
import 'package:yanshu/features/meeting/meeting_remote.dart';
import 'package:yanshu/features/meeting/meeting_store.dart';
import 'package:yanshu/features/meeting/meeting_questions.dart';
import 'package:yanshu/features/meeting/meeting_question_widgets.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('云端会后疑问在未绑定微信的手机展示回答与原声依据', (tester) async {
    final api = ApiClient(baseUrl: 'https://124.220.169.122/api/v1/');
    final stamp = DateTime.now().microsecondsSinceEpoch;
    const password = 'Question-phone-QA-2026!';
    final email = 'question-phone-$stamp@example.com';
    final auth = (await api.post('auth/register', data: {
      'name': '疑问链路隔离测试', 'email': email, 'password': password,
    }))['data'];
    final owner = auth['user']['id'] as String;
    api.accountId = () => owner;
    api.accessToken = () async => auth['access_token'] as String;
    final questions = MeetingQuestions(MemoryMeetingStore(), DioMeetingRepository(api));
    try {
      final r = MeetingRecord(id: 'question-phone-$stamp', ownerId: owner,
        title: '接口超时验证', startedAt: DateTime.now(), ended: true,
        elapsed: const Duration(seconds: 75), syncRevision: 1, demo: false,
        utterances: const [
          MeetingUtterance(id: 'u1', speaker: '发言人 A', raw: 'ERP接口超时是否会造成数据丢失？', at: Duration(seconds: 5)),
          MeetingUtterance(id: 'u2', speaker: '发言人 B', raw: '不会造成数据永久丢失，失败后会自动重试。工单状态可能延迟两三分钟。', at: Duration(seconds: 20)),
          MeetingUtterance(id: 'u3', speaker: '发言人 A', raw: '请先确认重试机制，再安排上线。', at: Duration(seconds: 55)),
        ]);
      final remote = DioMeetingRepository(api);
      await remote.sync(r, paused: false);
      try { await remote.archive(r); } on ApiFailure {
        // Direct retry keeps the original meeting; a failed model job is not a successful archive.
        await api.post('meetings/${r.id}/archive', authenticated: true, accountId: owner, receiveTimeout: const Duration(minutes: 3));
      }
      final qid = await questions.create(r, atMs: 5000);
      await questions.edit(r, qid, text: 'ERP接口超时是否会造成数据永久丢失？');
      var synced = false;
      for (var i = 0; i < 8; i++) {
        if (await questions.sync(r)) { synced = true; break; }
        await tester.runAsync(() => Future<void>.delayed(const Duration(seconds: 1)));
      }
      expect(synced, isTrue, reason: questions.error);
      Map<String, dynamic>? done;
      for (var i = 0; i < 90; i++) {
        final data = (await api.get('meetings/${r.id}/questions', authenticated: true, accountId: owner))['data'] as List;
        final q = Map<String, dynamic>.from(data.single);
        if (q['analysis']?['state'] == 'answered') { done = q; break; }
        await tester.runAsync(() => Future<void>.delayed(const Duration(seconds: 2)));
      }
      expect(done, isNotNull, reason: '真实后台应返回带依据的回答');
      expect(done!['content']['status'], 'pending');
      final evidence = done['analysis']['answers'][0]['evidence'] as List;
      expect(evidence.any((e) => e['id'] == 'u2'), isTrue);
      // Wait for normal repository refresh, as in the real page.
      await tester.runAsync(() => Future<void>.delayed(const Duration(seconds: 31)));
      await questions.sync(r);
      String? opened;
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: SingleChildScrollView(
        child: MeetingQuestionList(questions: questions, record: r, minutesStyle: true,
          onSource: (id) => opened = id)))));
      await tester.pumpAndSettle();
      expect(find.text('有参考答案'), findsOneWidget);
      await tester.tap(find.text('ERP接口超时是否会造成数据永久丢失？'));
      await tester.pumpAndSettle();
      expect(find.text('会议中有明确回答'), findsOneWidget);
      final links = find.textContaining('查看原始依据');
      expect(links, findsWidgets);
      await tester.ensureVisible(links.last);
      await tester.tap(links.last);
      expect(opened, 'u2');
      expect(tester.takeException(), isNull);
    } on ApiFailure catch (failure) {
      fail('云端接口失败：${failure.message}，HTTP ${failure.status}');
    } finally {
      questions.dispose();
      await api.post('auth/delete-account', authenticated: true, accountId: owner,
        data: {'current_password': password, 'confirmation': 'DELETE'});
    }
  }, timeout: const Timeout(Duration(minutes: 8)));
}
