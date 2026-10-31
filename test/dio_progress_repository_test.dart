import 'dart:async';
import 'package:yanshu/features/meeting/meeting_models.dart';
import 'package:yanshu/features/meeting/meeting_store.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yanshu/core/network/api_client.dart';
import 'package:yanshu/core/network/api_config.dart';
import 'package:yanshu/features/progress/models/progress_models.dart';
import 'package:yanshu/features/progress/repositories/dio_progress_repository.dart';
import 'package:yanshu/features/progress/viewmodels/progress_view_model.dart';
import 'dio_auth_repository_test.dart' show TestAdapter, envelope;

Map<String, dynamic> snapshot() => {
  'goals': [
    {
      'id': 'g1',
      'title': '真实目标',
      'condition': '交付测试报告',
      'acceptance': '合同指标',
      'phase': '测试',
      'deadline': '2026-11-05T18:00:00+08:00',
      'status': 'pending',
      'version': 1,
      'milestones': [
        {'title': '测试', 'weight': 1, 'status': 'pending'},
      ],
      'history': [],
    },
  ],
  'commitments': [
    {
      'id': 'c1',
      'title': '提交报告',
      'person': '发言人 A',
      'side': 'ours',
      'status': 'pending',
      'version': 3,
      'summary': '原话来源',
      'goalId': 'g1',
      'createdAt': '2026-10-19T10:00:00+08:00',
      'deadline': '2026-10-28T23:59:00+08:00',
      'evidence': {
        'id': 'u1',
        'sessionId': 'm1',
        'transcript': '我方承诺提交报告',
        'start': 1000,
        'end': 1000,
        'recordedAt': '2026-10-19T10:00:00+08:00',
        'timeZone': 'Asia/Shanghai',
      },
      'history': [],
    },
  ],
  'artifacts': [],
  'pending': [],
};

