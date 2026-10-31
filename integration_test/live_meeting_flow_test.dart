import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:provider/provider.dart';
import 'package:yanshu/main.dart' as production;
import 'package:yanshu/core/network/api_client.dart';
import 'package:yanshu/core/network/api_config.dart';
import 'package:yanshu/features/auth/repositories/dio_auth_repository.dart';
import 'package:yanshu/features/auth/services/session_store.dart';
import 'package:yanshu/features/meeting/meeting_services.dart';
import 'package:yanshu/features/meeting/meeting_view_model.dart';
import 'package:yanshu/features/knowledge/viewmodels/knowledge_view_model.dart';
import 'package:yanshu/features/progress/viewmodels/progress_view_model.dart';

// 只在独立测试包中替换采音平台边界；不打开麦克风，不模拟 ASR/LLM 返回。
class PublicPcmInput {
  PublicPcmInput(this.messenger, this.bytes);
  final TestDefaultBinaryMessenger messenger;
  final Uint8List bytes;
  Timer? timer;
  MockStreamHandlerEventSink? sink;
  int offset = 0;
  bool paused = false;
  void install() {
    messenger.setMockMethodCallHandler(
      const MethodChannel('yanshu/audio_input'),
      (_) async => {
        'id': 'qa-public-pcm',
        'name': '公开音频自动化输入',
        'type': 'usb',
        'verified': true,
        'sampleRate': 16000,
        'channels': 1,
        'silenced': false,
      },
    );
    messenger.setMockStreamHandler(
      const EventChannel('yanshu/audio_input/events'),
      MockStreamHandler.inline(onListen: (_, sink) {}),
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('com.llfbandit.record/messages'),
      (call) async {
        final id = (call.arguments as Map?)?['recorderId'];
        switch (call.method) {
          case 'create':
            messenger.setMockStreamHandler(
              EventChannel('com.llfbandit.record/events/$id'),
              MockStreamHandler.inline(onListen: (_, sink) {}),
            );
            messenger.setMockStreamHandler(
              EventChannel('com.llfbandit.record/eventsRecord/$id'),
              MockStreamHandler.inline(
                onListen: (_, events) {
                  sink = events;
                  Timer(const Duration(milliseconds: 500), () {
                    timer = Timer.periodic(const Duration(milliseconds: 100), (
                      _,
                    ) {
                      if (paused || offset >= bytes.length) return;
                      final end = (offset + 3200).clamp(0, bytes.length);
                      sink?.success(Uint8List.sublistView(bytes, offset, end));
                      offset = end;
                    });
                  });
                },
                onCancel: (_) {
                  timer?.cancel();
                },
              ),
            );
          case 'hasPermission':
            return true;
          case 'listInputDevices':
            return [
              {
                'id': 'qa-public-pcm',
                'label': '公开音频自动化输入',
                'type': 'usb',
                'sampleRates': [16000],
              },
            ];
          case 'pause':
            paused = true;
          case 'resume':
            paused = false;
          case 'stop':
            timer?.cancel();
            sink?.endOfStream();
          case 'dispose':
            timer?.cancel();
        }
        return null;
      },
    );
  }
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    '正式main入口：真实ASR、匿名分离、真实Agent、进展和知识库',
    (tester) async {
      final report = <String, dynamic>{
        'synthetic_only': true,
        'microphone_test': false,
        'input': '公开PCM及明确标注的合成会议文字',
        'checks': <String, bool>{},
      };
      void save() => binding.reportData = report;
      Future<void> until(bool Function() condition, {int seconds = 45}) async {
        final deadline = DateTime.now().add(Duration(seconds: seconds));
        while (!condition() && DateTime.now().isBefore(deadline)) {
          await tester.pump(const Duration(milliseconds: 100));
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        expect(condition(), isTrue);
      }

      final api = ApiClient(baseUrl: ApiConfig.baseUrl);
      final auth = DioAuthRepository(
        api,
        SecureSessionStore(ApiConfig.baseUrl),
      );
      MeetingViewModel? vm;
      PublicPcmInput? input;
      try {
        final identity = await auth.register(
          '云端APP联调',
          'cloud-app-live-${DateTime.now().microsecondsSinceEpoch}@example.com',
          'Live-Flow-Synthetic-2026!',
        );
        report['test_account'] = {'id': identity.id, 'email': identity.email};
        save();
        final wav = await rootBundle.load('assets/qa/asr_reference.wav');
        input = PublicPcmInput(
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger,
          wav.buffer.asUint8List(
            wav.offsetInBytes + 44,
            wav.lengthInBytes - 44,
          ),
        )..install();
        await production.main();
        await until(() => find.text('点击开始会话').evaluate().isNotEmpty);
        final homeContext = tester.element(find.text('点击开始会话'));
        final progress = homeContext.read<ProgressViewModel>();
        final knowledge = homeContext.read<KnowledgeViewModel>();
        await progress.load();
        await knowledge.load();
        expect(progress.data.goals, isEmpty);
        expect(progress.data.commitments, isEmpty);
        expect(knowledge.data.documents, isEmpty);
        report['checks']['fresh_account_no_demo_goals_or_documents'] = true;
        save();
        await tester.tap(find.text('点击开始会话'));
        await tester.pumpAndSettle();
        expect(find.text('体验模拟会话'), findsNothing);
        await tester.ensureVisible(
          find.byKey(const ValueKey('start-live-meeting')),
        );
        await tester.tap(find.byKey(const ValueKey('start-live-meeting')));
        await until(
          () =>
              find.byKey(const ValueKey('meeting-pause')).evaluate().isNotEmpty,
        );
        vm = tester
            .element(find.byKey(const ValueKey('meeting-pause')))
            .read<MeetingViewModel>();
        expect(
          (vm.recorder as DeviceMeetingRecorder).recognizerFactory,
          isNotNull,
        );
        expect(vm.record!.demo, isFalse);
        expect(vm.record!.utterances, isEmpty);
        report['checks']['production_main_factory_tencent_and_no_preset_transcripts'] =
            true;
        save();
        await until(() => input!.offset >= input.bytes.length);
        await vm.pause();
        expect(vm.record!.utterances, isNotEmpty);
        report['asr_utterances'] = vm.record!.utterances
            .map(
              (u) => {
                'raw': u.raw,
                'speaker': u.speaker,
                'speakerId': u.speakerId,
                'separated': u.speakerSeparated,
              },
            )
            .toList();
        expect(vm.record!.utterances.any((u) => u.speakerSeparated), isTrue);
        report['checks']['real_cloud_asr_with_anonymous_speaker'] = true;
        save();
        for (final text in [
          '交付目标是完成Android和iOS双端测试并部署到客户预发环境。验收我们先按……',
          '先谈交付范围。Windows只是新增提议，尚未批准，一期仍只包含Android和iOS，原交付周期三十天。',
          '接着刚才的验收，验收标准是双端测试全部通过。',
          '新增Windows如果仍要求三十天交付，需要重新评估工作量和风险，现在尚未确认。',
          '我方承诺在下周三提交双端测试报告。我们考虑改为下周五交付，但还没确定，请不要取消原计划。',
        ]) {
          await vm.addManual('合成测试发言', text);
        }
        await vm.syncCloud();
        expect(vm.cloudError, isNull);
        final detail =
            (await api.get(
                  'meetings/${vm.record!.id}',
                  authenticated: true,
                  accountId: identity.id,
                ))['data']
                as Map;
        final analysis = detail['analysis'] as Map;
        report['analysis'] = {
          'provider': analysis['provider'],
          'runtime': analysis['runtime'],
          'agents': analysis['agents_completed'],
          'insights': analysis['insights'],
          'repairs': analysis['repairs'],
          'withdrawals': analysis['withdrawals'],
        };
        expect(
          (analysis['agents_completed'] as List).contains('verify'),
          isTrue,
        );
        expect(analysis['withdrawals'] as List, isEmpty);
        report['checks']['real_agent_candidates_without_unapproved_withdrawal'] =
            true;
        save();
        await progress.load();
        report['progress_counts'] = {
          'goals': progress.data.goals.length,
          'commitments': progress.data.commitments.length,
          'pending': progress.data.pending.length,
        };
        expect(
          progress.data.goals.length +
              progress.data.commitments.length +
              progress.data.pending.length,
          greaterThan(0),
        );
        report['checks']['real_progress_projection'] = true;
        save();
        expect(await vm.finish(), isTrue);
        await vm.syncCloud();
        expect(vm.cloudError, isNull);
        await knowledge.load();
        final archivedDocumentId = 'meeting-${vm.record!.id}';
        expect(
          knowledge.data.documents.any((d) => d.id == archivedDocumentId),
          isTrue,
        );
        report['checks']['real_minutes_archived_to_knowledge'] = true;
        save();
      } finally {
        input?.timer?.cancel();
        if (vm != null) {
          final paths = List<String>.of(vm.record?.audioPaths ?? []);
          await vm.suspendForLogout();
          for (final path in paths) {
            for (final file in [File(path), File('$path.capture.json')]) {
              if (await file.exists()) await file.delete();
            }
          }
        }
        await auth.logout();
        api.dio.close(force: true);
        save();
        await tester.pumpWidget(const SizedBox.shrink());
      }
    },
    timeout: const Timeout(Duration(minutes: 12)),
  );
}
