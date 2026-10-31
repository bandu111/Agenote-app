import 'dart:async';
import 'dart:io';
import 'package:yanshu/features/meeting/meeting_audio.dart';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:go_router/go_router.dart';
import 'package:yanshu/app/app.dart';
import 'package:yanshu/features/meeting/meeting_models.dart';
import 'package:yanshu/features/meeting/meeting_remote.dart';
import 'package:yanshu/features/meeting/meeting_demo.dart';
import 'package:yanshu/features/meeting/meeting_services.dart';
import 'package:yanshu/features/meeting/meeting_store.dart';
import 'package:yanshu/features/meeting/meeting_view_model.dart';
import 'package:yanshu/features/meeting/local_speech.dart';
import 'package:yanshu/features/knowledge/repositories/knowledge_repository.dart';
import 'package:yanshu/features/profile/repositories/profile_repository.dart';

class FakeMeetingRecorder implements MeetingRecorder {
  int starts = 0, pauses = 0, resumes = 0, stops = 0;
  bool deny = false;
  @override
  Stream<double> get levels => const Stream.empty();
  final transcriptEvents = StreamController<MeetingTranscript>.broadcast(
    sync: true,
  );
  @override
  Stream<MeetingTranscript> get transcripts => transcriptEvents.stream;
  @override
  Stream<String> get states => const Stream.empty();
  @override
  Future<String> start(String id) async {
    starts++;
    if (deny) throw StateError('denied');
    return '/private/$id.m4a';
  }

  @override
  Future<void> pause() async {
    pauses++;
  }

  @override
  Future<void> resume() async {
    resumes++;
  }

  @override
  Future<void> stop() async {
    stops++;
  }

  @override
  Future<void> dispose() async {}
}

/// 模拟原生录音器在启动完成前和停止时同步返回识别结果。
class BoundaryMeetingRecorder extends FakeMeetingRecorder {
  @override
  Future<String> start(String id) async {
    transcriptEvents.add(const MeetingTranscript(0, '验收我们先讨论', isFinal: true));
    return super.start(id);
  }

  @override
  Future<void> pause() async {
    transcriptEvents.add(
      const MeetingTranscript(1, '先说预算，验收稍后接着说', isFinal: true),
    );
    await super.pause();
  }

  @override
  Future<void> stop() async {
    transcriptEvents.add(
      const MeetingTranscript(2, '接着刚才验收，周三确认指标', isFinal: true),
    );
    await super.stop();
  }
}

class InputLossMeetingRecorder extends FakeMeetingRecorder {
  final inputStates = StreamController<String>.broadcast(sync: true);
  final inputLevels = StreamController<double>.broadcast(sync: true);
  @override
  Stream<String> get states => inputStates.stream;
  @override
  Stream<double> get levels => inputLevels.stream;
}

class FakeMeetingCalendar implements MeetingCalendar {
  int calls = 0;
  @override
  Future<bool> openEditor(String title, DateTime startsAt) async {
    calls++;
    return true;
  }
}

class PermissionWaitingRecorder extends FakeMeetingRecorder {
  final permission = Completer<void>();
  @override
  Future<String> start(String id) async {
    await permission.future;
    return super.start(id);
  }
}

Future<MeetingViewModel> openMeeting(
  WidgetTester tester, {
  FakeMeetingRecorder? recorder,
  FakeMeetingCalendar? calendar,
  MemoryMeetingStore? store,
}) async {
  await tester.pumpWidget(
    YanShuApp(
      initialLocation: '/meeting',
      profileRepository: ProfileRepository(MemoryProfileStore()),
      knowledgeRepository: KnowledgeRepository(
        MemoryKnowledgeStore(),
        seedExamples: true,
      ),
      meetingStore: store ?? MemoryMeetingStore(),
      meetingRecorder: recorder ?? FakeMeetingRecorder(),
      meetingCalendar: calendar ?? FakeMeetingCalendar(),
    ),
  );
  await tester.pumpAndSettle();
  return tester
      .element(find.byKey(const ValueKey('meeting-start-recording')))
      .read<MeetingViewModel>();
}

