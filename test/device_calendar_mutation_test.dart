import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yanshu/features/notifications/device_calendar_executor.dart';

Map<String, dynamic> nativeEvent({
  String title = '原项目会',
  String start = '2030-11-10T06:00:00Z',
  String end = '2030-11-10T06:30:00Z',
}) => {
  'calendarId': 'calendar-1',
  'eventId': 'event-1',
  'eventTitle': title,
  'eventDescription': '[yanshu:owner:create:old]',
  'eventStartDate': DateTime.parse(start).millisecondsSinceEpoch,
  'eventEndDate': DateTime.parse(end).millisecondsSinceEpoch,
  'eventStartTimeZone': 'UTC',
  'eventEndTimeZone': 'UTC',
};

Map<String, dynamic> mutation(
  String operation, {
  String title = '改期后的项目会',
  String start = '2030-11-10T07:00:00Z',
  String end = '2030-11-10T07:30:00Z',
}) => {
  'id': '$operation-action',
  'operation': operation,
  'fingerprint': '$operation-fingerprint',
  'title': title,
  'start': start,
  'end': end,
  'deviceId': 'test-device-123456',
  'target': {
    'eventId': 'event-1',
    'calendarId': 'calendar-1',
    'deviceId': 'test-device-123456',
  },
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.builttoroam.com/device_calendar');

  test('reschedule 只更新 target eventId，回读一致且重试不新增', () async {
    FlutterSecureStorage.setMockInitialValues({});
    Map<String, dynamic>? event = nativeEvent();
    var updates = 0, creates = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          switch (call.method) {
            case 'requestPermissions':
              return true;
            case 'retrieveCalendars':
              return jsonEncode([
                {
                  'id': 'calendar-1',
                  'name': '主日历',
                  'isReadOnly': false,
                  'isDefault': true,
                },
              ]);
            case 'retrieveEvents':
              return jsonEncode(event == null ? [] : [event]);
            case 'createOrUpdateEvent':
              final args = Map<String, dynamic>.from(call.arguments as Map);
              if (args['eventId'] == null) {
                creates++;
                return 'unexpected-created-event';
              }
              expect(args['eventId'], 'event-1');
              updates++;
              event = {...args, 'eventId': 'event-1'};
              return 'event-1';
          }
          throw StateError('unexpected calendar call ${call.method}');
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    final executor = DeviceCalendarExecutor();
    final command = mutation('reschedule');
    final receipt = await executor.execute(
      'owner',
      command,
      isCurrent: () => true,
    );
    expect(receipt['eventId'], 'event-1');
    expect(receipt['previousEventId'], 'event-1');
    expect(receipt['calendarId'], 'calendar-1');
    expect(receipt['deleted'], isFalse);
    expect(updates, 1);
    expect(creates, 0);
    final repeated = await executor.execute(
      'owner',
      command,
      isCurrent: () => true,
    );
    expect(repeated['eventId'], 'event-1');
    expect(updates, 1);
    expect(creates, 0);
  });

  test('cancel 只删除 target eventId，确认不存在后返回 tombstone 且重试不重复删除', () async {
    FlutterSecureStorage.setMockInitialValues({});
    Map<String, dynamic>? event = nativeEvent();
    var deletes = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          switch (call.method) {
            case 'requestPermissions':
              return true;
            case 'retrieveCalendars':
              return jsonEncode([
                {
                  'id': 'calendar-1',
                  'name': '主日历',
                  'isReadOnly': false,
                  'isDefault': true,
                },
              ]);
            case 'retrieveEvents':
              return jsonEncode(event == null ? [] : [event]);
            case 'deleteEvent':
              deletes++;
              event = null;
              return true;
          }
          throw StateError('unexpected calendar call ${call.method}');
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    final executor = DeviceCalendarExecutor();
    final command = mutation(
      'cancel',
      title: '原项目会',
      start: '2030-11-10T06:00:00Z',
      end: '2030-11-10T06:30:00Z',
    );
    final receipt = await executor.execute(
      'owner',
      command,
      isCurrent: () => true,
    );
    expect(receipt, containsPair('eventId', 'event-1'));
    expect(receipt, containsPair('previousEventId', 'event-1'));
    expect(receipt, containsPair('calendarId', 'calendar-1'));
    expect(receipt, containsPair('deleted', true));
    expect(receipt['title'], command['title']);
    expect(receipt['start'], command['start']);
    expect(receipt['end'], command['end']);
    expect(receipt['fingerprint'], command['fingerprint']);
    expect(deletes, 1);
    final repeated = await executor.execute(
      'owner',
      command,
      isCurrent: () => true,
    );
    expect(repeated['deleted'], isTrue);
    expect(deletes, 1);
  });

  test('update 或 delete 未通过原生结果与回读时安全失败，不伪装成功或创建新项', () async {
    for (final operation in ['reschedule', 'cancel']) {
      FlutterSecureStorage.setMockInitialValues({});
      final event = nativeEvent();
      var creates = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            switch (call.method) {
              case 'requestPermissions':
                return true;
              case 'retrieveCalendars':
                return jsonEncode([
                  {
                    'id': 'calendar-1',
                    'name': '主日历',
                    'isReadOnly': false,
                    'isDefault': true,
                  },
                ]);
              case 'retrieveEvents':
                return jsonEncode([event]);
              case 'createOrUpdateEvent':
                final args = Map<String, dynamic>.from(call.arguments as Map);
                if (args['eventId'] == null) creates++;
                return null;
              case 'deleteEvent':
                return false;
            }
            throw StateError('unexpected calendar call ${call.method}');
          });
      final command = operation == 'cancel'
          ? mutation(
              operation,
              title: '原项目会',
              start: '2030-11-10T06:00:00Z',
              end: '2030-11-10T06:30:00Z',
            )
          : mutation(operation);
      await expectLater(
        DeviceCalendarExecutor().execute(
          'owner',
          command,
          isCurrent: () => true,
        ),
        throwsA(isA<CalendarExecutionFailure>()),
      );
      expect(creates, 0);
      expect(event, isNotNull);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    }
  });
}
