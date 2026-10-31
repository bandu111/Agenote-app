import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yanshu/core/network/api_client.dart';
import 'package:yanshu/features/meeting/meeting_models.dart';
import 'package:yanshu/features/meeting/meeting_remote.dart';
import 'package:yanshu/features/meeting/meeting_store.dart';
import 'package:yanshu/features/meeting/meeting_view_model.dart';
import 'package:yanshu/features/meeting/local_speech.dart';
import 'package:yanshu/features/knowledge/repositories/knowledge_repository.dart';
import 'package:yanshu/features/knowledge/viewmodels/knowledge_view_model.dart';
import 'package:yanshu/features/home/viewmodels/home_view_model.dart';
import 'package:yanshu/features/notifications/notification_model.dart';
import 'meeting_remote_test.dart' show NoisyMeetingRecorder;
import 'meeting_test.dart' show FakeMeetingCalendar;

class BaselineRiskRepository extends DioMeetingRepository {
  BaselineRiskRepository(super.client);
  @override
  Future<void> liveRisks(
    MeetingRecord record,
    void Function(Map<String, dynamic>) onUpdate,
  ) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    '连续四轮真实云端风险延迟，完整分析与持续采音同时运行',
    () async {
      // 仅显式启用的合成账户联调使用真实网络；不读取手机、真实账号或录音。
      final previousHttp = HttpOverrides.current;
      HttpOverrides.global = null;
      final client = ApiClient(baseUrl: 'https://124.220.169.122/api/v1/');
      final random = Random.secure();
      final nonce = List.generate(
        16,
        (_) => random.nextInt(16).toRadixString(16),
      ).join();
      final password =
          'Continuous-${List.generate(24, (_) => random.nextInt(36).toRadixString(36)).join()}';
      final report = <String, dynamic>{
        'scenario': const String.fromEnvironment(
          'YANSHU_CLOUD_SCENARIO',
          defaultValue: 'risk',
        ),
        'syntheticOnly': true,
        'realDio': true,
        'realCloudModels': true,
        'realAudio': false,
      };
      final requests = <Map<String, dynamic>>[];
      client.dio.interceptors.add(
        InterceptorsWrapper(
          onResponse: (response, handler) {
            requests.add({
              'path': response.requestOptions.path,
              'status': response.statusCode,
            });
            handler.next(response);
          },
          onError: (error, handler) {
            requests.add({
              'path': error.requestOptions.path,
              'status': error.response?.statusCode,
              'type': error.type.name,
            });
            handler.next(error);
          },
        ),
      );
      MeetingViewModel? vm;
      Timer? voice;
      var registered = false;
      final knowledge = KnowledgeViewModel(
        KnowledgeRepository(MemoryKnowledgeStore(), seedExamples: false),
      );
      final home = HomeViewModel(), notices = NotificationModel();
      try {
        final result = await client.post(
          'auth/register',
          data: {
            'name': '持续会议自动化核验',
            'email': 'continuous-$nonce@example.com',
            'password': password,
          },
        );
        final data = result['data'] as Map;
        final token = data['access_token'] as String,
            owner = (data['user'] as Map)['id'] as String;
        client.accessToken = () async => token;
        client.accountId = () => owner;
        registered = true;
        await knowledge.load();
        final recorder = NoisyMeetingRecorder();
        vm = MeetingViewModel(
          store: MemoryMeetingStore(),
          recorder: recorder,
          calendar: FakeMeetingCalendar(),
          knowledge: knowledge,
          home: home,
          notifications: notices,
          remote: const bool.fromEnvironment('YANSHU_RISK_BASELINE')
              ? BaselineRiskRepository(client)
              : DioMeetingRepository(client),
        );
        await vm.start(demo: false);
        var ticks = 0;
        var currentPartialIndex = 1;
        voice = Timer.periodic(const Duration(milliseconds: 200), (_) {
          ticks++;
          recorder.amplitudes.add(.025);
          recorder.transcriptEvents.add(
            MeetingTranscript(
              currentPartialIndex,
              '继续讨论第$ticks个信息，大家一直在说话',
              isFinal: false,
            ),
          );
        });
        final watch = Stopwatch()..start();
        const texts = [
          'ERP接口持续超时，已导致工单状态延迟，可能影响周一交付。',
          '移动端图片在弱网下上传失败，客户无法提交凭证，可能影响验收。',
          '客户的合同款今天无法支付，付款延迟会影响项目交付，请先核实。',
          'Windows端尚未批准纳入交付，但客户要求下周一起验收，范围存在冲突。',
        ];
        final rounds = <Map<String, dynamic>>[];
        void measure() {
          for (final row in rounds) {
            if (row['riskSeconds'] != null) continue;
            final u = vm!.record!.utterances
                .where((u) => u.raw == row['text'])
                .firstOrNull;
            if (u == null) continue;
            if (vm.record!.insights.any(
              (i) =>
                  i.kind == InsightKind.risk &&
                  i.body.trim().isNotEmpty &&
                  i.evidenceIds.contains(u.id),
            )) {
              row['riskSeconds'] =
                  (watch.elapsedMilliseconds - (row['startMs'] as int)) / 1000;
            }
          }
        }

        vm.addListener(measure);
        for (var n = 0; n < texts.length; n++) {
          currentPartialIndex = n + 1;
          final row = <String, dynamic>{
            'round': n + 1,
            'text': texts[n],
            'startMs': watch.elapsedMilliseconds,
          };
          rounds.add(row);
          recorder.transcriptEvents.add(
            MeetingTranscript(
              n,
              texts[n],
              isFinal: true,
              speakerId: 'synthetic:$n',
              speakerSeparated: true,
              audioStart: Duration(seconds: n * 12),
              audioEnd: Duration(seconds: n * 12 + 1),
            ),
          );
          await Future<void>.delayed(const Duration(seconds: 12));
        }
        while (rounds.any((r) => r['riskSeconds'] == null) &&
            watch.elapsed < const Duration(seconds: 100)) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        report.addAll({
          'baseline': const bool.fromEnvironment('YANSHU_RISK_BASELINE'),
          'rounds': [
            for (final r in rounds) {...r}..remove('text'),
          ],
          'phase': vm.phase.name,
          'partialStillUpdating': vm.partial.isNotEmpty,
          'voiceTicks': ticks,
          'recorderPauses': recorder.pauses,
          'recorderStops': recorder.stops,
          'cloudError': vm.cloudError,
          'requests': requests,
        });
        expect(vm.phase, MeetingPhase.recording);
        expect(recorder.pauses, 0);
        expect(recorder.stops, 0);
        if (!const bool.fromEnvironment('YANSHU_RISK_BASELINE')) {
          expect(
            rounds.every((r) => r['riskSeconds'] != null),
            isTrue,
            reason: '每轮新风险都须在会中出现，不能只测第一轮',
          );
        }
        report['passed'] = true;
      } finally {
        voice?.cancel();
        vm?.dispose();
        if (registered) {
          final result = await client.post(
            'auth/delete-account',
            authenticated: true,
            data: {'current_password': password, 'confirmation': 'DELETE'},
          );
          report['temporaryAccountDeleted'] = result['code'] == 200;
        }
        client.dio.close(force: true);
        knowledge.dispose();
        home.dispose();
        notices.dispose();
        HttpOverrides.global = previousHttp;
        await File(
          const bool.fromEnvironment('YANSHU_RISK_BASELINE')
              ? 'build/continuous_risk_baseline_20261022.json'
              : 'build/continuous_risk_after_20261022.json',
        ).writeAsString(const JsonEncoder.withIndent('  ').convert(report));
      }
      expect(report['temporaryAccountDeleted'], isTrue);
    },
    skip: !const bool.fromEnvironment('YANSHU_REAL_CLOUD_TEST'),
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