void main() {
  testWidgets(
    'home start-session entry never opens the previous meeting minutes',
    (tester) async {
      final vm = await openMeeting(tester);
      await vm.start(demo: false);
      final previous = vm.record!.id;
      await vm.finish();
      await tester.pumpAndSettle();
      GoRouter.of(tester.element(find.text('会议纪要'))).go('/home');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('connect-device')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('recording-source-phone')));
      await tester.pumpAndSettle();
      expect(find.text('会议纪要'), findsNothing);
      expect(vm.active, true);
      expect(vm.record!.id, isNot(previous));
      expect(find.byKey(const ValueKey('meeting-finish')), findsOneWidget);
      expect(find.text('会议纪要'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  for (final deviceStarting in [false, true]) {
    testWidgets(
      'new session keeps live page with previous ended record (device=$deviceStarting)',
      (tester) async {
        final recorder = PermissionWaitingRecorder();
        final vm = await openMeeting(tester, recorder: recorder);
        vm.record = MeetingRecord(
          id: 'previous',
          startedAt: DateTime(2026),
          demo: false,
          ended: true,
        );
        vm.phase = MeetingPhase.ended;
        final context = tester.element(
          find.byKey(const ValueKey('meeting-start-recording')),
        );
        final starting = deviceStarting ? vm.start(demo: false) : null;
        GoRouter.of(context).push('/meeting?record=1');
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.text('会议纪要'), findsNothing);
        expect(recorder.starts, 0);
        recorder.permission.complete();
        if (starting != null) await starting;
        await tester.pumpAndSettle();
        expect(vm.active, isTrue);
        expect(recorder.starts, 1);
        expect(vm.record!.id, isNot('previous'));
        expect(find.text('会议纪要'), findsNothing);
        await vm.finish();
        await tester.pumpAndSettle();
        expect(find.text('会议纪要'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
  testWidgets('独立风险推演拼图卡片显示在对应原话下，AI补充入口保持原交互', (tester) async {
    final vm = await openMeeting(tester);
    await vm.start(demo: false);
    await vm.addManual('发言人 A', 'Windows尚未批准，验收标准稍后接着说。');
    final original = vm.record!.utterances.single.id;
    vm.record = applyMeetingAnalysis(vm.record!, {
      'insights': [
        for (final entry in [
          ('risk', 'scope', '范围尚未批准'),
          ('prediction', 'forecast', '后续可能讨论交期'),
          ('stitch', 'memory', '验收话题接回'),
          ('question', 'inline', 'AI 补充'),
        ])
          {
            'id': entry.$2,
            'kind': entry.$1,
            'title': entry.$3,
            'body': '请核对对应原话。',
            'evidence_ids': [original],
          },
      ],
    });
    await vm.addManual('发言人 B', '继续讨论。');
    await tester.pumpAndSettle();
    final group = find.byKey(ValueKey('speech-turn-$original'));
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('meeting-insight-scope')),
      -200,
      scrollable: find
          .descendant(
            of: find.byKey(const PageStorageKey('meeting-transcript')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    final list = tester.widget<ListView>(
      find.byKey(const PageStorageKey('meeting-transcript')),
    );
    final topKeys = (list.childrenDelegate as SliverChildListDelegate).children
        .map((w) => w.key)
        .toList();
    for (final id in ['scope', 'forecast', 'memory']) {
      expect(
        topKeys,
        contains(ValueKey('meeting-insight-$id')),
        reason: '建议必须是独立列表卡片，不能藏在语音白色容器里',
      );
      expect(
        find.descendant(
          of: group,
          matching: find.byKey(ValueKey('meeting-insight-$id')),
        ),
        findsNothing,
      );
    }
    final transcriptScroll = find
        .descendant(
          of: find.byKey(const PageStorageKey('meeting-transcript')),
          matching: find.byType(Scrollable),
        )
        .first;
    final memoryCard = find.byKey(const ValueKey('meeting-insight-memory'));
    await tester.scrollUntilVisible(
      memoryCard,
      150,
      scrollable: transcriptScroll,
    );
    expect(
      find.descendant(
        of: memoryCard,
        matching: find.textContaining(RegExp(r'\d{2}:\d{2} · 发言人 A')),
      ),
      findsOneWidget,
      reason: '话题接回/拼图卡片保留关联时间与发言人',
    );
    final riskCard = find.byKey(const ValueKey('meeting-insight-scope'));
    await tester.scrollUntilVisible(
      riskCard,
      -150,
      scrollable: transcriptScroll,
    );
    expect(
      find.descendant(
        of: riskCard,
        matching: find.textContaining(RegExp(r'\d{2}:\d{2} · 发言人 A')),
      ),
      findsNothing,
      reason: '其他独立建议仍不显示时间与发言人',
    );
    expect(
      find.byKey(const ValueKey('meeting-insight-inline')),
      findsNothing,
      reason: '补充仍默认收起',
    );
    final button = find.byKey(ValueKey('ai-context-$original'));
    await tester.scrollUntilVisible(
      button,
      -200,
      scrollable: find
          .descendant(
            of: find.byKey(const PageStorageKey('meeting-transcript')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.ensureVisible(button);
    await tester.pumpAndSettle();
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('meeting-insight-inline')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
  testWidgets('同轮ASR片段显示为一段文字、一个播放条和上下文入口，底层证据保留', (tester) async {
    final vm = await openMeeting(tester);
    await vm.start(demo: false);
    final events = (vm.recorder as FakeMeetingRecorder).transcriptEvents;
    events.add(const MeetingTranscript(0, '今天会议主要讨论三个事情。', isFinal: true));
    await tester.pump(const Duration(seconds: 3));
    events.add(const MeetingTranscript(1, '第一个是试点运行的情况。', isFinal: true));
    await tester.pumpAndSettle();
    final sources = vm.record!.utterances;
    expect(sources.map((u) => u.turnId).toSet(), hasLength(1));
    final group = find.byKey(ValueKey('speech-turn-${sources.first.id}'));
    expect(group, findsOneWidget);
    for (final source in sources.take(1)) {
      expect(
        find.descendant(
          of: group,
          matching: find.byKey(ValueKey('utterance-${source.id}')),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: group,
          matching: find.byKey(ValueKey('utterance-audio-${source.id}')),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(ValueKey('utterance-${source.id}')),
          matching: find.text('展开上下文 ›'),
        ),
        findsOneWidget,
      );
    }
    expect(sources, hasLength(2));
    expect(
      find.descendant(
        of: group,
        matching: find.text(sources.map((s) => s.display).join('')),
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(ValueKey('utterance-audio-${sources.last.id}')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });
  testWidgets('AI提示固定在各自发言下方，新发言和新增证据不移动已有提示', (tester) async {
    final vm = await openMeeting(tester);
    await vm.start(demo: false);
    await vm.addManual('发言人 A', '桌面端还没有批准。');
    final first = vm.record!.utterances.first.id;
    void update(String id, List<String> evidence, String body) {
      vm.record = applyMeetingAnalysis(vm.record!, {
        'insights': [
          {
            'id': id,
            'kind': 'question',
            'title': 'AI 补充',
            'body': body,
            'evidence_ids': evidence,
            'streaming': true,
          },
        ],
      }, preserveInferences: true);
    }

    update('first-hint', [first], '建议');
    await vm.addManual('发言人 B', '接下来确认预算。');
    final second = vm.record!.utterances.last.id;
    update('first-hint', [first, second], '建议确认交付范围');
    update('second-hint', [second], '建议确认预算');
    // 流式补充有持续动画，使用有界帧推进，不等待动画完全停止。
    // 通过正常发言事件通知页面，模拟模型流到达期间又有人继续说话。
    await vm.addManual('发言人 C', '继续讨论。');
    await tester.pump(const Duration(milliseconds: 300));
    final stream = tester.widget<ListView>(
      find.byKey(const PageStorageKey('meeting-transcript')),
    );
    final keys = (stream.childrenDelegate as SliverChildListDelegate).children
        .map((w) => w.key)
        .toList();
    expect(
      keys.where((k) => k.toString().contains('meeting-insight-')),
      isEmpty,
    );
    final transcript = find.byKey(const PageStorageKey('meeting-transcript'));
    Future<void> openSuggestion(String source, String hint, double step) async {
      final button = find.byKey(ValueKey('ai-context-$source'));
      await tester.scrollUntilVisible(
        button,
        step,
        scrollable: find
            .descendant(of: transcript, matching: find.byType(Scrollable))
            .first,
      );
      await tester.ensureVisible(button);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(button);
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        find.descendant(
          of: find.byKey(ValueKey('utterance-$source')),
          matching: find.byKey(ValueKey('meeting-insight-$hint')),
        ),
        findsOneWidget,
      );
    }

    await openSuggestion(first, 'first-hint', -200);
    await openSuggestion(second, 'second-hint', 200);
    final saved = MeetingRecord.fromJson(vm.record!.toJson());
    expect(saved.insights.first.anchorId, first);
    expect(saved.insights.last.anchorId, second);
    expect(tester.takeException(), isNull);
  });
  testWidgets('补句在同一原文位置增长，光标保留，未等待完整文字', (tester) async {
    final vm = await openMeeting(tester);
    await vm.start(demo: false);
    await vm.addManual('发言人 A', '现在确认……');
    final id = vm.record!.utterances.first.id;
    Future<void> update(String text) async {
      vm.record = vm.record!.copy(
        utterances: [
          vm.record!.utterances.first.revise(
            repair: SpeechRepair(start: 4, end: 6, text: text, streaming: true),
          ),
        ],
      );
      await vm.addManual('发言人 B', '继续讨论。');
    }

    await update('功能');
    await tester.pump();
    final original = find.byKey(ValueKey('repair-text-$id'));
    expect(original, findsOneWidget);
    expect(
      tester.widget<Text>(original).textSpan!.toPlainText(),
      contains('现在确认'),
    );
    expect(
      tester.widget<Text>(original).textSpan!.toPlainText(),
      contains('功能'),
    );
    expect(find.text('建议补充中 · 未确认'), findsOneWidget);
    expect(find.byKey(ValueKey('repair-cursor-$id')), findsOneWidget);
    await update('功能清单');
    await tester.pump();
    expect(
      tester.widget<Text>(original).textSpan!.toPlainText(),
      contains('功能清单'),
    );
    expect(vm.record!.utterances.first.raw, '现在确认……');
    expect(tester.takeException(), isNull);
  });
  testWidgets('结束后自动进入会议纪要，短会议保留逐字稿而不生成纪要', (tester) async {
    final vm = await openMeeting(tester);
    await vm.start(demo: false);
    await vm.addManual('发言人 A', '会议结束。');
    await vm.finish();
    await tester.pumpAndSettle();
    expect(find.text('会议纪要'), findsOneWidget);
    expect(find.textContaining('会议不足 1 分钟'), findsOneWidget);
    expect(vm.record!.documentId, isNull);
    expect(find.byKey(const ValueKey('meeting-ended-panel')), findsNothing);
    expect(find.textContaining('原始录音 1'), findsNothing);
    expect(find.text('开始真实会话'), findsNothing);
    await tester.tap(find.text('逐字稿'));
    await tester.pumpAndSettle();
    expect(find.text('会议结束。'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('变更显示旧原话红色删除线及新内容，未审批不撤回原文', (tester) async {
    final vm = await openMeeting(tester);
    await vm.start(demo: false);
    await vm.addManual('发言人 A', '周三提交评估报告。');
    final old = vm.record!.utterances.first;
    await vm.addManual('发言人 A', '评估报告改为周五提交。');
    final replacement = vm.record!.utterances.last;
    vm.record = vm.record!.copy(
      sourceChanges: [
        {
          'target_id': old.id,
          'replacement_id': replacement.id,
          'status': 'pending',
          'operation': 'replace',
          'new_text': replacement.raw,
        },
      ],
    );
    await vm.pause();
    await tester.pumpAndSettle();
    expect(find.byKey(ValueKey('source-change-${old.id}')), findsOneWidget);
    expect(find.text('变更待确认 · 原任务保持不变'), findsOneWidget);
    final previous = tester.widget<Text>(find.text(old.raw));
    expect(previous.style!.decoration, TextDecoration.lineThrough);
    expect(vm.record!.utterances.first.withdrawn, isFalse);
    expect(vm.record!.utterances.first.raw, old.raw);
  });

  test(
    'utterance replay extracts its original samples and rejects unavailable ranges',
    () async {
      final folder = await Directory.systemTemp.createTemp(
        'meeting-audio-test-',
      );
      addTearDown(() => folder.delete(recursive: true));
      final pcm = Uint8List(32000);
      final data = ByteData.sublistView(pcm);
      for (var i = 0; i < 16000; i++) {
        data.setInt16(i * 2, i, Endian.little);
      }
      final original = File('${folder.path}/source.wav');
      final source = Uint8List.fromList([
        ...meetingWavHeader(pcm.length),
        ...pcm,
      ]);
      await original.writeAsBytes(source);
      final clip = File('${folder.path}/clip.wav');
      await writeMeetingAudioClip(
        original,
        clip,
        const Duration(milliseconds: 250),
        const Duration(milliseconds: 750),
      );
      final bytes = await clip.readAsBytes();
      expect(bytes.length, 44 + 16000);
      expect(ByteData.sublistView(bytes).getInt16(44, Endian.little), 4000);
      expect(
        ByteData.sublistView(bytes).getInt16(bytes.length - 2, Endian.little),
        11999,
      );
      expect(await original.readAsBytes(), source);
      await expectLater(
        writeMeetingAudioClip(
          original,
          clip,
          Duration.zero,
          const Duration(seconds: 2),
        ),
        throwsStateError,
      );
      final utterance = MeetingUtterance(
        id: 'voice',
        speaker: '我',
        raw: '原声',
        at: Duration.zero,
        audioPath: original.path,
        audioStart: const Duration(milliseconds: 250),
        audioEnd: const Duration(milliseconds: 750),
      );
      final restored = MeetingUtterance.fromJson(
        utterance.revise(correction: '更正后的文字').toJson(),
      );
      expect(restored.hasAudio, isTrue);
      expect(restored.audioPath, original.path);
      expect(restored.audioStart, const Duration(milliseconds: 250));
      expect(restored.audioEnd, const Duration(milliseconds: 750));
    },
  );

  test(
    'inline repairs persist as anchored suggestions while originals and manual corrections remain independent',
    () {
      final original = meetingDemoUtterance(
        6,
        const Duration(minutes: 1),
        availableThrough: 12,
      );
      final restored = MeetingUtterance.fromJson(original.toJson());
      final repair = restored.repair!;
      expect(repair.validFor(restored.raw), isTrue);
      expect(restored.raw.substring(0, repair.start), '验收就按');
      expect(restored.raw.substring(repair.start, repair.end), '……');
      expect(restored.raw, isNot(contains(repair.text)));
      expect(repair.evidenceIds, ['demo-7', 'demo-9']);
      final corrected = restored.revise(correction: '需要双方再确认验收标准');
      expect(corrected.raw, original.raw);
      expect(corrected.display, '需要双方再确认验收标准');
    },
  );
  test('WAV header describes the exact PCM stream sent to recognition', () {
    final header = ByteData.sublistView(meetingWavHeader(32000));
    expect(header.getUint32(4, Endian.little), 32036);
    expect(header.getUint16(22, Endian.little), 1);
    expect(header.getUint32(24, Endian.little), 16000);
    expect(header.getUint16(34, Endian.little), 16);
    expect(header.getUint32(40, Endian.little), 32000);
  });

  testWidgets('设备断连保留原话并暂停，继续时重新打开设备而不是假装仍在采音', (tester) async {
    final recorder = InputLossMeetingRecorder();
    final vm = await openMeeting(tester, recorder: recorder);
    await vm.start(demo: false);
    recorder.transcriptEvents.add(
      const MeetingTranscript(0, '原计划不取消', isFinal: true),
    );
    recorder.inputStates.add('input_lost');
    await tester.pumpAndSettle();
    expect(vm.phase, MeetingPhase.paused);
    expect(vm.error, contains('采音设备'));
    expect(vm.record!.utterances.single.raw, '原计划不取消');
    // 取消原生事件流订阅使用真实异步队列，不用虚拟动画时钟等待。
    await tester.runAsync(() => vm.resume());
    await tester.pump();
    expect(vm.phase, MeetingPhase.recording);
    expect(recorder.starts, 2);
    expect(recorder.resumes, 0);
    expect(vm.record!.utterances.single.raw, '原计划不取消');
    await tester.pumpWidget(const SizedBox.shrink());
    unawaited(recorder.inputStates.close());
    unawaited(recorder.inputLevels.close());
    await tester.pump();
  });

  testWidgets(
    'phone speech partials update in place and final results commit once to the semantic stream',
    (tester) async {
      final recorder = FakeMeetingRecorder();
      final vm = await openMeeting(tester, recorder: recorder);
      await vm.start(demo: false);
      recorder.transcriptEvents.add(
        const MeetingTranscript(0, '今天', isFinal: false),
      );
      await tester.pumpAndSettle();
      expect(vm.partial, '今天');
      expect(vm.record!.utterances, isEmpty);
      recorder.transcriptEvents.add(
        const MeetingTranscript(0, '今天确认交付范围', isFinal: false),
      );
      await tester.pumpAndSettle();
      expect(vm.partial, '今天确认交付范围');
      expect(vm.record!.utterances, isEmpty);
      recorder.transcriptEvents.add(
        const MeetingTranscript(
          0,
          '今天确认交付范围',
          isFinal: true,
          audioStart: Duration.zero,
          audioEnd: Duration(seconds: 3),
        ),
      );
      recorder.transcriptEvents.add(
        const MeetingTranscript(
          0,
          '今天确认交付范围',
          isFinal: true,
          audioStart: Duration.zero,
          audioEnd: Duration(seconds: 3),
        ),
      );
      await tester.pumpAndSettle();
      expect(vm.partial, isEmpty);
      expect(vm.record!.utterances.length, 1);
      expect(vm.record!.utterances.single.raw, '今天确认交付范围');
      expect(vm.record!.utterances.single.manual, isFalse);
      expect(vm.record!.utterances.single.hasAudio, isTrue);
      expect(
        vm.record!.utterances.single.audioPath,
        vm.record!.audioPaths.single,
      );
      expect(vm.record!.utterances.single.audioEnd, const Duration(seconds: 3));
      expect(find.byTooltip('补录文字'), findsNothing);
      expect(
        find.byKey(
          ValueKey('utterance-audio-${vm.record!.utterances.single.id}'),
        ),
        findsOneWidget,
      );
      expect(vm.record!.demo, isFalse);
      expect(vm.record!.insights, isEmpty);
      await vm.finish();
      expect(vm.minutes(), contains('今天确认交付范围'));
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('碎片采集保留启动首句、暂停前中断句和结束尾句', (tester) async {
    final recorder = BoundaryMeetingRecorder();
    final vm = await openMeeting(tester, recorder: recorder);
    await vm.start(demo: false);
    expect(vm.record!.utterances.single.raw, '验收我们先讨论');
    await vm.pause();
    expect(vm.record!.utterances.length, 2);
    await vm.resume();
    await vm.finish();
    expect(vm.record!.utterances.map((item) => item.raw).toList(), [
      '验收我们先讨论',
      '先说预算，验收稍后接着说',
      '接着刚才验收，周三确认指标',
    ]);
    expect(vm.minutes(), contains('接着刚才验收，周三确认指标'));
    expect(recorder.starts, 1);
    expect(recorder.resumes, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'sign-out cancels a pending microphone grant before a recording session becomes active',
    (tester) async {
      final recorder = PermissionWaitingRecorder();
      final vm = await openMeeting(tester, recorder: recorder);
      final start = vm.start(demo: false);
      await vm.suspendForLogout();
      recorder.permission.complete();
      await start;
      expect(vm.active, isFalse);
      expect(vm.record, isNull);
      expect(recorder.stops, 1);
      expect(tester.takeException(), isNull);
    },
  );
  test(
    'display cleanup removes disfluencies without deleting dates or changing the original',
    () {
      const raw = '嗯，这个这个我们我们 2026-10-20 14:00 先评估一下，不是批准。';
      expect(tidySpeech(raw), '这个我们 2026-10-20 14:00 先评估一下，不是批准。');
      expect(raw, startsWith('嗯，这个这个'));
    },
  );
  test('explicit dates reject ambiguous, past and invalid appointments', () {
    final now = DateTime(2026, 10, 18);
    expect(
      explicitMeetingDate('2026-10-20 14:00 对齐', now),
      DateTime(2026, 10, 20, 14),
    );
    expect(explicitMeetingDate('2026-02-31 14:00', now), isNull);
    expect(explicitMeetingDate('2026-10-20 25:00', now), isNull);
    expect(explicitMeetingDate('明天下午聊聊', now), isNull);
    expect(explicitMeetingDate('2026-10-17 14:00', now), isNull);
  });

  testWidgets(
    'recording permission, pause, manual originals, explicit consent and archive are separate',
    (tester) async {
      final recorder = FakeMeetingRecorder(), calendar = FakeMeetingCalendar();
      final store = MemoryMeetingStore();
      final vm = await openMeeting(
        tester,
        recorder: recorder,
        calendar: calendar,
        store: store,
      );
      recorder.deny = true;
      await vm.start(demo: false);
      await tester.pumpAndSettle();
      expect(vm.phase, MeetingPhase.ready);
      expect(vm.error, isNotNull);
      recorder.deny = false;
      await vm.start(demo: false);
      await tester.pumpAndSettle();
      expect(vm.record!.audioPaths.length, 1);
      await vm.pause();
      await vm.resume();
      expect(recorder.pauses, 1);
      expect(recorder.resumes, 1);
      final year = DateTime.now().year + 1;
      await vm.addManual('项目负责人', '$year-10-20 14:00 项目对齐');
      expect(calendar.calls, 0);
      final notice = vm.notifications.items.firstWhere(
        (n) => n.id.startsWith('meeting-calendar:'),
      );
      await vm.notifications.decide(notice.id, allow: true);
      expect(calendar.calls, 1);
      final original = vm.record!.utterances.single.raw;
      await vm.correct(vm.record!.utterances.single.id, '更正后的表述');
      await vm.retract(vm.record!.utterances.single.id);
      expect(vm.record!.utterances.single.raw, original);
      expect(vm.record!.utterances.single.withdrawn, isTrue);
      expect(await vm.finish(), isTrue);
      expect(recorder.stops, 1);
      expect(vm.record!.documentId, isNull);
      // A short recording stays in history; a qualifying duration permits archival.
      await store.save(vm.record!.copy(elapsed: const Duration(minutes: 1)));
      await vm.open(vm.record!.id);
      expect(await vm.finish(), isTrue);
      final docId = vm.record!.documentId!;
      final doc = vm.knowledge.document(docId)!;
      expect(doc.archived, isTrue);
      expect(doc.allowed, isTrue);
      expect(doc.selected.content, contains(original));
      expect(doc.selected.content, contains('~~更正后的表述~~'));
      expect(await vm.finish(), isTrue);
      expect(vm.knowledge.data.documents.where((d) => d.id == docId).length, 1);
      expect(store.records[vm.record!.id]!.ended, isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'demo streams findings and stitches without microphone access or replacing originals',
    (tester) async {
      final recorder = FakeMeetingRecorder();
      final vm = await openMeeting(tester, recorder: recorder);
      await vm.start(demo: true);
      await tester.pump();
      await tester.pump(const Duration(seconds: 25));
      await tester.pumpAndSettle();
      expect(recorder.starts, 0);
      expect(vm.record!.utterances.length, 16);
      expect(
        vm.record!.insights.any((i) => i.kind == InsightKind.stitch),
        isTrue,
      );
      expect(vm.record!.insights.every((i) => i.inference), isTrue);
      expect(vm.record!.utterances[3].withdrawn, isTrue);
      vm.notifications.dismissPrompt();
      await vm.pause();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('meeting-tab-0')), findsNothing);
      expect(find.byKey(const ValueKey('meeting-tab-1')), findsNothing);
      final transcript = find.byKey(const PageStorageKey('meeting-transcript'));
      final stream = tester.widget<ListView>(transcript);
      final items =
          (stream.childrenDelegate as SliverChildListDelegate).children;
      final keys = items.map((item) => item.key).toList();
      expect(
        keys.where((key) => key.toString().contains('meeting-insight-')),
        hasLength(3),
      );
      final clarification = vm.record!.insights.firstWhere(
        (i) => i.id == 'clarify',
      );
      final contextButton = find.byKey(
        ValueKey('ai-context-${clarification.evidenceIds.last}'),
      );
      await tester.scrollUntilVisible(
        contextButton,
        -250,
        scrollable: find.descendant(
          of: transcript,
          matching: find.byType(Scrollable),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(contextButton);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('meeting-insight-clarify')),
        findsOneWidget,
      );
      expect(find.textContaining('Windows 是否纳入一期'), findsWidgets);
      expect(await vm.finish(), isTrue);
      expect(vm.knowledge.document(vm.record!.documentId!)!.demo, isTrue);
      expect(vm.minutes(), contains('演示场景'));
      expect(tester.takeException(), isNull);
    },
  );

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    testWidgets(
      'meeting fits narrow large text on $platform',
      (tester) async {
        tester.view.physicalSize = const Size(320, 640);
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.textScaleFactorTestValue = 2;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        final vm = await openMeeting(tester);
        await vm.start(demo: true);
        await tester.pump();
        await tester.pump(const Duration(seconds: 25));
        await vm.pause();
        vm.notifications.dismissPrompt();
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('meeting-tab-0')), findsNothing);
        expect(find.byKey(const ValueKey('meeting-tab-1')), findsNothing);
        final repaired = find.byKey(const ValueKey('repair-text-demo-7'));
        await tester.scrollUntilVisible(
          repaired,
          -250,
          scrollable: find.descendant(
            of: find.byKey(const PageStorageKey('meeting-transcript')),
            matching: find.byType(Scrollable),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('repair-cursor-demo-7')),
          findsOneWidget,
        );
        expect(
          tester.widget<Text>(repaired).textSpan!.toPlainText(),
          contains('双方确认的功能清单和测试通过率'),
        );
        expect(
          find.byKey(const ValueKey('utterance-audio-demo-7')),
          findsOneWidget,
        );
        expect(
          tester
              .widget<IconButton>(
                find.byKey(const ValueKey('play-utterance-demo-7')),
              )
              .onPressed,
          isNull,
        );
        expect(find.byTooltip('补录文字'), findsNothing);
        expect(vm.record!.utterances[6].raw, contains('……'));
        expect(vm.record!.utterances[6].raw, isNot(contains('双方确认的功能清单')));
        expect(tester.takeException(), isNull);
        await vm.finish();
      },
      variant: TargetPlatformVariant({platform}),
    );
  }
}
