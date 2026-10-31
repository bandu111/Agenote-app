import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yanshu/core/network/api_client.dart';
import 'package:yanshu/core/network/api_config.dart';
import 'package:yanshu/features/knowledge/models/knowledge_models.dart';
import 'package:yanshu/features/knowledge/repositories/dio_knowledge_repository.dart';
import 'package:yanshu/features/knowledge/repositories/knowledge_repository.dart';
import 'package:yanshu/features/knowledge/viewmodels/knowledge_view_model.dart';
import 'package:yanshu/features/notifications/account_actions.dart';
import 'package:yanshu/features/notifications/device_calendar_executor.dart';
import 'package:yanshu/features/notifications/notification_model.dart';
import 'dio_auth_repository_test.dart' show TestAdapter, envelope;

class NoCalendar extends DeviceCalendarExecutor {
  @override
  Future<String> deviceId() async => 'test-device-123456';
  @override
  Future<Map<String, dynamic>> execute(
    String owner,
    Map<String, dynamic> action, {
    required bool Function() isCurrent,
  }) async => throw StateError('资料任务不得调用日历');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('OCR 队列完成后自动刷新索引状态及来源缓存，不重载页面或伪装空结果', () async {
    final snapshot = await KnowledgeRepository(
      MemoryKnowledgeStore(),
      seedExamples: true,
    ).load();
    final doc = snapshot.documents.first;
    var indexed = false;
    final dio = Dio()
      ..httpClientAdapter = TestAdapter((request) async {
        if (request.path == 'knowledge') {
          return (
            200,
            envelope({
              'revision': 1,
              'snapshot': snapshot.toJson(),
              'indexStates': [
                {
                  'documentId': doc.id,
                  'versionId': doc.selected.id,
                  'status': 'queued',
                },
              ],
            }),
          );
        }
        if (request.path == 'knowledge/index-status') {
          indexed = true;
          return (
            200,
            envelope([
              {
                'documentId': doc.id,
                'versionId': doc.selected.id,
                'status': 'indexed',
              },
            ]),
          );
        }
        return (
          200,
          envelope(
            indexed
                ? [
                    {
                      'documentId': doc.id,
                      'versionId': doc.selected.id,
                      'hash': doc.selected.hash,
                      'nodeId': 'node',
                      'text': doc.selected.content,
                      'source': doc.source,
                    },
                  ]
                : [],
          ),
        );
      });
    final client = ApiClient(baseUrl: 'https://test.example/', dio: dio)
      ..accountId = (() => 'owner');
    final repo = DioKnowledgeRepository(client);
    final vm = KnowledgeViewModel(repo);
    addTearDown(() {
      vm.dispose();
      dio.close(force: true);
    });
    await vm.load();
    final before = vm.sourceRevision;
    expect(repo.hasPendingIndex, isTrue);
    expect(await vm.findReferences('正在解析的资料'), isEmpty);
    for (var i = 0; i < 100 && repo.hasPendingIndex; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(repo.hasPendingIndex, isFalse);
    expect(vm.sourceRevision, isNot(before));
    expect(await vm.findReferences('正在解析的资料'), isNotEmpty);
  });
  test('工具计划复用通知，批准后回读完成再刷新资料，不能进入日历分支', () async {
    var changed = 0, decisions = 0;
    final dio = Dio()
      ..httpClientAdapter = TestAdapter((request) async {
        if (request.path == 'tasks') return (200, envelope([]));
        if (request.method == 'GET') {
          return (
            200,
            envelope([
              {
                'id': 'p1',
                'kind': 'tool_plan',
                'status': 'pending',
                'title': '创建资料和任务',
                'instruction': '创建后回读核验。',
                'fingerprint': 'digest',
              },
            ]),
          );
        }
        decisions++;
        return (200, envelope({'status': 'completed'}));
      });
    final client = ApiClient(baseUrl: 'https://test.example/', dio: dio)
      ..accountId = (() => 'owner');
    final notifications = NotificationModel();
    final actions = AccountActions(
      client,
      notifications,
      executor: NoCalendar(),
      onChanged: () async {
        changed++;
      },
    );
    addTearDown(() {
      actions.dispose();
      notifications.dispose();
      dio.close(force: true);
    });
    actions.refreshAccount();
    for (var i = 0; i < 20 && notifications.items.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(notifications.items.single.title, '创建资料和任务');
    expect(await notifications.decide('action:p1', allow: true), isTrue);
    expect(changed, 1);
    expect(decisions, 1);
    expect(notifications.items.single.state, NoticeState.completed);
  });

  test('任务复用通知并带版本确认，旧版本提示清除且不调用日历', () async {
    var status = 'pending', version = 1, changed = 0;
    final dio = Dio()
      ..httpClientAdapter = TestAdapter((request) async {
        if (request.path == 'actions?includeToolPlans=true') {
          return (200, envelope([]));
        }
        if (request.path == 'tasks') {
          return (
            200,
            envelope([
              {
                'id': 't1',
                'title': '测试报告',
                'version': version,
                'status': status,
                'evidenceCurrent': true,
              },
            ]),
          );
        }
        expect(request.path, 'tasks/t1/status');
        expect(request.data['version'], version);
        status = request.data['status'] as String;
        version++;
        return (200, envelope({'status': status, 'version': version}));
      });
    final client = ApiClient(baseUrl: 'https://test.example/', dio: dio)
      ..accountId = (() => 'owner');
    final notifications = NotificationModel();
    final actions = AccountActions(
      client,
      notifications,
      executor: NoCalendar(),
      onChanged: () async {
        changed++;
      },
    );
    addTearDown(() {
      actions.dispose();
      notifications.dispose();
      dio.close(force: true);
    });
    actions.refreshAccount();
    for (var i = 0; i < 50 && notifications.items.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(notifications.items.single.title, '开始任务：测试报告');
    expect(await notifications.decide('action:task:t1:1', allow: true), isTrue);
    expect(status, 'active');
    await actions.refresh();
    expect(notifications.items, isEmpty);
    status = 'evidence_verified';
    version++;
    await actions.refresh();
    expect(notifications.items.single.title, '确认任务完成：测试报告');
    expect(await notifications.decide('action:task:t1:3', allow: true), isTrue);
    expect(status, 'verified');
    expect(changed, 2);
    await actions.refresh();
    expect(notifications.items, isEmpty);
  });

  test('后台执行恢复完成后自动刷新现有业务，恢复期间不重复要求批准', () async {
    var completed = false, changed = 0;
    final dio = Dio()
      ..httpClientAdapter = TestAdapter((request) async {
        if (request.path == 'tasks') return (200, envelope([]));
        return (
          200,
          envelope([
            {
              'id': 'recover',
              'kind': 'tool_plan',
              'title': '已批准资料任务',
              'instruction': '恢复未完成步骤',
              'fingerprint': 'digest',
              'status': completed ? 'completed' : 'retryable',
              'approved': true,
              'executionAttempts': 1,
            },
          ]),
        );
      });
    final client = ApiClient(baseUrl: 'https://test.example/', dio: dio)
      ..accountId = (() => 'owner');
    final notifications = NotificationModel();
    final actions = AccountActions(
      client,
      notifications,
      executor: NoCalendar(),
      onChanged: () async {
        changed++;
      },
    );
    addTearDown(() {
      actions.dispose();
      notifications.dispose();
      dio.close(force: true);
    });
    actions.refreshAccount();
    for (var i = 0; i < 50 && notifications.items.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(notifications.items.single.state, NoticeState.preparing);
    expect(notifications.pendingCount, 0);
    // 等首次读取的任务同步结束，再模拟后台工作器完成。
    await Future<void>.delayed(const Duration(milliseconds: 20));
    completed = true;
    await actions.refresh();
    expect(changed, 1);
    expect(notifications.items.single.state, NoticeState.completed);
    await actions.refresh();
    expect(changed, 1);
  });

  test('内置 Office 预览校验 PDF 哈希、源版本和返回期间的账户', () async {
    var owner = 'owner';
    var corrupt = false;
    final bytes = utf8.encode('%PDF-1.7\nsynthetic');
    final dio = Dio()
      ..httpClientAdapter = TestAdapter(
        (request) async => (
          200,
          envelope({
            'documentId': 'doc',
            'versionId': 'v1',
            'sourceHash': 'source',
            'pdfData': base64Encode(bytes),
            'pdfHash': corrupt ? 'wrong' : sha256.convert(bytes).toString(),
          }),
        ),
      );
    final client = ApiClient(baseUrl: 'https://test.example/', dio: dio)
      ..accountId = (() => owner);
    final repository = DioKnowledgeRepository(client);
    addTearDown(() => dio.close(force: true));
    final version = KnowledgeVersion(
      id: 'v1',
      number: 1,
      title: 'Office',
      content: '',
      hash: knowledgeHash(''),
      createdAt: DateTime(2026),
      state: KnowledgeValidity.current,
    );
    final document = KnowledgeDocument(
      id: 'doc',
      folderId: 'inbox',
      projectId: 'p',
      kind: KnowledgeKind.word,
      source: 'import',
      createdAt: DateTime(2026),
      versions: [version],
      selectedVersionId: 'v1',
      ownerUserId: owner,
      fileHash: 'source',
    );
    expect(await repository.preview(document, version), bytes);
    corrupt = true;
    await expectLater(
      repository.preview(document, version),
      throwsA(isA<ApiFailure>()),
    );
    owner = 'other';
    await expectLater(
      repository.preview(document, version),
      throwsA(isA<ApiFailure>()),
    );
  });
}
