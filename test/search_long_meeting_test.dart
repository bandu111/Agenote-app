import 'dart:async';
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:yanshu/features/progress/views/progress_search.dart';
import 'package:yanshu/features/progress/viewmodels/progress_view_model.dart';
import 'package:yanshu/features/progress/repositories/dio_progress_repository.dart';
import 'package:yanshu/features/meeting/meeting_services.dart';
import 'package:yanshu/features/meeting/meeting_store.dart';
import 'package:yanshu/features/meeting/meeting_view_model.dart';
import 'package:yanshu/features/knowledge/viewmodels/knowledge_view_model.dart';
import 'package:yanshu/features/knowledge/repositories/knowledge_repository.dart';
import 'package:yanshu/features/home/viewmodels/home_view_model.dart';
import 'package:yanshu/features/notifications/notification_model.dart';
import 'meeting_test.dart' show FakeMeetingRecorder, FakeMeetingCalendar;
import 'package:yanshu/core/network/api_client.dart';
import 'package:yanshu/core/network/api_config.dart';
import 'package:yanshu/core/network/relevance.dart';
import 'package:yanshu/core/network/unified_search.dart';
import 'package:yanshu/features/meeting/meeting_models.dart';
import 'package:yanshu/features/meeting/meeting_remote.dart';
import 'package:yanshu/features/meeting/speech_turn.dart';
import 'dio_auth_repository_test.dart' show TestAdapter, envelope;

