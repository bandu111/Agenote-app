import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:device_calendar/device_calendar.dart' show RetrieveEventsParams;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:yanshu/app/app.dart';
import 'package:yanshu/core/network/api_client.dart';
import 'package:yanshu/core/network/api_config.dart';
import 'package:yanshu/features/auth/repositories/dio_auth_repository.dart';
import 'package:yanshu/features/auth/services/session_store.dart';
import 'package:yanshu/features/knowledge/models/knowledge_models.dart';
import 'package:yanshu/features/knowledge/repositories/dio_knowledge_repository.dart';
import 'package:yanshu/features/knowledge/viewmodels/knowledge_view_model.dart';
import 'package:yanshu/features/meeting/meeting_models.dart';
import 'package:yanshu/features/meeting/meeting_remote.dart';
import 'package:yanshu/features/meeting/meeting_services.dart';
import 'package:yanshu/features/meeting/meeting_store.dart';
import 'package:yanshu/features/notifications/device_calendar_executor.dart';
import 'package:yanshu/features/profile/models/profile_data.dart';
import 'package:yanshu/features/profile/repositories/profile_repository.dart';
import 'package:yanshu/features/progress/repositories/dio_progress_repository.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('真机：录音及会议→进展→知识库→跨会议引用→日历回读', (tester) async {
    // 先绘制测试宿主首帧，避免 Driver 在后续网络等待期间阻塞平台消息。
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: Center(child: CircularProgressIndicator())),
      ),
    );
    final api = ApiClient(baseUrl: ApiConfig.baseUrl);
    api.dio.interceptors.add(
      InterceptorsWrapper(
        onError: (error, handler) {
          debugPrint(
            'CHAIN_NETWORK ${error.type.name} status=${error.response?.statusCode} cause=${error.error.runtimeType} message=${error.message}',
          );
          handler.next(error);
        },
      ),
    );
    final store = SecureSessionStore(
      '${ApiConfig.baseUrl}#knowledge-chain-test',
    );
    await store.clear();
    final auth = DioAuthRepository(api, store);
    final checks = <String, bool>{};
    final result = <String, dynamic>{
      'synthetic_only': true,
      'platform': Platform.operatingSystem,
      'transcript_input': 'controlled_text_fixtures_not_microphone_ASR',
      'asr_accuracy_measured': false,
      'real_backend': true,
      'real_hermes_deepseek': true,
      'checks': checks,
    };
    final directory = await getApplicationSupportDirectory();
    final file = File('${directory.path}/knowledge_chain_device_result.json');
    Future<void> save() async {
      await file.writeAsString(jsonEncode(result));
      binding.reportData = result;
    }

    final recorder = DeviceMeetingRecorder();
    String? audio;
    DeviceCalendarExecutor? calendarFixture;
    String? temporaryCalendarId;
    KnowledgeViewModel? knowledge;
    try {
      final email =
          'auto-meeting-chain-${DateTime.now().microsecondsSinceEpoch}@example.com';
      final user = await auth.register(
        '自动化会议',
        email,
        'Only-Synthetic-Chain-Test-2026!',
      );
      result['accounts_for_cleanup'] = [
        {'id': user.id, 'email': email},
      ];
      await save();
      // 原生麦克风只检验采集/暂停/恢复/文件，不上传或记录周围谈话的文字。
      audio = await recorder.start('synthetic-device-check');
      await Future<void>.delayed(const Duration(seconds: 2));
      await recorder.pause();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await recorder.resume();
      await Future<void>.delayed(const Duration(seconds: 1));
      await recorder.stop();
      final bytes = await File(audio).readAsBytes();
      checks['native_microphone_pause_resume_wav'] =
          bytes.length > 44 && ascii.decode(bytes.take(4).toList()) == 'RIFF';
      expect(checks['native_microphone_pause_resume_wav'], isTrue);
      await File(audio).delete();
      audio = null;
      await save();

      final repo = DioKnowledgeRepository(api);
      knowledge = KnowledgeViewModel(repo, accountId: () => user.id);
      await knowledge.load();
      expect(knowledge.error, isNull);
      final id = await knowledge.addDocument(
        title: '星澜一期范围合同（合成测试）',
        content: '星澜项目一期合同仅约定Android和iOS双端交付。Windows是额外范围，必须单独评估和批准，不包含在原合同中。',
        folderId: 'inbox',
        projectId: 'personal',
        kind: KnowledgeKind.markdown,
        allowed: true,
      );
      expect(id, isNotNull, reason: knowledge.actionError);

      const statements = [
        '交付目标是完成 Android 与 iOS 双端测试并部署至预发环境。交期2030年11月5日。验收要求是通过双方确认的测试清单。',
        '我方负责2030年10月28日提交双端测试报告。',
        'Windows需求先评估，尚未同意加入交付范围。',
        '验收清单我们周……',
        '先说部署预算。',
        '接回验收清单，验收清单我们周三确认。',
        '可以考虑改为2030年10月30日提交，但还没确定。',
        '请不要改成 Windows。',
        '我们已经确认2030年10月23日14:00到15:00召开星澜进度会议。',
      ];
      result['input_statements'] = statements;
      MeetingRecord fixture(String key, List<String> words) => MeetingRecord(
        id: key,
        title: '星澜测试会议',
        startedAt: DateTime.parse('2026-10-19T10:00:00+08:00'),
        demo: false,
        ownerId: user.id,
        syncRevision: 1,
        elapsed: Duration(seconds: words.length * 10),
        utterances: [
          for (var i = 0; i < words.length; i++)
            MeetingUtterance(
              id: 'u$i',
              speaker: i == 4 ? '发言人 B' : '发言人 A',
              speakerId: i == 4 ? 'fixture-b' : 'fixture-a',
              speakerSeparated: true,
              raw: words[i],
              at: Duration(seconds: i * 10),
            ),
        ],
      );
      final meeting = DioMeetingRepository(
        api,
        pollInterval: const Duration(seconds: 1),
      );
      var first = fixture(
        'chain-${DateTime.now().microsecondsSinceEpoch}',
        statements,
      );
      await meeting.sync(first, paused: true);
      final watch = Stopwatch()..start();
      final analysis = await meeting.analyze(first);
      result['analysis_seconds'] = watch.elapsedMilliseconds / 1000;
      result['first_analysis'] = analysis;
      checks['no_automatic_retraction'] =
          (analysis['withdrawals'] as List? ?? []).isEmpty;
      final progress = await DioProgressRepository(api).load();
      checks['goal_projected'] = progress.goals.any(
        (g) => g.condition.contains('Android'),
      );
      checks['commitment_projected'] = progress.commitments.any(
        (c) => c.title.contains('测试报告'),
      );
      checks['proposal_does_not_change_deadline'] = progress.commitments.any(
        (c) =>
            c.title.contains('测试报告') &&
            c.deadline.toUtc().year == 2030 &&
            c.deadline.toUtc().month == 10 &&
            c.deadline.toUtc().day == 28,
      );
      checks['recorded_party_is_ours'] = progress.commitments.any(
        (c) => c.title.contains('测试报告') && c.side.name == 'ours',
      );
      result['goal_count'] = progress.goals.length;
      result['commitment_count'] = progress.commitments.length;
      await save();
      expect(checks['goal_projected'], isTrue);
      expect(checks['commitment_projected'], isTrue);
      expect(checks['proposal_does_not_change_deadline'], isTrue);
      expect(checks['recorded_party_is_ours'], isTrue);
      expect(checks['no_automatic_retraction'], isTrue);

      first = first.copy(ended: true, syncRevision: 2);
      await meeting.sync(first, paused: false);
      final archive = await meeting.archive(first);
      await knowledge.load();
      final archived = knowledge.document('meeting-${first.id}');
      checks['archive_visible_in_cloud_knowledge'] =
          archived?.selected.content == archive['markdown'];
      expect(checks['archive_visible_in_cloud_knowledge'], isTrue);

      final second = fixture(
        'chain-next-${DateTime.now().microsecondsSinceEpoch}',
        ['回到星澜项目，之前Android和iOS的范围继续。Windows可以一起做吗？先评估，尚未批准增加范围。'],
      );
      await meeting.sync(second, paused: true);
      final next = await meeting.analyze(second);
      result['second_analysis'] = next;
      checks['next_meeting_retrieves_previous_minutes'] =
          (next['knowledge_sources'] as List? ?? []).any(
            (h) => h['sessionId'] == first.id,
          );
      checks['windows_proposal_no_approved_expansion'] =
          (next['goals'] as List? ?? []).every(
            (g) => g['authorization_status'] == 'pending',
          ) &&
          (next['commitments'] as List? ?? []).every(
            (c) => c['authorization_status'] == 'pending',
          );
      final afterSecond = await DioProgressRepository(api).load();
      checks['windows_proposal_no_approved_expansion'] =
          checks['windows_proposal_no_approved_expansion']! &&
          afterSecond.goals.length == progress.goals.length &&
          afterSecond.goals.every((g) => !g.condition.contains('Windows'));
      result['second_candidate_goals'] = next['goals'];
      result['business_goal_count_after_second_meeting'] =
          afterSecond.goals.length;
      expect(checks['next_meeting_retrieves_previous_minutes'], isTrue);
      expect(checks['windows_proposal_no_approved_expansion'], isTrue);
      final hits = await repo.search('Windows Android 合同');
      final contractHit = hits.firstWhere((h) => h['documentId'] == id);
      expect(await repo.resolve(contractHit), isTrue);
      expect(await knowledge.delete(id!), isTrue);
      checks['deleted_citation_rejected'] = !await repo.resolve(contractHit);
      expect(checks['deleted_citation_rejected'], isTrue);
      await save();

      // 实际服务端审批 + 原生创建回读，再重试验证不重复。只删除本测试创建的事件。
      final actions =
          (await api.get('actions', authenticated: true))['data'] as List;
      final action = Map<String, dynamic>.from(
        actions.firstWhere((a) => a['status'] == 'pending'),
      );
      final executor = DeviceCalendarExecutor();
      calendarFixture = executor;
      expect((await executor.plugin.requestPermissions()).data, isTrue);
      final inventory = await executor.plugin.retrieveCalendars();
      result['calendar_inventory'] = {
        'success': inventory.isSuccess,
        'count': inventory.data?.length,
        'writable_flags': inventory.data?.map((c) => c.isReadOnly).toList(),
      };
      expect(inventory.isSuccess, isTrue);
      if (!(inventory.data?.any((c) => c.isReadOnly == false) ?? false)) {
        final created = await executor.plugin.createCalendar(
          '言枢临时联调日历',
          localAccountName: 'YanShu synthetic test',
          calendarColor: const Color(0xff0057ff),
        );
        expect(created.isSuccess, isTrue);
        expect(created.data, isNotNull);
        temporaryCalendarId = created.data;
        result['temporary_calendar_created'] = true;
        await save();
      }
      final device = await executor.deviceId();
      final decision = await api.post(
        'actions/${action['id']}/decision',
        authenticated: true,
        data: {
          'fingerprint': action['fingerprint'],
          'allow': true,
          'deviceId': device,
        },
      );
      expect(decision['data']['status'], 'awaiting_device');
      final receipt = await executor.execute(
        user.id,
        action,
        isCurrent: () => true,
      );
      try {
        final repeated = await executor.execute(
          user.id,
          action,
          isCurrent: () => true,
        );
        checks['calendar_retry_same_native_event'] =
            repeated['eventId'] == receipt['eventId'];
        final saved = await api.post(
          'actions/${action['id']}/receipt',
          authenticated: true,
          data: {...receipt, 'deviceId': device},
        );
        checks['calendar_native_readback_verified'] =
            saved['data']['status'] == 'completed';
      } finally {
        final calendars =
            (await executor.plugin.retrieveCalendars()).data ?? [];
        var removed = false;
        for (final c in calendars) {
          if (c.id != null) {
            final existing = await executor.plugin.retrieveEvents(
              c.id!,
              RetrieveEventsParams(eventIds: [receipt['eventId']]),
            );
            if (existing.data?.any(
                  (e) =>
                      e.eventId == receipt['eventId'] &&
                      e.description?.contains('yanshu:${user.id}:') == true,
                ) ==
                true) {
              final deletion = await executor.plugin.deleteEvent(
                c.id!,
                receipt['eventId'],
              );
              final fresh = await executor.plugin.retrieveEvents(
                c.id!,
                RetrieveEventsParams(eventIds: [receipt['eventId']]),
              );
              removed =
                  deletion.isSuccess &&
                  deletion.data == true &&
                  fresh.isSuccess &&
                  (fresh.data?.isEmpty ?? false);
            }
          }
        }
        result['synthetic_calendar_event_removed'] = removed;
        expect(removed, isTrue);
      }
      await save();

      final profiles = ProfileRepository(
        MemoryProfileStore(
          value: jsonEncode(
            ProfileData(
              accountId: user.id,
              name: user.name,
              email: user.email,
            ).toJson(),
          ),
        ),
      );
      await tester.pumpWidget(
        YanShuApp(
          initialLocation: '/progress',
          authRepository: auth,
          profileRepository: profiles,
          knowledgeRepository: repo,
          progressRepository: DioProgressRepository(api),
          meetingRemote: meeting,
          meetingStore: MemoryMeetingStore(),
        ),
      );
      for (var i = 0; i < 60; i++) {
        await tester.pump(const Duration(milliseconds: 150));
      }
      expect(find.text('持续目标'), findsWidgets);
      expect(find.textContaining('双端测试'), findsWidgets);
      checks['progress_screen_real_cloud_data'] = true;
      await tester.tap(find.text('知识库').last);
      for (var i = 0; i < 35; i++) {
        await tester.pump(const Duration(milliseconds: 150));
      }
      expect(find.text('项目资料加载失败'), findsNothing);
      expect(find.text('星澜一期范围合同（合成测试）'), findsOneWidget);
      checks['knowledge_tab_real_cloud_data'] = true;
      await tester.pumpWidget(const SizedBox.shrink());
      await save();
    } catch (error) {
      result['failure_type'] = error.runtimeType.toString();
      if (error is ApiFailure) {
        result['failure'] = {'message': error.message, 'status': error.status};
      }
      await save();
      rethrow;
    } finally {
      if (temporaryCalendarId != null && calendarFixture != null) {
        final deletion = await calendarFixture.plugin.deleteCalendar(
          temporaryCalendarId,
        );
        final calendars = await calendarFixture.plugin.retrieveCalendars();
        result['temporary_calendar_removed'] =
            deletion.isSuccess &&
            deletion.data == true &&
            calendars.isSuccess &&
            !(calendars.data?.any((c) => c.id == temporaryCalendarId) ?? true);
      }
      if (audio != null && await File(audio).exists()) {
        await File(audio).delete();
      }
      await recorder.dispose();
      knowledge?.dispose();
      await auth.logout();
      await store.clear();
      await save();
    }
  }, timeout: const Timeout(Duration(minutes: 15)));
}
