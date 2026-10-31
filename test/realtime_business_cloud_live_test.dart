import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:yanshu/core/network/api_config.dart';
import 'package:yanshu/features/auth/repositories/dio_auth_repository.dart';
import 'package:yanshu/features/home/repositories/dio_home_repository.dart';
import 'package:yanshu/features/home/viewmodels/home_view_model.dart';
import 'package:yanshu/features/knowledge/repositories/knowledge_repository.dart';
import 'package:yanshu/features/knowledge/viewmodels/knowledge_view_model.dart';
import 'package:yanshu/features/meeting/meeting_models.dart';
import 'package:yanshu/features/meeting/meeting_remote.dart';
import 'package:yanshu/features/meeting/meeting_store.dart';
import 'package:yanshu/features/meeting/meeting_view_model.dart';
import 'package:yanshu/features/notifications/account_actions.dart';
import 'package:yanshu/features/notifications/notification_model.dart';
import 'package:yanshu/features/progress/repositories/dio_progress_repository.dart';
import 'package:yanshu/features/progress/viewmodels/progress_view_model.dart';
import 'dio_auth_repository_test.dart' show MemorySessionStore;
import 'meeting_backend_live_test.dart' show liveApi;
import 'meeting_test.dart' show FakeMeetingRecorder, FakeMeetingCalendar;
import 'controlled_actions_test.dart' show NoCalendar;

class ObservedCloudMeeting extends DioMeetingRepository {
  ObservedCloudMeeting(super.client);
  final timer = Stopwatch();
  final events = <Map<String, dynamic>>[];
  final finished = Completer<void>();
  bool businessDone = false;
  bool hintsDone = false;
  final liveEvents = <Map<String, dynamic>>[];
  @override
  Future<void> liveHints(
    MeetingRecord record,
    void Function(Map<String, dynamic>) onUpdate,
  ) async {
    await super.liveHints(record, (event) {
      if (event['event'] == 'done') hintsDone = true;
      liveEvents.add({
        'seconds': timer.elapsedMilliseconds / 1000,
        'event': event['event'],
        'body': (event['insights'] as List? ?? [])
            .map((i) => i['body'])
            .join('\n'),
      });
      onUpdate(event);
    });
  }

