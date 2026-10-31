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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    '持续采音的Flutter ViewModel经Dio在会中收到真实云端AI提示',
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
          remote: DioMeetingRepository(client),
        );
        await vm.start(demo: false);
        var ticks = 0;
        voice = Timer.periodic(const Duration(milliseconds: 200), (_) {
          ticks++;
          recorder.amplitudes.add(.025);
          recorder.transcriptEvents.add(
            MeetingTranscript(1, '继续讨论第$ticks个信息，大家一直在说话', isFinal: false),
          );
        });
        final watch = Stopwatch()..start();
        double? firstSuggestion, firstLiveSupplement, firstRisk;
        void measureFirstText() {
          final items = vm?.record?.insights ?? <MeetingInsight>[];
          if (items.any((i) => i.body.trim().isNotEmpty)) {
            firstSuggestion ??= watch.elapsedMilliseconds / 1000;
          }
          if (items.any(
            (i) => i.kind == InsightKind.risk && i.body.trim().isNotEmpty,
          )) {
            firstRisk ??= watch.elapsedMilliseconds / 1000;
          }
          if (items.any(
            (i) => i.title == 'AI 补充' && i.body.trim().isNotEmpty,
          )) {
            firstLiveSupplement ??= watch.elapsedMilliseconds / 1000;
          }
        }

        vm.addListener(measureFirstText);
        const actionCase =
            String.fromEnvironment('YANSHU_CLOUD_SCENARIO') == 'action';
        recorder.transcriptEvents.add(
          const MeetingTranscript(
            0,
            actionCase
                ? '乙方负责处理同步延迟，周一下午提交测试版本，但接口今天无法确认，可能影响交付。'
                : '我们不能承诺下周上线，ERP接口仍然超时，验收必须先通过，Windows范围尚未批准。',
            isFinal: true,
            speakerId: 'synthetic:a',
            speakerSeparated: true,
            audioStart: Duration.zero,
            audioEnd: Duration(seconds: 1),
          ),
        );
        while ((firstRisk == null ||
                (actionCase && firstLiveSupplement == null)) &&
            watch.elapsed < const Duration(seconds: 75)) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        report.addAll({
          'firstRiskSeconds': firstRisk,
          'observedSeconds': watch.elapsedMilliseconds / 1000,
          'firstSuggestionSeconds': firstSuggestion,
          'firstLiveSupplementSeconds': firstLiveSupplement,
          'insights': vm.record!.insights.length,
          'phase': vm.phase.name,
          'partialStillUpdating': vm.partial.isNotEmpty,
          'voiceTicks': ticks,
          'recorderPauses': recorder.pauses,
          'recorderStops': recorder.stops,
          'semanticCheckpoint': vm.record!.utterances.first.turnStatus,
          'cloudError': vm.cloudError,
          'analysisStatus': vm.analysisStatus,
          'requests': requests,
        });
        expect(
          vm.record!.insights.any((i) => i.kind == InsightKind.risk),
          isTrue,
          reason: '必须收到核心风险分析，不能只用快速AI补充冒充完整会中理解',
        );
        expect(vm.phase, MeetingPhase.recording);
        expect(vm.partial, isNotEmpty);
        expect(recorder.pauses, 0);
        expect(recorder.stops, 0);
        if (actionCase) {
          expect(firstLiveSupplement, isNotNull, reason: '必须真实收到并行只读快通道正文');
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
        final actionCase =
            const String.fromEnvironment('YANSHU_CLOUD_SCENARIO') == 'action';
        await File(
          actionCase
              ? 'build/continuous_meeting_action_cloud_20261022.json'
              : 'build/continuous_meeting_cloud_20261022.json',
        ).writeAsString(const JsonEncoder.withIndent('  ').convert(report));
      }
      expect(report['temporaryAccountDeleted'], isTrue);
    },
    skip: !const bool.fromEnvironment('YANSHU_REAL_CLOUD_TEST'),
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