class BackgroundRecorder extends FakeMeetingRecorder
    implements BackgroundRecordingStatus {
  @override
  bool backgroundActive = true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('页内进展搜索防抖且迟到的旧请求不覆盖新结果', (tester) async {
    final queries = <String>[];
    final old = Completer<(int, dynamic)>();
    final api = ApiClient(
      baseUrl: 'https://test/api/v1/',
      dio: Dio()
        ..httpClientAdapter = TestAdapter((r) async {
          final query = r.data['query'] as String;
          queries.add(query);
          if (query == '旧词') return old.future;
          return (
            200,
            envelope([
              {
                'id': query,
                'kind': 'goal',
                'title': query,
                'text': '内容',
                'path': '/progress/goals/new',
              },
            ]),
          );
        }),
    )..accountId = () => 'owner';
    final model = ProgressViewModel(DioProgressRepository(api));
    final query = ValueNotifier('旧词');
    addTearDown(() {
      query.dispose();
      model.dispose();
      api.dio.close(force: true);
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ValueListenableBuilder<String>(
            valueListenable: query,
            builder: (context, value, _) => ProgressSearchResults(
              model: model,
              query: value,
              onOpen: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump();
    expect(queries, ['旧词']);
    query.value = '中间词';
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    query.value = '新词';
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    expect(queries, ['旧词', '新词']);
    expect(find.text('新词'), findsOneWidget);
    old.complete((
      200,
      envelope([
        {
          'id': 'old',
          'kind': 'goal',
          'title': '旧结果',
          'path': '/progress/goals/old',
        },
      ]),
    ));
    await tester.pumpAndSettle();
    await tester.pumpAndSettle();
    expect(find.text('旧结果'), findsNothing);
    expect(find.text('新词'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  }, skip: true);
  testWidgets('现有搜索界面调用统一接口，并返回带原话定位参数的路径', (tester) async {
    final api = ApiClient(
      baseUrl: 'https://test/api/v1/',
      dio: Dio()
        ..httpClientAdapter = TestAdapter((r) async {
          expect(r.path, 'search');
          return (
            200,
            envelope([
              {
                'id': 'source',
                'kind': 'utterance',
                'title': '合同会议',
                'text': '尚未批准新增范围',
                'path': '/meeting?id=old&utterance=u1',
                'matchPercent': 75,
              },
            ]),
          );
        }),
    )..accountId = () => 'owner';
    final model = ProgressViewModel(DioProgressRepository(api));
    String? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                selected = await showSearch<String?>(
                  context: context,
                  delegate: ProgressSearch(model),
                );
              },
              child: const Text('搜索'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('搜索'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Android');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    expect(find.text('合同会议'), findsOneWidget);
    await tester.tap(find.text('合同会议'));
    await tester.pumpAndSettle();
    expect(selected, '/meeting?id=old&utterance=u1');
    model.dispose();
  });
  test('后台服务有效时锁屏不暂停，服务失效仍安全暂停', () async {
    final recorder = BackgroundRecorder();
    final knowledge = KnowledgeViewModel(
      KnowledgeRepository(MemoryKnowledgeStore()),
    );
    await knowledge.load();
    final notifications = NotificationModel(), home = HomeViewModel();
    final vm = MeetingViewModel(
      store: MemoryMeetingStore(),
      recorder: recorder,
      calendar: FakeMeetingCalendar(),
      knowledge: knowledge,
      notifications: notifications,
      home: home,
    );
    await vm.start(demo: false);
    vm.didChangeAppLifecycleState(AppLifecycleState.paused);
    await Future<void>.delayed(Duration.zero);
    expect(recorder.pauses, 0);
    expect(vm.active, isTrue);
    recorder.backgroundActive = false;
    vm.didChangeAppLifecycleState(AppLifecycleState.paused);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(recorder.pauses, 1);
    vm.dispose();
    knowledge.dispose();
    notifications.dispose();
    home.dispose();
  });
  test('跨端同一相关度定义，缺失文本不是零置信度', () {
    for (final row in [
      ['Android', 'android', 100],
      ['Android', 'iOS', 0],
      ['Android iOS', 'Android', 55],
      ['测试', '测试报告', 85],
      ['Android iOS', 'Android iOS Windows', 94],
      ['', '测试', null],
      ['C++', 'C#', 0],
    ]) {
      expect(textRelevancePercent(row[0] as String, row[1] as String), row[2]);
    }
  });
  test('断句保留否定半句、未闭合引用与轻声发言', () {
    for (final text in ['交期是', 'Windows 尚未', '合同包括', '他说“周三之前']) {
      expect(isUnfinishedSpeech(text), isTrue);
    }
    expect(isUnfinishedSpeech('尚未批准 Windows，继续原计划。'), isFalse);
    final gate = SpeechActivityGate();
    for (var i = 0; i < 20; i++) {
      expect(gate.observe(.002), isFalse);
    }
    for (var i = 0; i < 1000; i++) {
      expect(gate.observe(.014), isTrue);
    }
    expect(gate.observe(double.nan), isFalse);
  });
  test('长会议只上传变化片段；首轮、原话变更及账号边界受保护', () async {
    final sent = <RequestOptions>[];
    final api = ApiClient(
      baseUrl: 'https://test/api/v1/',
      dio: Dio()
        ..httpClientAdapter = TestAdapter((r) async {
          sent.add(r);
          return (
            200,
            envelope({'revision': r.data['revision'], 'deltaSupported': true}),
          );
        }),
    )..accountId = () => 'owner';
    final repo = DioMeetingRepository(api);
    final first = MeetingRecord(
      id: 'long',
      ownerId: 'owner',
      demo: false,
      title: '长会议',
      startedAt: DateTime.utc(2026),
      syncRevision: 1,
      utterances: [
        const MeetingUtterance(
          id: 'u1',
          speaker: '发言人 A',
          raw: '尚未批准新增范围',
          at: Duration.zero,
        ),
      ],
    );
    await repo.sync(first, paused: false);
    final next = first.copy(
      syncRevision: 2,
      utterances: [
        ...first.utterances,
        const MeetingUtterance(
          id: 'u2',
          speaker: '发言人 A',
          raw: '保持原计划',
          at: Duration(seconds: 3),
        ),
      ],
    );
    await repo.sync(next, paused: false);
    expect(sent[0].path, 'meetings/sync');
    expect(sent[1].path, 'meetings/sync-delta');
    expect(sent[1].data['baseRevision'], 1);
    expect((sent[1].data['utterances'] as List).map((u) => u['id']), ['u2']);
    expect(jsonEncode(sent[1].data), isNot(contains('尚未批准新增范围')));
    api.accountId = () => 'another';
    await expectLater(
      repo.sync(next, paused: false),
      throwsA(isA<ApiFailure>()),
    );
  });
  test('统一搜索晚响应不能越过账号切换，路径不能跳往外部', () async {
    String owner = 'A';
    final pending = Completer<(int, Object?)>(), requested = Completer<void>();
    final api = ApiClient(
      baseUrl: 'https://test/api/v1/',
      dio: Dio()
        ..httpClientAdapter = TestAdapter((r) async {
          requested.complete();
          return pending.future;
        }),
    )..accountId = () => owner;
    final task = UnifiedSearchRepository(api).search('Android');
    await requested.future;
    owner = 'B';
    final expectation = expectLater(task, throwsA(isA<ApiFailure>()));
    pending.complete((
      200,
      envelope([
        {
          'id': 'u',
          'kind': 'utterance',
          'title': 'A的原话',
          'text': '私有内容',
          'path': '/meeting?id=a',
        },
      ]),
    ));
    await expectation;
  });
}
