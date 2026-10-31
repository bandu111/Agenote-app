import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:device_calendar/device_calendar.dart';
import 'package:yanshu/core/network/api_client.dart';
import 'package:yanshu/features/auth/repositories/dio_auth_repository.dart';
import 'package:yanshu/features/home/viewmodels/home_view_model.dart';
import 'package:yanshu/features/knowledge/repositories/knowledge_repository.dart';
import 'package:yanshu/features/knowledge/viewmodels/knowledge_view_model.dart';
import 'package:yanshu/features/meeting/meeting_store.dart';
import 'package:yanshu/features/meeting/meeting_view_model.dart';
import 'package:yanshu/features/notifications/account_actions.dart';
import 'package:yanshu/features/notifications/device_calendar_executor.dart';
import 'package:yanshu/features/notifications/notification_model.dart';
import '../test/dio_auth_repository_test.dart' show MemorySessionStore;
import '../test/meeting_test.dart'
    show FakeMeetingRecorder, FakeMeetingCalendar;
import '../test/realtime_business_cloud_live_test.dart'
    show ObservedCloudMeeting;

class ObservedDeviceCalendar extends DeviceCalendarExecutor {
  final receipts = <Map<String, dynamic>>[];
  final createdCalendarIds = <String>{};
  @override
  Future<Map<String, dynamic>> execute(
    String owner,
    Map<String, dynamic> action, {
    required bool Function() isCurrent,
  }) async {
    final permission = await plugin.requestPermissions();
    if (permission.data != true) {
      throw const CalendarExecutionFailure('测试需要系统日历权限');
    }
    final before = await plugin.retrieveCalendars();
    if (!before.isSuccess) throw const CalendarExecutionFailure('测试前日历清单读取失败');
    final ids = before.data?.map((c) => c.id).toSet() ?? <String?>{};
    final receipt = await super.execute(owner, action, isCurrent: isCurrent);
    receipts.add({...receipt, '_owner': owner, '_action': action['id']});
    final after = await plugin.retrieveCalendars();
    for (final c in after.data ?? <Calendar>[]) {
      if (c.id != null && !ids.contains(c.id)) {
        createdCalendarIds.add(c.id!);
      }
    }
    return receipt;
  }

