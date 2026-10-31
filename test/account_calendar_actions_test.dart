import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yanshu/core/network/api_client.dart';
import 'package:yanshu/features/notifications/account_actions.dart';
import 'package:yanshu/features/notifications/device_calendar_executor.dart';
import 'package:yanshu/features/notifications/notification_model.dart';
import 'dio_auth_repository_test.dart' show TestAdapter, envelope;

class CapturingCalendarExecutor extends DeviceCalendarExecutor {
  final commands = <Map<String, dynamic>>[];

  @override
  Future<String> deviceId() async => 'test-device-123456';

  @override
  Future<Map<String, dynamic>> execute(
    String owner,
    Map<String, dynamic> action, {
    required bool Function() isCurrent,
  }) async {
    commands.add(Map<String, dynamic>.from(action));
    final target = action['target'] is Map
        ? Map<String, dynamic>.from(action['target'] as Map)
        : const <String, dynamic>{};
    final eventId = target['eventId'] as String? ?? 'created-event';
    return {
      'verified': true,
      'eventId': eventId,
      'previousEventId': action['operation'] == 'create' ? null : eventId,
      'calendarId': target['calendarId'] ?? 'calendar-1',
      'deleted': action['operation'] == 'cancel',
      'fingerprint': action['fingerprint'],
      'title': action['title'],
      'start': action['start'],
      'end': action['end'],
    };
  }
}

