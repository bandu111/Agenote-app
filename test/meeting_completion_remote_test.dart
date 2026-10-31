import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yanshu/core/network/api_client.dart';
import 'package:yanshu/core/network/api_config.dart';
import 'package:yanshu/features/meeting/meeting_models.dart';
import 'package:yanshu/features/meeting/meeting_remote.dart';
import 'dio_auth_repository_test.dart' show TestAdapter, envelope;

void main() {
  test('Dio仅绑定同会议原话履约项，确认使用版本且返回已确认状态', () async {
    var calls = 0;
    final value = {
      'id': 'c',
      'title': '报告',
      'version': 3,
      'kind': 'commitment',
      'status': 'pending',
      'side': 'unknown',
      'deadline': null,
      'authorizationStatus': 'pending',
      'evidence': {'sessionId': 'm', 'id': 'u'},
    };
    final dio = Dio()
      ..httpClientAdapter = TestAdapter((options) async {
        calls++;
        if (options.method == 'GET') {
          return (
            200,
            envelope({
              'pending': [
                value,
                {
                  ...value,
                  'id': 'other-meeting',
                  'evidence': {'sessionId': 'another', 'id': 'u'},
                },
                {
                  ...value,
                  'id': 'other-source',
                  'evidence': {'sessionId': 'm', 'id': 'else'},
                },
                {...value, 'id': 'withdrawn', 'status': 'withdrawn'},
              ],
              'commitments': [],
            }),
          );
        }
        expect(options.path, 'progress/c/complete');
        expect(options.data['confirm'], true);
        expect(options.data['version'], 3);
        expect(options.data['side'], 'ours');
        expect(DateTime.parse(options.data['deadline']).isUtc, true);
        return (
          200,
          envelope({
            ...value,
            'version': 4,
            'side': 'ours',
            'deadline': options.data['deadline'],
            'status': 'planned',
            'authorizationStatus': 'owner_confirmed',
          }),
        );
      });
    final client = ApiClient(baseUrl: 'https://test.example/', dio: dio)
      ..accountId = (() => 'a')
      ..accessToken = (() async => 'test-token');
    final repo = DioMeetingRepository(client);
    final record = MeetingRecord(
      id: 'm',
      startedAt: DateTime(2026),
      ownerId: 'a',
      demo: false,
    );
    final items = await repo.completionItems(record, ['u']);
    expect(items.map((i) => i.id), ['c']);
    final saved = await repo.confirmCompletion(
      record,
      items.single,
      side: 'ours',
      deadline: DateTime(2026, 11, 1, 23, 59, 59),
    );
    expect(saved.confirmed, true);
    expect(saved.version, 4);
    expect(calls, 2);
  });

  test('账户切换时拒绝发送旧会议的补全请求', () async {
    var requests = 0;
    final dio = Dio()
      ..httpClientAdapter = TestAdapter((options) async {
        requests++;
        return (200, envelope(null));
      });
    final client = ApiClient(baseUrl: 'https://test.example/', dio: dio)
      ..accountId = (() => 'new-account')
      ..accessToken = (() async => 'test-token');
    final record = MeetingRecord(
      id: 'm',
      startedAt: DateTime(2026),
      ownerId: 'old-account',
      demo: false,
    );
    await expectLater(
      DioMeetingRepository(client).completionItems(record, ['u']),
      throwsA(isA<ApiFailure>()),
    );
    expect(requests, 0);
  });
}
