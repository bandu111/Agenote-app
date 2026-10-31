import 'package:yanshu/features/progress/repositories/progress_repository.dart';
import 'package:yanshu/features/home/repositories/schedule_repository.dart';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:go_router/go_router.dart';
import 'package:yanshu/app/app.dart';
import 'package:yanshu/core/network/api_client.dart';
import 'package:yanshu/features/meeting/meeting_recorder_factory.dart';
import 'package:yanshu/features/meeting/meeting_services.dart';
import 'package:yanshu/features/meeting/audio_input_route.dart';
import 'package:yanshu/features/meeting/meeting_page.dart';
import 'package:yanshu/features/meeting/tencent_speech.dart';
import 'package:yanshu/features/meeting/meeting_models.dart';
import 'package:yanshu/features/meeting/meeting_remote.dart';
import 'package:yanshu/features/meeting/meeting_store.dart';
import 'package:yanshu/features/meeting/meeting_view_model.dart';
import 'package:yanshu/features/profile/repositories/profile_repository.dart';
import 'package:yanshu/features/knowledge/repositories/knowledge_repository.dart';
import 'meeting_test.dart' show FakeMeetingRecorder;

void main() {
  for (final direct in [true, false]) {
    for (final systemBack in [true, false]) {
      testWidgets(
        '会议返回保留录音 direct=$direct system=$systemBack',
        (tester) async {
          final recorder = FakeMeetingRecorder();
          await tester.pumpWidget(
            YanShuApp(
              initialLocation: direct ? '/meeting?record=1' : '/home',
              profileRepository: ProfileRepository(MemoryProfileStore()),
              knowledgeRepository: KnowledgeRepository(MemoryKnowledgeStore()),
              meetingStore: MemoryMeetingStore(),
              meetingRecorder: recorder,
            ),
          );
          await tester.pumpAndSettle();
          if (!direct) {
            GoRouter.of(
              tester.element(find.byType(NavigationBar)),
            ).push('/meeting?record=1');
            await tester.pumpAndSettle();
          }
          final vm = tester
              .element(find.byType(MeetingPage))
              .read<MeetingViewModel>();
          final id = vm.record!.id;
          if (systemBack) {
            await tester.binding.handlePopRoute();
          } else if (!direct && defaultTargetPlatform == TargetPlatform.iOS) {
            final pageContext = tester.element(find.byType(MeetingPage));
            expect(Theme.of(pageContext).platform, TargetPlatform.iOS);
            expect(ModalRoute.of(pageContext)!.popGestureEnabled, isTrue);
            final gesture = await tester.startGesture(const Offset(5, 200));
            await gesture.moveBy(const Offset(50, 0));
            await tester.pump(const Duration(milliseconds: 16));
            expect(
              ModalRoute.of(pageContext)!.navigator!.userGestureInProgress,
              isTrue,
            );
            await gesture.moveBy(const Offset(600, 0));
            await tester.pump(const Duration(milliseconds: 16));
            await gesture.up();
          } else {
            await tester.tap(find.byType(BackButton));
          }
          await tester.pumpAndSettle();
          expect(find.byType(MeetingPage), findsNothing);
          expect(find.byType(NavigationBar), findsOneWidget);
          expect(vm.active, isTrue);
          expect(recorder.pauses, 0);
          expect(recorder.stops, 0);
          GoRouter.of(
            tester.element(find.byType(NavigationBar)),
          ).push('/meeting');
          await tester.pumpAndSettle();
          expect(vm.record!.id, id);
          expect(recorder.starts, 1);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        },
        variant: TargetPlatformVariant({
          TargetPlatform.android,
          TargetPlatform.iOS,
        }),
      );
    }
  }
  testWidgets('采音状态只接受实际路由，区分蓝牙、手机、暂停与未知', (tester) async {
    final recorder = DeviceMeetingRecorder();
    await tester.pumpWidget(
      YanShuApp(
        initialLocation: '/meeting',
        profileRepository: ProfileRepository(MemoryProfileStore()),
        knowledgeRepository: KnowledgeRepository(MemoryKnowledgeStore()),
        meetingStore: MemoryMeetingStore(),
        meetingRecorder: recorder,
      ),
    );
    await tester.pumpAndSettle();
    final vm = tester
        .element(find.byType(MeetingPage))
        .read<MeetingViewModel>();
    expect(vm.inputStatus, '未开始采音');
    vm.phase = MeetingPhase.recording;
    expect(vm.inputStatus, '采音状态待核实');
    for (final entry in {
      'bluetooth': '蓝牙麦克风',
      'builtIn': '手机麦克风',
      'usb': '外接麦克风',
      'unknown': '采音状态待核实',
    }.entries) {
      recorder.inputRoute = AudioInputRoute(
        id: 'input',
        name: 'X5 Pro',
        type: entry.key,
        verified: true,
      );
      expect(vm.inputStatus, entry.value);
      expect(vm.recordingStatus, startsWith('${entry.value} ·'));
    }
    recorder.inputRoute = const AudioInputRoute(
      id: 'input',
      name: 'X5 Pro',
      type: 'bluetooth',
      verified: true,
      silenced: true,
    );
    expect(vm.inputStatus, '采音状态待核实');
    vm.phase = MeetingPhase.paused;
    expect(vm.inputStatus, '采音已暂停');
    vm.phase = MeetingPhase.ended;
    expect(vm.inputStatus, '未开始采音');
    await tester.pumpWidget(const SizedBox.shrink());
  });
  test('配置录音目录不会绕过腾讯云供应商选择；无客户端时拒绝静默降级', () async {
    final api = ApiClient(baseUrl: 'https://example.com/api/v1/');
    final directory = Directory('isolated-recording-directory');
    final recorder = createDeviceMeetingRecorder(
      directory: directory,
      apiClient: api,
      provider: 'tencent',
    );
    expect(recorder.directory, same(directory));
    final speech = recorder.recognizerFactory!('meeting-a');
    expect(speech, isA<TencentSpeechWorker>());
    await speech.close();
    expect(
      () => createDeviceMeetingRecorder(provider: 'tencent'),
      throwsStateError,
    );
    expect(
      () => createDeviceMeetingRecorder(provider: 'unsupported'),
      throwsStateError,
    );
    api.dio.close(force: true);
  });

  for (final route in ['/meeting?record=1', '/meeting?demo=1']) {
    testWidgets('真实入口 $route 不预填发言、补齐或风险', (tester) async {
      final recorder = FakeMeetingRecorder();
      await tester.pumpWidget(
        YanShuApp(
          initialLocation: route,
          profileRepository: ProfileRepository(MemoryProfileStore()),
          knowledgeRepository: KnowledgeRepository(
            MemoryKnowledgeStore(),
            seedExamples: true,
          ),
          meetingStore: MemoryMeetingStore(),
          meetingRecorder: recorder,
        ),
      );
      await tester.pumpAndSettle();
      final vm = tester
          .element(find.byKey(const ValueKey('meeting-finish')))
          .read<MeetingViewModel>();
      expect(find.byKey(const ValueKey('meeting-pause')), findsNothing);
      expect(find.text('结束并归档'), findsOneWidget);
      expect(recorder.starts, 1);
      expect(vm.record!.demo, isFalse);
      expect(vm.record!.utterances, isEmpty);
      expect(vm.record!.insights, isEmpty);
      expect(find.text('体验模拟会话'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('录音中点击原声回放不会暗中暂停会议', (tester) async {
    final recorder = FakeMeetingRecorder();
    await tester.pumpWidget(
      YanShuApp(
        initialLocation: '/meeting?record=1',
        profileRepository: ProfileRepository(MemoryProfileStore()),
        knowledgeRepository: KnowledgeRepository(MemoryKnowledgeStore()),
        meetingStore: MemoryMeetingStore(),
        meetingRecorder: recorder,
      ),
    );
    await tester.pumpAndSettle();
    final vm = tester
        .element(find.byKey(const ValueKey('meeting-finish')))
        .read<MeetingViewModel>();
    recorder.transcriptEvents.add(
      const MeetingTranscript(
        0,
        '这段话已经说完。',
        isFinal: true,
        audioStart: Duration.zero,
        audioEnd: Duration(seconds: 1),
      ),
    );
    await tester.pump();
    final key = ValueKey('play-utterance-${vm.record!.utterances.single.id}');
    await tester.ensureVisible(find.byKey(key));
    await tester.tap(find.byKey(key));
    await tester.pump();
    expect(recorder.pauses, 0);
    expect(vm.phase, MeetingPhase.recording);
    expect(find.text('会议正在持续录音，结束后可回放原声'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test('空仓储不注入演示目标、日程或资料', () async {
    expect((await EmptyProgressRepository().load()).goals, isEmpty);
    expect(await EmptyScheduleRepository().load(), isEmpty);
    final knowledge = await KnowledgeRepository(MemoryKnowledgeStore()).load();
    expect(knowledge.documents, isEmpty);
    expect(knowledge.projects.map((p) => p.id), ['personal']);
  });

  testWidgets('匿名说话人后续更正保留原话和映射履历，旧版本不覆盖', (tester) async {
    final recorder = FakeMeetingRecorder();
    await tester.pumpWidget(
      YanShuApp(
        initialLocation: '/meeting?record=1',
        profileRepository: ProfileRepository(MemoryProfileStore()),
        knowledgeRepository: KnowledgeRepository(MemoryKnowledgeStore()),
        meetingStore: MemoryMeetingStore(),
        meetingRecorder: recorder,
      ),
    );
    await tester.pumpAndSettle();
    final vm = tester
        .element(find.byKey(const ValueKey('meeting-finish')))
        .read<MeetingViewModel>();
    recorder.transcriptEvents.add(
      const MeetingTranscript(0, '验收稍后确认', isFinal: true),
    );
    recorder.transcriptEvents.add(
      const MeetingTranscript(
        0,
        '不得覆盖原文',
        isFinal: true,
        isSpeakerUpdate: true,
        speakerId: 'scope:0',
        speakerSeparated: true,
        speakerRevision: 1,
      ),
    );
    recorder.transcriptEvents.add(
      const MeetingTranscript(
        0,
        '旧映射',
        isFinal: true,
        isSpeakerUpdate: true,
        speakerId: 'scope:1',
        speakerSeparated: true,
        speakerRevision: 0,
      ),
    );
    expect(vm.record!.utterances.single.raw, '验收稍后确认');
    expect(vm.record!.utterances.single.speaker, '发言人 A');
    expect(vm.record!.utterances.single.speakerHistory.length, 2);
    expect(vm.record!.utterances.single.speakerRevision, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test('新结果不再支持的补齐必须清除，原话不变', () {
    final record = MeetingRecord(
      id: 'r',
      demo: false,
      startedAt: DateTime.now(),
      utterances: [
        const MeetingUtterance(
          id: 'u1',
          speaker: '发言人 A',
          raw: '验收先按',
          at: Duration.zero,
          repair: SpeechRepair(
            start: 4,
            end: 4,
            text: '周三确认',
            evidenceIds: ['u1', 'u2'],
          ),
        ),
        const MeetingUtterance(
          id: 'u2',
          speaker: '发言人 A',
          raw: '接着刚才验收，周三确认',
          at: Duration(seconds: 3),
        ),
      ],
    );
    final applied = applyMeetingAnalysis(record, {
      'insights': [],
      'repairs': [],
    });
    expect(applied.utterances.first.raw, record.utterances.first.raw);
    expect(applied.utterances.first.repair, isNull);
  });
}