Future<void> waitForNotice(NotificationModel model, String id) async {
  for (var i = 0; i < 100 && !model.items.any((item) => item.id == id); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('日历审批使用稳定 mutationId、服务端批准 action 和批准后的 version', () async {
    final executor = CapturingCalendarExecutor();
    final decisions = <Map<String, dynamic>>[];
    final receipts = <Map<String, dynamic>>[];
    var receiptAttempts = 0;
    final requested = <String, dynamic>{
      'id': 'reschedule-1',
      'version': 1,
      'kind': 'calendar',
      'operation': 'reschedule',
      'status': 'pending',
      'fingerprint': 'approved-fingerprint',
      'title': '客户端旧标题',
      'start': '2030-11-10T14:00:00+08:00',
      'end': '2030-11-10T14:30:00+08:00',
      'target': {
        'eventId': 'native-event-1',
        'calendarId': 'calendar-1',
        'deviceId': 'test-device-123456',
      },
    };
    final dio = Dio()
      ..httpClientAdapter = TestAdapter((request) async {
        if (request.path == 'actions?includeToolPlans=true') {
          return (200, envelope([requested]));
        }
        if (request.path == 'tasks') return (200, envelope([]));
        if (request.path.endsWith('/decision')) {
          decisions.add(Map<String, dynamic>.from(request.data as Map));
          return (
            200,
            envelope({
              ...requested,
              'version': 2,
              'status': 'awaiting_device',
              'deviceId': 'test-device-123456',
              'title': '服务端批准标题',
            }),
          );
        }
        if (request.path.endsWith('/receipt')) {
          receipts.add(Map<String, dynamic>.from(request.data as Map));
          receiptAttempts++;
          if (receiptAttempts == 1) {
            return (503, envelope(null, status: 503, message: 'temporary'));
          }
          return (200, envelope({'status': 'completed'}));
        }
        throw StateError('unexpected request ${request.path}');
      });
    final api = ApiClient(baseUrl: 'https://test.example/', dio: dio)
      ..accountId = (() => 'owner')
      ..accessToken = (() async => 'token');
    final notifications = NotificationModel();
    final actions = AccountActions(api, notifications, executor: executor);
    addTearDown(actions.dispose);
    addTearDown(notifications.dispose);
    addTearDown(() => dio.close(force: true));
    actions.refreshAccount();
    await waitForNotice(notifications, 'action:reschedule-1');

    expect(
      notifications.items
          .singleWhere((item) => item.id == 'action:reschedule-1')
          .title,
      '改期日程：客户端旧标题',
    );
    expect(
      await notifications.decide('action:reschedule-1', allow: true),
      isFalse,
    );
    expect(
      await notifications.decide('action:reschedule-1', allow: true),
      isTrue,
    );
    expect(decisions, hasLength(2));
    expect(decisions[0]['version'], 1);
    expect(decisions[0]['mutationId'], startsWith('decision-allow-'));
    expect(decisions[1]['mutationId'], decisions[0]['mutationId']);
    expect(executor.commands, hasLength(2));
    expect(executor.commands.first['title'], '服务端批准标题');
    expect(executor.commands.first['version'], 2);
    expect(receipts, hasLength(2));
    expect(receipts.first['version'], 2);
    expect(receipts.first['mutationId'], startsWith('receipt-'));
    expect(receipts.last['mutationId'], receipts.first['mutationId']);
  });

  test('旧 action 缺少 version 时仍可审批，allow 与 decline mutationId 不同', () async {
    final executor = CapturingCalendarExecutor();
    final decisions = <Map<String, dynamic>>[];
    final actionsData = [
      {
        'id': 'legacy-allow',
        'status': 'pending',
        'fingerprint': 'legacy-a',
        'title': '旧创建',
        'start': '2030-01-01T09:00:00Z',
        'end': '2030-01-01T10:00:00Z',
      },
      {
        'id': 'legacy-decline',
        'status': 'pending',
        'fingerprint': 'legacy-b',
        'title': '旧拒绝',
        'start': '2030-01-02T09:00:00Z',
        'end': '2030-01-02T10:00:00Z',
      },
    ];
    final dio = Dio()
      ..httpClientAdapter = TestAdapter((request) async {
        if (request.path == 'actions?includeToolPlans=true') {
          return (200, envelope(actionsData));
        }
        if (request.path == 'tasks') return (200, envelope([]));
        if (request.path.endsWith('/decision')) {
          final payload = Map<String, dynamic>.from(request.data as Map);
          decisions.add(payload);
          return (
            200,
            envelope({
              'status': payload['allow'] == true
                  ? 'awaiting_device'
                  : 'declined',
            }),
          );
        }
        if (request.path.endsWith('/receipt')) {
          expect((request.data as Map).containsKey('version'), isFalse);
          return (200, envelope({'status': 'completed'}));
        }
        throw StateError('unexpected request ${request.path}');
      });
    final api = ApiClient(baseUrl: 'https://test.example/', dio: dio)
      ..accountId = (() => 'owner');
    final notifications = NotificationModel();
    final actions = AccountActions(api, notifications, executor: executor);
    addTearDown(actions.dispose);
    addTearDown(notifications.dispose);
    addTearDown(() => dio.close(force: true));
    actions.refreshAccount();
    await waitForNotice(notifications, 'action:legacy-decline');

    expect(
      await notifications.decide('action:legacy-allow', allow: true),
      isTrue,
    );
    expect(
      await notifications.decide('action:legacy-decline', allow: false),
      isTrue,
    );
    expect(decisions, hasLength(2));
    expect(
      decisions.every((payload) => !payload.containsKey('version')),
      isTrue,
    );
    expect(decisions[0]['mutationId'], startsWith('decision-allow-'));
    expect(decisions[1]['mutationId'], startsWith('decision-decline-'));
    expect(decisions[0]['mutationId'], isNot(decisions[1]['mutationId']));
  });

  test('创建、改期、取消通知使用准确标题和设备说明', () async {
    final data = [
      for (final operation in ['create', 'reschedule', 'cancel'])
        {
          'id': operation,
          'operation': operation,
          'status': 'pending',
          'fingerprint': operation,
          'title': '项目会',
          'start': '2030-01-01T09:00:00Z',
          'end': '2030-01-01T10:00:00Z',
        },
    ];
    final dio = Dio()
      ..httpClientAdapter = TestAdapter(
        (request) async => request.path == 'tasks'
            ? (200, envelope([]))
            : (200, envelope(data)),
      );
    final api = ApiClient(baseUrl: 'https://test.example/', dio: dio)
      ..accountId = (() => 'owner');
    final notifications = NotificationModel();
    final actions = AccountActions(
      api,
      notifications,
      executor: CapturingCalendarExecutor(),
    );
    addTearDown(actions.dispose);
    addTearDown(notifications.dispose);
    addTearDown(() => dio.close(force: true));
    actions.refreshAccount();
    await waitForNotice(notifications, 'action:cancel');
    final byId = {for (final item in notifications.items) item.id: item};
    expect(byId['action:create']!.title, '创建日程：项目会');
    expect(byId['action:create']!.instruction, contains('创建日历项'));
    expect(byId['action:reschedule']!.title, '改期日程：项目会');
    expect(byId['action:reschedule']!.instruction, contains('更新原日历项'));
    expect(byId['action:cancel']!.title, '取消日程：项目会');
    expect(byId['action:cancel']!.instruction, contains('删除原日历项'));
  });
}