  @override
  Future<void> updateBusiness(
    MeetingRecord record,
    void Function(Map<String, dynamic>) onUpdate,
  ) async {
    try {
      await super.updateBusiness(record, (event) {
        events.add({
          'seconds': timer.elapsedMilliseconds / 1000,
          'event': event['event'],
          'extracting': event['extracting'],
          'published': event['published'],
        });
        if (event['event'] == 'done') businessDone = true;
        onUpdate(event);
      });
      if (!finished.isCompleted) finished.complete();
    } catch (error, stack) {
      if (!finished.isCompleted) finished.completeError(error, stack);
      rethrow;
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'Flutter真实ViewModel自动上传→云端SSE→首页/进展/通知提前刷新，不暂停',
    () async {
      expect(ApiConfig.current.environment, AppEnvironment.cloud);
      final api = liveApi();
      final auth = DioAuthRepository(api, MemorySessionStore());
      final remote = ObservedCloudMeeting(api);
      final home = HomeViewModel(repository: DioHomeRepository(api));
      final progress = ProgressViewModel(DioProgressRepository(api));
      final notices = NotificationModel()..bind(progress);
      final actions = AccountActions(api, notices, executor: NoCalendar());
      final recorder = FakeMeetingRecorder();
      final knowledge = KnowledgeViewModel(
        KnowledgeRepository(MemoryKnowledgeStore(), seedExamples: false),
      );
      await knowledge.load();
      final readings = <String, dynamic>{};
      final checks = <String, bool>{};
      void observe(String key, bool available) {
        if (available && !readings.containsKey(key)) {
          readings[key] = {
            'seconds': remote.timer.elapsedMilliseconds / 1000,
            'beforeBusinessDone': !remote.businessDone,
          };
        }
      }

      home.addListener(
        () => observe('home', (home.data['rows'] as List? ?? []).isNotEmpty),
      );
      progress.addListener(() {
        observe('goal', progress.data.goals.isNotEmpty);
        observe(
          'counterparty',
          progress.data.commitments.any((c) => c.side.name == 'theirs'),
        );
      });
      notices.addListener(
        () => observe(
          'notification',
          notices.items.any(
            (n) => n.title.contains('评估报告') && n.state == NoticeState.pending,
          ),
        ),
      );
      final vm = MeetingViewModel(
        store: MemoryMeetingStore(),
        recorder: recorder,
        calendar: FakeMeetingCalendar(),
        knowledge: knowledge,
        notifications: notices,
        home: home,
        remote: remote,
        onProgressChanged: () async {
          await Future.wait([
            progress.load(silent: true),
            home.refresh(),
            actions.refresh(),
          ]);
        },
      );
      vm.addListener(() {
        if (!readings.containsKey('liveText') &&
            vm.record?.insights.any((i) => i.streaming && i.body.isNotEmpty) ==
                true) {
          readings['liveText'] = {
            'seconds': remote.timer.elapsedMilliseconds / 1000,
            'beforeHintsDone': !remote.hintsDone,
            'skeletonVisible': vm.liveHintsLoading,
          };
        }
      });
      var registered = false;
      const password = 'Synthetic-Flutter-Cloud-2026!';
      try {
        await auth.register(
          '云端联调',
          'speed-${DateTime.now().microsecondsSinceEpoch}@example.com',
          password,
        );
        registered = true;
        actions.refreshAccount();
        await vm.start(demo: false);
        remote.timer.start();
        await vm.addManual(
          '发言人 A',
          '本期交付目标是完成Android和iOS双端测试，验收要求是双方确认的功能清单全部通过，交期2030年10月30日。',
        );
        await vm.addManual('发言人 B', '对方承诺周五提供测试账号。');
        await vm.addManual('发言人 A', '请创建任务提交评估报告。');
        // 仅替代声源输入，业务、Dio、Hermes、数据库和刷新回调均使用真实实现。
        vm.record = vm.record!.copy(
          utterances: [
            for (final u in vm.record!.utterances)
              MeetingUtterance.fromJson({
                ...u.toJson(),
                'speakerId': u.speaker == '发言人 B' ? 'fixture-b' : 'fixture-a',
                'speakerSeparated': true,
              }),
          ],
        );
        await remote.finished.future.timeout(const Duration(seconds: 90));
        final deadline = DateTime.now().add(const Duration(seconds: 15));
        while (readings.length < 4 && DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }
        expect(vm.record!.demo, isFalse);
        expect(progress.error, isNull);
        expect(home.error, isNull);
        expect(progress.data.goals, isNotEmpty);
        expect(
          progress.data.commitments.any((c) => c.side.name == 'theirs'),
          isTrue,
        );
        expect(
          readings.keys,
          containsAll(['home', 'goal', 'counterparty', 'notification']),
        );
        expect((readings['home'] as Map)['beforeBusinessDone'], isTrue);
        expect((readings['goal'] as Map)['beforeBusinessDone'], isTrue);
        expect(recorder.pauses, 0);
        expect(readings['liveText'], isNotNull);
        expect((readings['liveText'] as Map)['beforeHintsDone'], isTrue);
        expect((readings['liveText'] as Map)['skeletonVisible'], isFalse);
        final bodies = remote.liveEvents
            .where((e) => e['event'] == 'preview')
            .map((e) => e['body'] as String)
            .where((b) => b.isNotEmpty)
            .toSet();
        expect(bodies.length, greaterThan(1));
        checks['realLiveTextPrefixesRenderedBeforeDone'] = true;
        expect((await api.get('tasks', authenticated: true))['data'], isEmpty);
        checks.addAll({
          'realFlutterDioAndViewModels': true,
          'automaticUploadWithoutPause': true,
          'homeAndGoalBeforeBusinessCompleted': true,
          'counterpartyAndNotificationVisible': true,
          'nothingExecutedWithoutApproval': true,
        });
      } finally {
        vm.dispose();
        actions.dispose();
        notices.dispose();
        progress.dispose();
        home.dispose();
        knowledge.dispose();
        if (registered) {
          await auth.deleteAccount(password);
          checks['temporaryAccountDeleted'] = true;
        }
        await File(
          'docs/realtime_flutter_cloud_verification_20261021.json',
        ).writeAsString(
          const JsonEncoder.withIndent('  ').convert({
            'syntheticOnly': true,
            'realMicrophone': false,
            'deviceCalendarTested': false,
            'backend': ApiConfig.baseUrl,
            'readings': readings,
            'streamEvents': remote.events,
            'liveModelEvents': remote.liveEvents,
            'checks': checks,
          }),
        );
      }
    },
    skip: !const bool.fromEnvironment('RUN_REALTIME_CLOUD'),
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
