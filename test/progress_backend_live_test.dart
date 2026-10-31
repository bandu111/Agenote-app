import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:yanshu/features/auth/repositories/dio_auth_repository.dart';
import 'package:yanshu/features/meeting/meeting_models.dart';
import 'package:yanshu/features/meeting/meeting_remote.dart';
import 'package:yanshu/features/progress/models/progress_models.dart';
import 'package:yanshu/features/progress/repositories/dio_progress_repository.dart';
import 'package:yanshu/features/progress/viewmodels/progress_view_model.dart';
import 'package:yanshu/core/network/api_config.dart';
import 'dio_auth_repository_test.dart' show MemorySessionStore;
import 'meeting_backend_live_test.dart' show liveApi;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    '真实Dio会议分析→进展落库→改期与状态更新→重读及跨账户隔离',
    () async {
      final api = liveApi();
      final auth = DioAuthRepository(api, MemorySessionStore());
      final accounts = <Map<String, String>>[];
      final checks = <String, bool>{};
      Future<void> save() => File('docs/progress_flutter_live_result.json')
          .writeAsString(
            jsonEncode({
              'synthetic_only': true,
              'audio': 'not_uploaded',
              'speaker_diarization': 'synthetic_fixture',
              'real_backend': true,
              'real_hermes_deepseek': true,
              'accounts_for_cleanup': accounts,
              'checks': checks,
            }),
          )
          .then((_) {});
      try {
        final email =
            'auto-meeting-progress-${DateTime.now().microsecondsSinceEpoch}@example.com';
        final user = await auth.register(
          '自动化会议',
          email,
          'Only-Local-Progress-Test-2026!',
        );
        accounts.add({'id': user.id, 'email': email});
        await save();
        final repo = DioProgressRepository(api);
        expect((await repo.load()).goals, isEmpty);
        const statements = [
          '交付目标是完成 Android 与 iOS 双端测试并部署至预发环境。交期2026年11月5日。验收要求是通过双方确认的测试清单。里程碑为需求确认、双端测试、预发部署。',
          '对于刚才的交付目标，我方承诺2026年10月28日提交双端测试报告。',
          'Windows 需求先评估，尚未同意加入交付范围。',
        ];
        final record = MeetingRecord(
          id: 'progress-${DateTime.now().microsecondsSinceEpoch}',
          startedAt: DateTime.parse('2026-10-19T10:00:00+08:00'),
          demo: false,
          ownerId: user.id,
          syncRevision: 1,
          elapsed: const Duration(seconds: 30),
          utterances: [
            for (var i = 0; i < statements.length; i++)
              MeetingUtterance(
                id: 'u$i',
                speaker: '发言人 A',
                speakerId: 'fixture-a',
                speakerSeparated: true,
                raw: statements[i],
                at: Duration(seconds: i * 10),
              ),
          ],
        );
        final meeting = DioMeetingRepository(
          api,
          pollInterval: const Duration(seconds: 1),
        );
        await meeting.sync(record, paused: true);
        final analyzed = await meeting.analyze(record);
        expect(analyzed['commitments'], isNotEmpty);
        final vm = ProgressViewModel(repo);
        await vm.load();
        expect(vm.error, isNull);
        expect(vm.data.goals, isNotEmpty);
        expect(vm.data.commitments, isNotEmpty);
        final item = vm.data.commitments.first;
        expect(item.evidence.transcript, contains('我方承诺'));
        expect(item.evidence.uri, isNull);
        expect(item.evidence.speakerConfirmed, isFalse);
        checks['real_analysis_materialized_to_progress'] = true;
        if (item.status == CommitmentStatus.pending) {
          expect(
            await vm.updateCommitment(
              item.id,
              CommitmentStatus.planned,
              '人工核对承诺成立',
            ),
            isTrue,
          );
        }
        expect(
          await vm.reschedule(
            item.id,
            DateTime.parse('2026-11-02T18:00:00+08:00'),
            '双方确认改期',
          ),
          isTrue,
        );
        expect(
          await vm.updateCommitment(
            item.id,
            CommitmentStatus.claimed,
            '人工记录对方声明报告已提交',
          ),
          isTrue,
        );
        final fresh = await DioProgressRepository(api).load();
        final saved = fresh.commitments.firstWhere((c) => c.id == item.id);
        expect(saved.status, CommitmentStatus.claimed);
        expect(saved.deadline.toUtc(), DateTime.parse('2026-11-02T10:00:00Z'));
        expect(saved.history.length, greaterThanOrEqualTo(2));
        expect(fresh.goals.map((g) => g.id), contains(vm.data.goals.first.id));
        checks['reschedule_status_and_audit_persisted'] = true;
        checks['self_report_not_automatically_verified'] = true;
        checks['original_evidence_retained_without_audio_upload'] = true;
        await save();
        await auth.logout();
        expect(vm.data.commitments, isEmpty);
        final otherEmail =
            'auto-meeting-progress-other-${DateTime.now().microsecondsSinceEpoch}@example.com';
        final other = await auth.register(
          '隔离账户',
          otherEmail,
          'Only-Local-Progress-Test-2026!',
        );
        accounts.add({'id': other.id, 'email': otherEmail});
        await save();
        expect((await DioProgressRepository(api).load()).goals, isEmpty);
        await expectLater(
          api.post(
            'progress/commitments/${item.id}/status',
            authenticated: true,
            data: {'version': 1, 'status': 'withdrawn', 'note': '越权验证'},
          ),
          throwsA(isA<ApiFailure>().having((e) => e.status, 'status', 404)),
        );
        checks['cross_account_progress_isolation'] = true;
        vm.dispose();
        await save();
      } finally {
        await auth.logout();
      }
    },
    skip: !const bool.fromEnvironment('RUN_PROGRESS_BACKEND'),
    timeout: const Timeout(Duration(minutes: 8)),
  );
}
