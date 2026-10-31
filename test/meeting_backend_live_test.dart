import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yanshu/core/network/api_client.dart';
import 'package:yanshu/core/network/api_config.dart';
import 'package:yanshu/features/auth/repositories/dio_auth_repository.dart';
import 'package:yanshu/features/home/viewmodels/home_view_model.dart';
import 'package:yanshu/features/knowledge/repositories/knowledge_repository.dart';
import 'package:yanshu/features/knowledge/viewmodels/knowledge_view_model.dart';
import 'package:yanshu/features/meeting/meeting_models.dart';
import 'package:yanshu/features/meeting/meeting_remote.dart';
import 'package:yanshu/features/meeting/meeting_services.dart';
import 'package:yanshu/features/meeting/meeting_store.dart';
import 'package:yanshu/features/meeting/meeting_view_model.dart';
import 'package:yanshu/features/notifications/notification_model.dart';
import 'dio_auth_repository_test.dart' show MemorySessionStore;
import 'meeting_test.dart' show FakeMeetingRecorder, FakeMeetingCalendar;

/// 普通 Flutter 测试默认拦截 HTTP；仅这个显式开启的本机联调使用真实客户端。
class RealMeetingHttp extends HttpOverrides {}

ApiClient liveApi() => ApiClient(
  baseUrl: ApiConfig.baseUrl,
  dio: Dio()
    ..httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: () => RealMeetingHttp().createHttpClient(null),
    ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'Flutter Dio → 真实账户后端 → Hermes 多 Agent → 本地知识库归档',
    () async {
      final accounts = <Map<String, String>>[];
      final checks = <String, bool>{};
      final artifact = File('docs/meeting_flutter_live_result.json');
      Future<void> save() => artifact
          .writeAsString(
            jsonEncode({
              'synthetic_only': true,
              'recorder': 'simulated',
              'real_microphone_tested': false,
              'real_backend': true,
              'real_hermes_deepseek': true,
              'accounts_for_cleanup': accounts,
              'checks': checks,
            }),
          )
          .then((_) {});
      final api = liveApi();
      final auth = DioAuthRepository(api, MemorySessionStore());
      final remote = DioMeetingRepository(
        api,
        pollInterval: const Duration(seconds: 1),
      );
      final recorder = FakeMeetingRecorder();
      final store = MemoryMeetingStore();
      final knowledge = KnowledgeViewModel(
        KnowledgeRepository(MemoryKnowledgeStore(), seedExamples: true),
      );
      await knowledge.load();
      final vm = MeetingViewModel(
        store: store,
        recorder: recorder,
        calendar: FakeMeetingCalendar(),
        knowledge: knowledge,
        notifications: NotificationModel(),
        home: HomeViewModel(),
        remote: remote,
        speakerName: () => '项目负责人',
      );
      try {
        final email =
            'auto-meeting-${DateTime.now().microsecondsSinceEpoch}@example.com';
        final user = await auth.register(
          '自动化会议',
          email,
          'Only-Local-Meeting-Test-2026!',
        );
        accounts.add({'id': user.id, 'email': email});
        await save();
        await vm.start(demo: false);
        recorder.transcriptEvents.add(
          const MeetingTranscript(0, '验收指标我们先', isFinal: false),
        );
        expect(vm.partial, '验收指标我们先');
        recorder.transcriptEvents.add(
          const MeetingTranscript(0, '嗯，嗯，验收指标我们我们先在……确认。', isFinal: true),
        );
        expect(vm.partial, isEmpty);
        const turns = [
          ('客户', '打断一下，先谈预算，预算还是原来的十万元。'),
          ('发言人 A', '原先约定本周五交付 Android 和 iOS。'),
          ('客户', 'Windows 端能不能一起做？'),
          ('发言人 A', '这个需求先评估一下，还没有同意加入一期范围。'),
          ('发言人 A', '接回刚才验收指标的话题，我们先在周三确认验收指标清单。'),
          ('发言人 A', '取消刚才本周五交付的决定，改为下周一交付，新增 Windows 另行评估。'),
          ('客户', '同意改为下周一，Windows 暂不纳入一期，但后续加上也不能增加预算。'),
          ('发言人 B', '我方承诺周三提交技术可行性评估报告。'),
        ];
        for (final turn in turns) {
          await vm.addManual(turn.$1, turn.$2);
        }
        // 仅测试夹具模拟分离后的匿名来源；手机收音本身仍未接入说话人分离。
        final last = vm.record!.utterances.last;
        vm.record = vm.record!.copy(
          utterances: [
            ...vm.record!.utterances.take(vm.record!.utterances.length - 1),
            MeetingUtterance.fromJson({
              ...last.toJson(),
              'speakerId': 'fixture-b',
              'speakerSeparated': true,
            }),
          ],
        );
        final originals = {for (final u in vm.record!.utterances) u.id: u.raw};
        final oldDateId = vm.record!.utterances[2].id;
        await vm.waitForPolish();
        expect(vm.polishError, isNull);
        expect(vm.record!.utterances.first.cleaned, isNot(contains('嗯')));
        expect(vm.record!.utterances.first.cleaned, isNot(contains('我们我们')));
        checks['real_transcript_polish'] = true;
        await vm.pause();
        await vm.syncCloud();
        expect(vm.cloudError, isNull);
        expect(vm.cloudAnalyzed, isTrue);
        expect(vm.record!.commitments, isNotEmpty);
        expect(
          vm.record!.commitments.every(
            (c) => c['verification_status'] == 'not_verified',
          ),
          isTrue,
        );
        expect(vm.record!.utterances.first.speaker, '发言人 A');
        expect(vm.record!.utterances.first.speakerSeparated, isFalse);
        expect(vm.record!.utterances.first.repair, isNotNull);
        expect(
          vm.record!.utterances.first.repair!.validFor(
            vm.record!.utterances.first.raw,
          ),
          isTrue,
        );
        expect(
          vm.record!.utterances.firstWhere((u) => u.id == oldDateId).withdrawn,
          isTrue,
        );
        expect(
          vm.record!.insights.any((i) => i.kind == InsightKind.risk),
          isTrue,
        );
        final detail =
            (await api.get(
                  'meetings/${vm.record!.id}',
                  authenticated: true,
                ))['data']
                as Map;
        expect(detail['paused'], isTrue);
        checks.addAll({
          'partial_and_final_flow': true,
          'six_agent_results_applied': true,
          'commitment_agent_evidence_preserved': true,
          'unverified_microphone_speaker_anonymous': true,
          'memory_gap_in_existing_stream': true,
          'old_decision_struck_out': true,
          'pause_synced': true,
        });
        await save();
        await vm.resume();
        expect(vm.phase, MeetingPhase.recording);
        expect(await vm.finish(), isTrue);
        final localDocument = vm.record!.documentId;
        await vm.syncCloud();
        expect(vm.cloudError, isNull);
        expect(vm.record!.cloudMinutes, isNotNull);
        expect(vm.record!.documentId, localDocument);
        expect(
          knowledge.document(localDocument!)!.selected.content,
          vm.record!.cloudMinutes,
        );
        expect(
          knowledge.data.documents.where((d) => d.id == localDocument).length,
          1,
        );
        for (final u in vm.record!.utterances) {
          expect(u.raw, originals[u.id]);
        }
        final restored = await DioMeetingRepository(api).history();
        expect(restored.any((r) => r.id == vm.record!.id && r.ended), isTrue);
        expect(restored.single.audioPaths, isEmpty);
        expect(vm.record!.audioPaths, isNotEmpty);
        final serverArchive =
            (await api.get(
                  'meetings/${vm.record!.id}/archive',
                  authenticated: true,
                ))['data']
                as Map;
        expect(serverArchive['markdown'], vm.record!.cloudMinutes);
        checks.addAll({
          'resume_keeps_originals': true,
          'finish_synced': true,
          'server_archive_matches_local': true,
          'knowledge_card_reused': true,
          'history_restored': true,
          'audio_stays_local': true,
        });
        await save();
        final otherApi = liveApi();
        final otherAuth = DioAuthRepository(otherApi, MemorySessionStore());
        final otherEmail =
            'auto-meeting-${DateTime.now().microsecondsSinceEpoch}@example.com';
        final other = await otherAuth.register(
          '隔离账户',
          otherEmail,
          'Only-Local-Meeting-Test-2026!',
        );
        accounts.add({'id': other.id, 'email': otherEmail});
        await save();
        await expectLater(
          otherApi.get('meetings/${vm.record!.id}', authenticated: true),
          throwsA(isA<ApiFailure>().having((e) => e.status, 'status', 404)),
        );
        await otherAuth.logout();
        checks['cross_account_isolation'] = true;
        await save();
        expect(checks.values.every((passed) => passed), isTrue);
      } finally {
        vm.dispose();
        knowledge.dispose();
        vm.notifications.dispose();
        vm.home.dispose();
        if (auth.authenticated) await auth.logout();
        await save();
      }
    },
    skip: const bool.fromEnvironment('RUN_MEETING_BACKEND')
        ? false
        : '显式开启才调用真实模型与本机后端',
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