void main() {
  test(
    'goal removal submits account scope and current goal version to the dedicated endpoint',
    () async {
      final requests = <RequestOptions>[];
      final api =
          ApiClient(
              baseUrl: 'https://test.example/',
              dio: Dio()
                ..httpClientAdapter = TestAdapter((o) async {
                  requests.add(o);
                  return (
                    200,
                    envelope(
                      o.method == 'GET' ? snapshot() : {'removed': true},
                    ),
                  );
                }),
            )
            ..accountId = (() => 'owner')
            ..accessToken = (() async => 'token');
      final repo = DioProgressRepository(api);
      await repo.load();
      await repo.removeGoal('g1');
      final post = requests.last;
      expect(post.path, 'progress/goals/g1/remove');
      expect(post.headers['Authorization'], 'Bearer token');
      expect(post.data['version'], 1);
      expect(post.data['note'], contains('保留原始记录'));
    },
  );
  test('完成承诺调用状态接口提交 claimed、版本与待核实说明', () async {
    final requests = <RequestOptions>[];
    final data = snapshot();
    (data['commitments'] as List).first['status'] = 'planned';
    final api =
        ApiClient(
            baseUrl: 'https://test.example/',
            dio: Dio()
              ..httpClientAdapter = TestAdapter((o) async {
                requests.add(o);
                return (200, envelope(o.method == 'GET' ? data : {}));
              }),
          )
          ..accountId = (() => 'a')
          ..accessToken = (() async => 'token');
    final repo = DioProgressRepository(api);
    await repo.load();
    await repo.updateCommitment(
      'c1',
      CommitmentStatus.claimed,
      '用户声明承诺已完成，待核实',
    );
    expect(requests.last.method, 'POST');
    expect(requests.last.path, endsWith('progress/commitments/c1/status'));
    expect(requests.last.data, {
      'version': 3,
      'status': 'claimed',
      'note': '用户声明承诺已完成，待核实',
    });
  });

  test('移除沿用状态接口提交 withdrawn、版本及审计说明，不调用删除接口', () async {
    final requests = <RequestOptions>[];
    final api =
        ApiClient(
            baseUrl: 'https://test.example/',
            dio: Dio()
              ..httpClientAdapter = TestAdapter((o) async {
                requests.add(o);
                return (200, envelope(o.method == 'GET' ? snapshot() : {}));
              }),
          )
          ..accountId = (() => 'a')
          ..accessToken = (() async => 'token');
    final repo = DioProgressRepository(api);
    await repo.load();
    await repo.updateCommitment('c1', CommitmentStatus.withdrawn, '用户移除');
    expect(requests.last.method, 'POST');
    expect(requests.last.path, endsWith('progress/commitments/c1/status'));
    expect(requests.last.data, {
      'version': 3,
      'status': 'withdrawn',
      'note': '用户移除',
    });
    expect(requests.any((r) => r.method == 'DELETE'), isFalse);
  });

  test('实体同 ID 使用各自版本，异常单条不阻断有效目标', () async {
    final data = snapshot();
    (data['commitments'] as List).first['id'] = 'g1';
    (data['goals'] as List).add({'id': 'invalid', 'version': 99});
    final requests = <RequestOptions>[];
    final api =
        ApiClient(
            baseUrl: 'https://test.example/',
            dio: Dio()
              ..httpClientAdapter = TestAdapter((o) async {
                if (o.method == 'GET') return (200, envelope(data));
                requests.add(o);
                return (200, envelope({}));
              }),
          )
          ..accountId = (() => 'a')
          ..accessToken = (() async => 'token');
    final repo = DioProgressRepository(api);
    final loaded = await repo.load();
    expect(loaded.goals, hasLength(1));
    expect(repo.skippedRows, 1);
    await repo.updateCommitment('g1', CommitmentStatus.planned, 'confirm');
    expect((requests.single.data as Map)['version'], 3);
  });
  test('承诺展示优先纠正和整理，原始引用不变且不串用不匹配来源', () async {
    final api =
        ApiClient(
            baseUrl: 'https://test.example/',
            dio: Dio()
              ..httpClientAdapter = TestAdapter(
                (o) async => (200, envelope(snapshot())),
              ),
          )
          ..accountId = (() => 'a')
          ..accessToken = (() async => 'token');
    final store = MemoryMeetingStore();
    final repo = DioProgressRepository(api, meetingStore: store);
    for (final row in [
      ('我方承诺提交报告', '我方承诺，提交报告。', '人工确认：提交报告。', '人工确认：提交报告。'),
      ('我方承诺提交报告', '我方承诺，提交报告。', ' ', '我方承诺，提交报告。'),
      ('我方承诺提交报告', ' ', '', '我方承诺提交报告'),
      ('不同的原文', '错误的整理', '错误的纠正', '我方承诺提交报告'),
    ]) {
      await store.save(
        MeetingRecord(
          id: 'm1',
          ownerId: 'a',
          startedAt: DateTime(2026),
          demo: false,
          utterances: [
            MeetingUtterance(
              id: 'u1',
              speaker: '待确认',
              raw: row.$1,
              cleaned: row.$2,
              correction: row.$3,
              at: Duration.zero,
            ),
          ],
        ),
      );
      final evidence = (await repo.load()).commitments.single.evidence;
      expect(evidence.displayTranscript, row.$4);
      expect(evidence.transcript, '我方承诺提交报告');
    }
  });

  test('Dio解析真实进展，写操作带版本且不上传音频或owner', () async {
    final requests = <RequestOptions>[];
    final api =
        ApiClient(
            baseUrl: 'https://test.example/',
            dio: Dio()
              ..httpClientAdapter = TestAdapter((o) async {
                requests.add(o);
                return (200, envelope(o.method == 'GET' ? snapshot() : {}));
              }),
          )
          ..accountId = (() => 'a')
          ..accessToken = (() async => 'token');
    final repo = DioProgressRepository(api);
    final data = await repo.load();
    expect(data.demo, isFalse);
    expect(data.goals.single.title, '真实目标');
    expect(data.commitments.single.side, CommitmentSide.ours);
    expect(data.commitments.single.evidence.speakerConfirmed, isFalse);
    expect(data.commitments.single.evidence.uri, isNull);
    await repo.updateCommitment('c1', CommitmentStatus.planned, '人工确认');
    expect(requests.last.data, {
      'version': 3,
      'status': 'planned',
      'note': '人工确认',
    });
    expect(requests.last.headers['Authorization'], 'Bearer token');
    await expectLater(
      repo.updateCommitment('c1', CommitmentStatus.withdrawn, '旧版本'),
      throwsA(isA<ApiFailure>()),
    );
  });

  test('账号切换立即隐藏旧进展，晚返回数据不能进入新账户', () async {
    String? owner = 'a';
    final gate = Completer<void>();
    var block = false;
    final api =
        ApiClient(
            baseUrl: 'https://test.example/',
            dio: Dio()
              ..httpClientAdapter = TestAdapter((o) async {
                if (block) await gate.future;
                return (200, envelope(snapshot()));
              }),
          )
          ..accountId = (() => owner)
          ..accessToken = (() async => 'token');
    final repo = DioProgressRepository(api);
    final vm = ProgressViewModel(repo);
    await vm.load();
    expect(vm.data.goals, isNotEmpty);
    block = true;
    final pending = vm.load();
    await Future<void>.delayed(Duration.zero);
    owner = 'b';
    expect(vm.data.goals, isEmpty);
    expect(vm.search('真实'), isEmpty);
    gate.complete();
    await pending;
    expect(vm.data.goals, isEmpty);
    await expectLater(
      repo.updateCommitment('c1', CommitmentStatus.planned, '错误账户'),
      throwsA(isA<ApiFailure>()),
    );
    owner = null;
    expect((await repo.load()).goals, isEmpty);
    vm.dispose();
  });

  test('网络失败不回退演示，刷新后空账户保持空数据', () async {
    final api =
        ApiClient(
            baseUrl: 'https://test.example/',
            dio: Dio()
              ..httpClientAdapter = TestAdapter(
                (o) async => (503, envelope(null, status: 503)),
              ),
          )
          ..accountId = (() => 'a')
          ..accessToken = (() async => 'token');
    final vm = ProgressViewModel(DioProgressRepository(api));
    await vm.load();
    expect(vm.error, isNotNull);
    expect(vm.data.goals, isEmpty);
    vm.dispose();
  });
}
