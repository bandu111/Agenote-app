import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yanshu/core/network/api_client.dart';
import 'package:yanshu/features/notifications/knowledge_assistance.dart';
import 'package:yanshu/features/notifications/notification_model.dart';
import 'package:yanshu/features/progress/repositories/dio_progress_repository.dart';
import 'dio_auth_repository_test.dart' show TestAdapter, envelope;
import 'dio_progress_repository_test.dart' show snapshot;

void main() {
  test('只能知道了的澄清不是待补全，清空后轮询和角标不恢复', () async {
    final client = ApiClient(
      baseUrl: 'https://test.example/',
      dio: Dio()
        ..httpClientAdapter = TestAdapter(
          (request) async => (
            200,
            envelope(request.path.contains('notice-inbox')
                ? {'clearedIds': []}
                : [
              {
                'id': 'meeting-warning:1:r',
                'fingerprint': 'risk',
                'kind': 'warning',
                'title': '上线条件冲突',
                'instruction': '尚有高优先级问题',
                'allowLabel': '知道了',
                'state': 'pending',
              },
            ]),
          ),
        ),
    )..accountId = (() => 'a');
    final notices = NotificationModel();
    final bridge = KnowledgeAssistance(client, notices);
    addTearDown(bridge.dispose);
    addTearDown(notices.dispose);
    final loaded = Completer<void>();
    notices.addListener(() {
      if (notices.items.length == 1 && !loaded.isCompleted) loaded.complete();
    });
    bridge.refreshAccount();
    await loaded.future.timeout(const Duration(seconds: 3));
    expect(notices.pendingCount, 1);
    final question = notices.items.single;
    expect(question.kind, NoticeKind.warning);
    notices.clearAll();
    expect(notices.stateOf(question.id), NoticeState.unavailable);
    await bridge.refresh();
    expect(notices.items, isEmpty);
    expect(notices.pendingCount, 0);
  });

  test('文档依据保留文档和版本，不假装有语音', () async {
    final data = snapshot();
    data['commitments'][0]['evidence'].addAll({
      'kind': 'document',
      'documentId': 'doc',
      'versionId': 'v2',
    });
    final client = ApiClient(
      baseUrl: 'https://test.example/',
      dio: Dio()
        ..httpClientAdapter = TestAdapter((_) async => (200, envelope(data))),
    )..accountId = (() => 'a');
    final evidence = (await DioProgressRepository(
      client,
    ).load()).commitments.single.evidence;
    expect(evidence.isDocument, isTrue);
    expect(evidence.versionId, 'v2');
    expect(evidence.uri, isNull);
    expect(evidence.unavailableReason, '文档依据不包含录音');
  });

  test('通知决定带指纹，记录成功才刷新进展，撤权移除旧通知', () async {
    final requests = <RequestOptions>[];
    var present = true, recorded = 0;
    final client = ApiClient(
      baseUrl: 'https://test.example/',
      dio: Dio()
        ..httpClientAdapter = TestAdapter((o) async {
          requests.add(o);
          if (o.method == 'POST') {
            return (200, envelope({'status': 'recorded'}));
          }
          return (
            200,
            envelope(
              present
                  ? [
                      {
                        'id': 'document-action:j:a',
                        'fingerprint': 'fp',
                        'title': '记录行动',
                        'instruction': '资料原文',
                        'allowLabel': '记录',
                        'state': 'pending',
                      },
                    ]
                  : [],
            ),
          );
        }),
    )..accountId = (() => 'a');
    final notices = NotificationModel();
    final bridge = KnowledgeAssistance(
      client,
      notices,
      onRecorded: () async {
        recorded++;
      },
    );
    addTearDown(bridge.dispose);
    addTearDown(notices.dispose);
    bridge.refreshAccount();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(notices.pendingCount, 0); // 普通资料行动静默保留审批入口。
    expect(await bridge.recordDocumentAction({
      'id': 'document-action:j:a',
      'fingerprint': 'fp',
    }), isTrue);
    expect(recorded, 1);
    final post = requests.singleWhere((r) => r.method == 'POST');
    expect(post.data, {
      'id': 'document-action:j:a',
      'fingerprint': 'fp',
      'allow': true,
    });
    await Future<void>.delayed(const Duration(milliseconds: 20));
    present = false;
    await bridge.refresh();
    expect(notices.items, isEmpty);
  });

  test('账号切换后旧账户晚返回的通知不能进入新账户', () async {
    String? owner = 'a';
    final gate = Completer<void>();
    final started = Completer<void>();
    final client = ApiClient(
      baseUrl: 'https://test.example/',
      dio: Dio()
        ..httpClientAdapter = TestAdapter((o) async {
          if (!started.isCompleted) started.complete();
          await gate.future;
          return (
            200,
            envelope([
              {
                'id': 'private',
                'fingerprint': 'fp',
                'title': '旧账号资料',
                'instruction': '私人内容',
                'allowLabel': '记录',
                'state': 'pending',
              },
            ]),
          );
        }),
    )..accountId = (() => owner);
    final notices = NotificationModel();
    final bridge = KnowledgeAssistance(client, notices);
    addTearDown(bridge.dispose);
    addTearDown(notices.dispose);
    bridge.refreshAccount();
    await started.future;
    owner = 'b';
    bridge.refreshAccount();
    gate.complete();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(notices.items, isEmpty);
  });
}