  Future<void> cleanup() async {
    final calendars = await plugin.retrieveCalendars();
    for (final calendar in calendars.data ?? <Calendar>[]) {
      for (final receipt in receipts) {
        final marker =
            '[yanshu:${receipt['_owner']}:${receipt['_action']}:${receipt['fingerprint']}]';
        // 测试包专用删除入口只按本次标记删除，不读取或修改用户的其他日程。
        await const MethodChannel('yanshu/calendar_compat').invokeMethod<int>(
          'deleteTestEvent',
          {'calendarId': calendar.id, 'marker': marker},
        );
        final found = await plugin.retrieveEvents(
          calendar.id!,
          RetrieveEventsParams(eventIds: [receipt['eventId'] as String]),
        );
        for (final event in found.data ?? <Event>[]) {
          if (event.description == marker) {
            await plugin.deleteEvent(calendar.id!, event.eventId);
          }
        }
      }
    }
    for (final id in createdCalendarIds) {
      await const MethodChannel('yanshu/calendar_compat').invokeMethod<int>(
        'deleteEmptyTestCalendar',
        {'calendarId': id, 'marker': '[yanshu:test-cleanup:empty]'},
      );
    }
    receipts.clear();
    createdCalendarIds.clear();
  }
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('真机云端：连续会议通知、批准任务、原生日历写入回读与清理', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: Center(child: Text('言枢会议链路自动验证中，无需朗读'))),
      ),
    );
    final api = ApiClient(baseUrl: 'https://124.220.169.122/api/v1/');
    final auth = DioAuthRepository(api, MemorySessionStore());
    final remote = ObservedCloudMeeting(api);
    // 观察器的完成 Future 也要消费错误；生产 ViewModel 会负责断线恢复。
    remote.finished.future.ignore();
    final knowledge = KnowledgeViewModel(
      KnowledgeRepository(MemoryKnowledgeStore(), seedExamples: false),
    );
    await knowledge.load();
    final notices = NotificationModel();
    final executor = ObservedDeviceCalendar();
    final actions = AccountActions(api, notices, executor: executor);
    final home = HomeViewModel();
    final vm = MeetingViewModel(
      store: MemoryMeetingStore(),
      recorder: FakeMeetingRecorder(),
      calendar: FakeMeetingCalendar(),
      knowledge: knowledge,
      notifications: notices,
      home: home,
      remote: remote,
      onProgressChanged: actions.refresh,
    );
    final report = <String, dynamic>{
      'realDevice': true,
      'realCloudModels': true,
      'realNativeCalendar': true,
      'realMicrophone': false,
      'syntheticSpeech': true,
    };
    const password = 'Synthetic-Device-QA-2026!';
    var registered = false;
    Future<void> until(bool Function() condition, {int seconds = 100}) async {
      final end = DateTime.now().add(Duration(seconds: seconds));
      while (!condition() && DateTime.now().isBefore(end)) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
        await tester.pump();
      }
      expect(condition(), isTrue, reason: '等待真机云端状态超时');
    }

    try {
      await auth.register(
        '真机行动联调',
        'device-action-${DateTime.now().microsecondsSinceEpoch}@example.com',
        password,
      );
      registered = true;
      actions.refreshAccount();
      await vm.start(demo: false);
      remote.timer.start();
      await vm.addManual('发言人 A', '现在确认，二〇三〇年十一月十日下午两点到两点半召开项目进度会。');
      await vm.addManual('发言人 A', '请创建任务提交评估报告。');
      await until(
        () => notices.items.any(
          (n) => n.state == NoticeState.pending && n.title.contains('评估报告'),
        ),
      );
      report['taskNoticeSeconds'] = remote.timer.elapsedMilliseconds / 1000;
      final task = notices.items.firstWhere(
        (n) => n.state == NoticeState.pending && n.title.contains('评估报告'),
      );
      // 通知出现后继续发言，再批准旧通知，复现此前的版本失效问题。
      await vm.addManual('发言人 B', '接下来讨论测试环境，账号稍后再说。');
      await Future<void>.delayed(const Duration(seconds: 1));
      expect(
        await notices.decide(task.id, allow: true),
        isTrue,
        reason: notices.error(task.id),
      );
      final tasks = await api.get('tasks', authenticated: true);
      expect(
        (tasks['data'] as List).any(
          (t) => t['title'].toString().contains('评估报告'),
        ),
        isTrue,
      );
      report['taskApprovedAfterNextSpeech'] = true;
      await until(
        () => notices.items.any(
          (n) => n.state == NoticeState.pending && n.title.startsWith('创建日程'),
        ),
      );
      report['calendarNoticeSeconds'] = remote.timer.elapsedMilliseconds / 1000;
      final calendar = notices.items.firstWhere(
        (n) => n.state == NoticeState.pending && n.title.startsWith('创建日程'),
      );
      expect(
        await notices.decide(calendar.id, allow: true),
        isTrue,
        reason: notices.error(calendar.id),
      );
      expect(executor.receipts.single['verified'], isTrue);
      report['nativeCalendarCreatedAndReadBack'] = true;
      await vm.addManual('发言人 A', '验收标准我们就按，先插一句明天提供账号。');
      await vm.addManual('发言人 B', '预算保持十万元。');
      await vm.addManual('发言人 A', '接着刚才的验收标准，我们按双方确认的功能清单验收。');
      await until(
        () => vm.record!.insights.any((i) => i.kind.name == 'stitch'),
      );
      report['mergedShortSpeechLinkedWithoutFakeSpeakerSplit'] = true;
      await vm.addManual('发言人 A', '现在确认，撤回之前提交评估报告的任务，这个任务不再需要。');
      await until(
        () => notices.items.any(
          (n) => n.state == NoticeState.pending && n.title.startsWith('撤回'),
        ),
        seconds: 150,
      );
      final cancel = notices.items.firstWhere(
        (n) => n.state == NoticeState.pending && n.title.startsWith('撤回'),
      );
      expect(
        await notices.decide(cancel.id, allow: true),
        isTrue,
        reason: notices.error(cancel.id),
      );
      final afterCancel = await api.get('tasks', authenticated: true);
      expect(
        (afterCancel['data'] as List).any((t) => t['status'] == 'cancelled'),
        isTrue,
      );
      report['withdrawalConfirmedAndPersisted'] = true;
      report['actionEvents'] = remote.events;
      expect(vm.phase.name, 'recording');
      report['recordingNeverPaused'] = true;
      await executor.cleanup();
      report['testCalendarCleaned'] = true;
    } finally {
      try {
        await executor.cleanup();
      } catch (_) {
        report['cleanupFailed'] = true;
      }
      vm.dispose();
      actions.dispose();
      notices.dispose();
      knowledge.dispose();
      home.dispose();
      if (registered) {
        await auth.deleteAccount(password);
        report['temporaryAccountDeleted'] = true;
      }
      api.dio.close(force: true);
      binding.reportData = report;
      debugPrint('MEETING_DEVICE_REPORT $report');
    }
  }, timeout: const Timeout(Duration(minutes: 5)));
}
