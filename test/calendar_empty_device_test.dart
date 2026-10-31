import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:yanshu/features/notifications/device_calendar_executor.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final description in [
    "original",
    "appended",
    "truncated",
    "wrong-title",
  ]) {
    for (final compat in [false, true]) {
      test('无系统日历及厂商URI兼容=$compat 描述=$description：批准后建立日历、回读、重试不重复', () async {
        FlutterSecureStorage.setMockInitialValues({});
        const channel = MethodChannel(
          'plugins.builttoroam.com/device_calendar',
        );
        var createdCalendars = 0, createdEvents = 0;
        Map<String, dynamic>? event;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              switch (call.method) {
                case 'requestPermissions':
                  return true;
                case 'retrieveCalendars':
                  return jsonEncode(
                    createdCalendars == 0
                        ? []
                        : [
                            {
                              'id': 'local',
                              'name': '言枢',
                              'isReadOnly': false,
                              'isDefault': true,
                            },
                          ],
                  );
                case 'createCalendar':
                  createdCalendars++;
                  return 'local';
                case 'retrieveEvents':
                  if (compat) {
                    throw PlatformException(
                      code: '404',
                      message: "Couldn't retrieve the Calendar with ID local",
                    );
                  }
                  return jsonEncode(event == null ? [] : [event]);
                case 'createOrUpdateEvent':
                  if (compat) {
                    throw PlatformException(
                      code: '404',
                      message: "Couldn't retrieve the Calendar with ID local",
                    );
                  }
                  createdEvents++;
                  event = {
                    ...Map<String, dynamic>.from(call.arguments as Map),
                    'eventId': 'test-event',
                  };
                  if (description == 'appended') {
                    event!['eventDescription'] =
                        '${event!['eventDescription']}\n系统日历同步';
                  }
                  if (description == 'truncated') {
                    event!['eventDescription'] = 'ROM 截断了备注';
                  }
                  if (description == 'wrong-title') {
                    event!['eventTitle'] = '被修改的标题';
                  }
                  return 'test-event';
              }
              throw StateError('Unexpected calendar call: ${call.method}');
            });
        const native = MethodChannel('yanshu/calendar_compat');
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(native, (call) async {
              final args = Map<String, dynamic>.from(call.arguments as Map);
              if (call.method == 'read') return event == null ? [] : [event];
              if (call.method == 'create') {
                createdEvents++;
                event = {
                  'calendarId': args['calendarId'],
                  'eventId': 'test-event',
                  'eventTitle': args['title'],
                  'eventDescription': args['marker'],
                  'eventStartDate': args['start'],
                  'eventEndDate': args['end'],
                  'eventStartTimeZone': 'UTC',
                  'eventEndTimeZone': 'UTC',
                };
                if (description == 'appended') {
                  event!['eventDescription'] =
                      '${event!['eventDescription']}\n系统日历同步';
                }
                if (description == 'truncated') {
                  event!['eventDescription'] = 'ROM 截断了备注';
                }
                if (description == 'wrong-title') {
                  event!['eventTitle'] = '被修改的标题';
                }
                return 'test-event';
              }
              throw StateError('Unexpected native calendar method');
            });
        addTearDown(
          () => TestDefaultBinaryMessengerBinding
              .instance
              .defaultBinaryMessenger
              .setMockMethodCallHandler(native, null),
        );
        addTearDown(
          () => TestDefaultBinaryMessengerBinding
              .instance
              .defaultBinaryMessenger
              .setMockMethodCallHandler(channel, null),
        );
        final executor = DeviceCalendarExecutor();
        final action = {
          'id': 'approved-calendar',
          'fingerprint': 'approved-hash',
          'title': '联调测试',
          'start': '2030-11-10T14:00:00+08:00',
          'end': '2030-11-10T14:30:00+08:00',
        };
        if (description == 'wrong-title') {
          for (var i = 0; i < 2; i++) {
            await expectLater(
              executor.execute('test-owner', action, isCurrent: () => true),
              throwsA(isA<CalendarExecutionFailure>()),
            );
          }
          expect(createdEvents, 1);
          return;
        }
        final first = await executor.execute(
          'test-owner',
          action,
          isCurrent: () => true,
        );
        expect(first['verified'], isTrue);
        expect(first['calendarId'], 'local');
        expect(first['previousEventId'], isNull);
        expect(first['deleted'], isFalse);
        expect(
          (await executor.execute(
            'test-owner',
            action,
            isCurrent: () => true,
          ))['eventId'],
          first['eventId'],
        );
        expect(createdCalendars, 1);
        expect(createdEvents, 1);
      });
    }
  }
}
