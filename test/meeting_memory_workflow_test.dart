import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yanshu/features/meeting/meeting_models.dart';
import 'package:yanshu/features/meeting/meeting_memory_workflow.dart';
import 'package:yanshu/features/meeting/meeting_remote.dart';
import 'package:yanshu/features/meeting/meeting_store.dart';
import 'package:yanshu/features/meeting/local_speech.dart';
import 'meeting_remote_test.dart' show FakeMeetingRemote, createMeeting;
import 'meeting_test.dart' show FakeMeetingRecorder, openMeeting;

class MemoryHintRemote extends FakeMeetingRemote
    implements LiveMeetingAnalysis {
  final prefix = Completer<void>();
  final finish = Completer<void>();
  @override
  Future<void> liveHints(
    MeetingRecord record,
    void Function(Map<String, dynamic>) onUpdate,
  ) async {
    final target = record.utterances.first;
    void frame(String text, bool streaming) => onUpdate({
      'event': streaming ? 'preview' : 'done',
      'insights': [],
      'repairs': [],
      'inferred_completions': [
        {
          'target_id': target.id,
          'start': target.raw.length,
          'end': target.raw.length,
          'text': text,
          'inferred': true,
          'streaming': streaming,
          'evidence_ids': [target.id],
        },
      ],
    });
    frame('双方', true);
    if (!prefix.isCompleted) prefix.complete();
    await finish.future;
    frame('双方确认的时间。', false);
  }
}

void main() {
  testWidgets('推测半句直接显示在原句断点后，淡色文字和光标复用原组件，无独立等待卡', (tester) async {
    final recorder = FakeMeetingRecorder();
    final vm = await openMeeting(tester, recorder: recorder);
    await vm.start(demo: false);
    recorder.transcriptEvents.add(
      const MeetingTranscript(
        0,
        '验收就按',
        isFinal: true,
        speakerId: 'scope:a',
        speakerSeparated: true,
      ),
    );
    recorder.transcriptEvents.add(
      const MeetingTranscript(
        1,
        '先谈预算。',
        isFinal: true,
        speakerId: 'scope:b',
        speakerSeparated: true,
      ),
    );
    final id = vm.record!.utterances.first.id;
    for (final text in ['双方', '双方确认的功能清单。']) {
      vm.record = applyMeetingAnalysis(vm.record!, {
        'inferred_completions': [
          {
            'target_id': id,
            'start': 4,
            'end': 4,
            'text': text,
            'inferred': true,
            'streaming': true,
            'evidence_ids': [id],
          },
        ],
      }, preserveInferences: true);
      await vm.addManual('发言人 B', '继续讨论预算。');
      await tester.pump();
      final rendered = tester.widget<Text>(
        find.byKey(ValueKey('repair-text-$id')),
      );
      expect(rendered.textSpan!.toPlainText(), contains(text));
      final span = (rendered.textSpan as TextSpan).children![2] as TextSpan;
      expect(span.style!.color, const Color(0xFF7A7E87));
      expect(find.byKey(ValueKey('repair-cursor-$id')), findsOneWidget);
      expect(find.text('记忆拼图 · 等待接回'), findsNothing);
      expect(vm.record!.utterances.first.raw, '验收就按');
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('A中断后直接流式续写原句，B继续时锚点不动，无新卡片且不等待完整分析', (tester) async {
    final remote = MemoryHintRemote();
    final full = Completer<Map<String, dynamic>>();
    remote.pending = full;
    final recorder = FakeMeetingRecorder();
    final vm = await createMeeting(
      remote,
      MemoryMeetingStore(),
      recorder: recorder,
      disposeViewModel: false,
    );
    await vm.start(demo: false);
    recorder.transcriptEvents.add(
      const MeetingTranscript(
        0,
        '交付时间定在',
        isFinal: true,
        speakerId: 'scope:a',
        speakerSeparated: true,
      ),
    );
    recorder.transcriptEvents.add(
      const MeetingTranscript(
        1,
        '先谈预算，预算保持原约定。',
        isFinal: true,
        speakerId: 'scope:b',
        speakerSeparated: true,
      ),
    );
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    expect(remote.prefix.isCompleted, isTrue);
    final originalId = vm.record!.utterances.first.id;
    final first = vm.record!.utterances.first;
    expect(first.repair!.text, '双方');
    expect(first.repair!.inferred, isTrue);
    expect(first.repair!.streaming, isTrue);
    expect(first.repair!.evidenceIds, [originalId]);
    expect(vm.record!.utterances.last.repair, isNull);
    expect(vm.record!.insights, isEmpty);
    expect(full.isCompleted, isFalse);
    remote.finish.complete();
    await tester.pump();
    final completed = vm.record!.utterances.first;
    expect(completed.id, originalId);
    expect(completed.raw, '交付时间定在');
    expect(completed.repair!.text, '双方确认的时间。');
    expect(completed.repair!.streaming, isFalse);
    expect(vm.record!.insights, isEmpty);
    expect(recorder.pauses, 0);
    vm.dispose();
    full.complete({'insights': [], 'repairs': []});
    await tester.pump();
  });

  test('清除误加的独立等待卡，保留行内推测及其持久化标记，真实后文优先', () {
    const source = MeetingUtterance(
      id: 'a',
      speaker: '发言人A',
      raw: '交期定在',
      at: Duration.zero,
      turnStatus: 'interrupted',
      speakerId: 'a',
      speakerSeparated: true,
    );
    final record = MeetingRecord(
      id: 'm',
      demo: false,
      startedAt: DateTime(2026),
      utterances: [source],
      insights: const [
        MeetingInsight(
          id: 'old',
          kind: InsightKind.stitch,
          title: '记忆拼图 · 等待接回',
          body: '等待',
          evidenceIds: ['a'],
          issueKey: 'memory-workflow-v1',
        ),
      ],
    );
    final inline = applyMeetingAnalysis(projectMemoryWorkflow(record), {
      'inferred_completions': [
        {
          'target_id': 'a',
          'start': 4,
          'end': 4,
          'text': '双方确认的时间',
          'inferred': true,
          'evidence_ids': ['a'],
        },
      ],
    }, preserveInferences: true);
    expect(inline.insights, isEmpty);
    expect(inline.utterances.single.repair!.inferred, isTrue);
    expect(
      MeetingRecord.fromJson(
        inline.toJson(),
      ).utterances.single.repair!.inferred,
      isTrue,
    );
    final verified = applyMeetingAnalysis(inline, {
      'repairs': [
        {
          'target_id': 'a',
          'start': 4,
          'end': 4,
          'text': '周三',
          'evidence_ids': ['a'],
        },
      ],
    }, preserveInferences: true);
    expect(verified.utterances.single.repair!.inferred, isFalse);
    final late = applyMeetingAnalysis(verified, {
      'inferred_completions': [
        {
          'target_id': 'a',
          'start': 4,
          'end': 4,
          'text': '旧推测',
          'inferred': true,
          'evidence_ids': ['a'],
        },
      ],
    }, preserveInferences: true);
    expect(late.utterances.single.repair!.text, '周三');
    expect(late.utterances.single.raw, source.raw);
  });
}
