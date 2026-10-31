import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yanshu/core/network/api_client.dart';
import 'package:yanshu/features/home/models/schedule_item.dart';
import 'package:yanshu/features/home/repositories/dio_home_repository.dart';
import 'package:yanshu/features/home/repositories/schedule_repository.dart';
import 'package:yanshu/features/home/viewmodels/home_view_model.dart';
import 'package:yanshu/features/home/viewmodels/schedule_view_model.dart';
import 'dio_auth_repository_test.dart' show TestAdapter, envelope;

Map<String, dynamic> homeData() => {
  'title': '账户目标',
  'rows': [
    {'label': '待核对', 'text': '验收条件待确认'},
  ],
  'decisions': [
    {'title': '确认交期', 'body': '请补充交期', 'route': '/notifications'},
  ],
  'tasks': [
    {
      'id': 'commitment:a',
      'title': '真实会议任务',
      'deadline': '2030-10-28T14:00:00+08:00',
      'version': 1,
      'sourceRoute': '/progress/commitments/a',
      'endsAt': '2030-10-28T15:00:00+08:00',
      'kind': 'meeting',
      'completed': false,
      'source': '已核验日历行动',
    },
  ],
};

void main() {
  test(
    'source meeting date alone is enough to place an undated action on the calendar',
    () async {
      final api = ApiClient(
        baseUrl: 'https://test.example/',
        dio: Dio()
          ..httpClientAdapter = TestAdapter(
            (_) async => (
              200,
              envelope({
                'tasks': [
                  {
                    'id': 'source-only',
                    'title': '补全接口文档',
                    'version': 1,
                    'sourceMeetingDate': '2026-10-22',
                    'deadline': null,
                  },
                ],
              }),
            ),
          ),
      )..accountId = (() => 'owner');
      final item = (await DioHomeRepository(api).load()).single;
      expect(item.hasDeadline, isFalse);
      expect(item.hasCalendarDate, isTrue);
      final model = ScheduleViewModel(
        HomeMockScheduleRepository([item]),
        listenToTime: false,
      );
      addTearDown(model.dispose);
      await model.refresh();
      expect(
        model.entriesOn(DateTime(2026, 10, 22)).single.item.id,
        'source-only',
      );
      expect(model.pendingTaskEntries.single.item.id, 'source-only');
    },
  );
  test('归档提交后不复用提交前仍在途的首页快照', () async {
    final old = Completer<(int, Map<String, dynamic>)>();
    var calls = 0;
    final api =
        ApiClient(
            baseUrl: 'https://test.example/',
            dio: Dio()
              ..httpClientAdapter = TestAdapter((_) {
                calls++;
                if (calls == 1) return old.future;
                return Future.value((200, envelope(homeData())));
              }),
          )
          ..accountId = (() => 'owner')
          ..accessToken = (() async => 'token');
    final repo = DioHomeRepository(api);
    final before = repo.snapshot();
    await Future<void>.delayed(Duration.zero);
    repo.invalidateSnapshot();
    final fresh = await repo.load();
    expect(calls, 2);
    expect(fresh.single.id, 'commitment:a');
    old.complete((200, envelope({'tasks': []})));
    expect((await before)['tasks'], isEmpty);
  });
  test('任务和会议分别读取，候选会议不冒充已授权', () async {
    final api =
        ApiClient(
            baseUrl: 'https://test.example/',
            dio: Dio()
              ..httpClientAdapter = TestAdapter(
                (_) async => (
                  200,
                  envelope({
                    ...homeData(),
                    'schedules': [
                      {
                        'id': 'calendar:a',
                        'title': 'ERP方案评审',
                        'startsAt': '2030-10-29T14:00:00+08:00',
                        'endsAt': '2030-10-29T15:00:00+08:00',
                        'kind': 'meeting',
                        'reviewPending': true,
                        'sourceRoute': '/notifications',
                      },
                    ],
                  }),
                ),
              ),
          )
          ..accountId = (() => 'owner')
          ..accessToken = (() async => 'token');
    final rows = await DioHomeRepository(api).load();
    expect(rows.length, 2);
    expect(rows.first.id, 'calendar:a');
    expect(rows.first.reviewPending, true);
    expect(rows.first.sourceRoute, '/notifications');
    expect(rows.last.id, 'commitment:a');
  });

  test('首页与日程共享认证读取，不回退演示，不伪造完成', () async {
    var calls = 0;
    final api =
        ApiClient(
            baseUrl: 'https://test.example/',
            dio: Dio()
              ..httpClientAdapter = TestAdapter((o) async {
                calls++;
                expect(o.headers['Authorization'], 'Bearer token');
                if (o.method == 'POST') {
                  expect(o.path, 'home/tasks/commitment%3Aa/complete');
                  expect(o.data, {'version': 1});
                  return (
                    200,
                    envelope({
                      'id': 'commitment:a',
                      'version': 2,
                      'completed': true,
                    }),
                  );
                }
                return (200, envelope(homeData()));
              }),
          )
          ..accountId = (() => 'owner')
          ..accessToken = (() async => 'token');
    final repo = DioHomeRepository(api);
    final result = await Future.wait([repo.snapshot(), repo.load()]);
    expect(calls, 1);
    expect((result[0] as Map)['title'], '账户目标');
    final entries = await repo.load();
    expect(entries.single.completed, false);
    expect(entries.single.sourceRoute, '/progress/commitments/a');
    await repo.markCompleted(entries.single.id);
  });

  test('账户切换立即清空首页和日程，晚返回不能跨账户展示', () async {
    String? owner = 'a';
    final pending = Completer<(int, Map<String, dynamic>)>();
    final api =
        ApiClient(
            baseUrl: 'https://test.example/',
            dio: Dio()..httpClientAdapter = TestAdapter((o) => pending.future),
          )
          ..accountId = (() => owner)
          ..accessToken = (() async => 'token');
    final repo = DioHomeRepository(api);
    final home = HomeViewModel(repository: repo)..refreshAccount();
    final schedule = ScheduleViewModel(repo)..refreshAccount();
    await Future<void>.delayed(Duration.zero);
    owner = null;
    home.refreshAccount();
    schedule.refreshAccount();
    expect(home.hasSessionData, false);
    expect(home.data, isEmpty);
    expect(schedule.entries, isEmpty);
    pending.complete((200, envelope(homeData())));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(home.data, isEmpty);
    expect(schedule.entries, isEmpty);
    expect(await repo.load(), isEmpty);
    home.dispose();
    schedule.dispose();
  });

  test('权威会议安全读取会前准备字段，完成复制不丢失元数据', () async {
    final api =
        ApiClient(
            baseUrl: 'https://test.example/',
            dio: Dio()
              ..httpClientAdapter = TestAdapter(
                (_) async => (
                  200,
                  envelope({
                    'tasks': <Object?>[],
                    'schedules': [
                      {
                        'id': 'calendar:action-1',
                        'title': '项目评审',
                        'startsAt': '2030-10-29T14:00:00+08:00',
                        'endsAt': '2030-10-29T15:00:00+08:00',
                        'kind': 'meeting',
                        'preparationId': 'opaque-prep_1',
                        'preparationStatus': 'succeeded',
                        'preparationSummary': '先核对客户验收范围。',
                        'preparationRoute': '/outcomes/opaque-prep_1',
                        'agenda': '确认验收范围',
                        'timeZone': 'Asia/Shanghai',
                        'authority':
                            'authenticated_device_receipt_fields_matched',
                        'actionVersion': 3,
                        'verifiedAt': '2030-10-28T01:02:03Z',
                      },
                    ],
                  }),
                ),
              ),
          )
          ..accountId = (() => 'owner')
          ..accessToken = (() async => 'token');
    final item = (await DioHomeRepository(api).load()).single;
    expect(item.preparationId, 'opaque-prep_1');
    expect(item.preparationStatus, 'succeeded');
    expect(item.preparationSummary, '先核对客户验收范围。');
    expect(item.preparationRoute, '/outcomes/opaque-prep_1');
    expect(item.agenda, '确认验收范围');
    expect(item.timeZone, 'Asia/Shanghai');
    expect(item.actionVersion, 3);
    expect(item.verifiedAt, DateTime.utc(2030, 10, 28, 1, 2, 3));
    final completed = item.complete();
    expect(completed.completed, isTrue);
    expect(completed.preparationId, item.preparationId);
    expect(completed.preparationRoute, item.preparationRoute);
    expect(completed.agenda, item.agenda);
    expect(completed.authority, item.authority);
    expect(completed.actionVersion, item.actionVersion);
    expect(completed.verifiedAt, item.verifiedAt);
  });

  test('会前准备可选字段类型错误与危险 route 被丢弃且不拖垮首页', () async {
    final routes = <Object?>[
      'https://evil.example/outcomes/private',
      '/outcomes/../private',
      '/outcomes/%2Fprivate',
      '/outcomes/other-id',
      42,
      null,
    ];
    final api = ApiClient(
      baseUrl: 'https://test.example/',
      dio: Dio()
        ..httpClientAdapter = TestAdapter(
          (_) async => (
            200,
            envelope({
              'tasks': <Object?>[],
              'schedules': [
                for (var index = 0; index < routes.length; index++)
                  {
                    'id': 'calendar:$index',
                    'title': '安全会议 $index',
                    'startsAt': '2030-10-29T14:00:00+08:00',
                    'kind': 'meeting',
                    'preparationId': 'expected-id',
                    'preparationStatus': index == 0 ? <String>[] : 7,
                    'preparationSummary': {'private': true},
                    'preparationRoute': routes[index],
                    'agenda': <String>[],
                    'timeZone': false,
                    'authority': 1,
                    'actionVersion': '3',
                    'verifiedAt': {'bad': true},
                  },
              ],
            }),
          ),
        ),
    )..accountId = (() => 'owner');
    final items = await DioHomeRepository(api).load();
    expect(items, hasLength(routes.length));
    for (final item in items) {
      expect(item.preparationRoute, isNull);
      expect(item.preparationStatus, isNull);
      expect(item.preparationSummary, isNull);
      expect(item.agenda, isNull);
      expect(item.timeZone, isNull);
      expect(item.authority, isNull);
      expect(item.actionVersion, isNull);
      expect(item.verifiedAt, isNull);
    }
    expect(
      validatedPreparationRoute(
        '/outcomes/right-id',
        preparationId: 'right-id',
      ),
      '/outcomes/right-id',
    );
  });
}
