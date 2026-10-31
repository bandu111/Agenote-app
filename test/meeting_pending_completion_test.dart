import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:yanshu/app/app.dart';
import 'package:yanshu/features/knowledge/repositories/knowledge_repository.dart';
import 'package:yanshu/features/profile/repositories/profile_repository.dart';
import 'package:yanshu/features/meeting/meeting_store.dart';
import 'package:yanshu/features/meeting/meeting_models.dart';
import 'package:yanshu/features/meeting/meeting_view_model.dart';
import 'package:yanshu/features/meeting/local_speech.dart';
import 'package:yanshu/features/meeting/speech_turn.dart';
import 'meeting_test.dart' show FakeMeetingRecorder;
import 'meeting_remote_test.dart' show FakeMeetingRemote, createMeeting;

void main() {
  testWidgets('A被打断后立即在原段显示待补全，B继续说也不移走，不等待AI或暂停', (tester) async {
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
        '我们先核对交期。',
        isFinal: true,
        speakerId: 'scope:0',
        speakerSeparated: true,
        audioStart: Duration.zero,
        audioEnd: Duration(seconds: 1),
      ),
    );
    recorder.transcriptEvents.add(
      const MeetingTranscript(
        1,
        '交付时间我们定在',
        isFinal: true,
        speakerId: 'scope:0',
        speakerSeparated: true,
        audioStart: Duration(seconds: 1),
        audioEnd: Duration(seconds: 2),
      ),
    );
    recorder.transcriptEvents.add(
      const MeetingTranscript(
        2,
        '先确认预算',
        isFinal: false,
        speakerId: 'scope:1',
        speakerSeparated: true,
        audioStart: Duration(seconds: 2),
        audioEnd: Duration(seconds: 3),
      ),
    );
    await tester.pump();
    expect(find.text('待补全 · 发言尚未完成'), findsOneWidget);
    expect(find.text('记忆拼图 · 等待接回'), findsNothing);
    final first = vm.record!.utterances.first;
    expect(
      find.byKey(ValueKey('pending-completion-${first.id}')),
      findsOneWidget,
    );
    expect(vm.record!.utterances.last.turnStatus, 'interrupted');
    expect(vm.record!.utterances.every((u) => u.repair == null), isTrue);
    recorder.transcriptEvents.add(
      const MeetingTranscript(
        2,
        '先确认预算，预算保持原约定。',
        isFinal: true,
        speakerId: 'scope:1',
        speakerSeparated: true,
        audioStart: Duration(seconds: 2),
        audioEnd: Duration(seconds: 4),
      ),
    );
    await tester.pump();
    expect(find.text('待补全 · 发言尚未完成'), findsOneWidget);
    expect(find.text('记忆拼图 · 等待接回'), findsNothing);
    expect(pendingSpeechCompletionIds(vm.record!.utterances), {
      vm.record!.utterances[1].id,
    });
    expect(recorder.pauses, 0);
    expect(recorder.stops, 0);
    // 人工补正该缺口后状态立即消失，原录音与原话不覆盖。
    await vm.correct(vm.record!.utterances[1].id, '交付时间我们定在下周三。');
    await tester.pump();
    expect(find.text('待补全 · 发言尚未完成'), findsNothing);
    expect(vm.record!.utterances[1].raw, '交付时间我们定在');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('完整A后出现未知身份的B中间字幕，不误标A待补全', (tester) async {
    final recorder = FakeMeetingRecorder();
    final vm = await createMeeting(
      FakeMeetingRemote(),
      MemoryMeetingStore(),
      recorder: recorder,
      disposeViewModel: false,
    );
    await vm.start(demo: false);
    recorder.transcriptEvents.add(
      const MeetingTranscript(
        0,
        '今天先核对原合同范围。',
        isFinal: true,
        speakerId: 'scope:0',
        speakerSeparated: true,
      ),
    );
    recorder.transcriptEvents.add(
      const MeetingTranscript(1, '我接着说预算', isFinal: false),
    );
    recorder.transcriptEvents.add(
      const MeetingTranscript(
        1,
        '我接着说预算，预算维持原约定。',
        isFinal: true,
        speakerId: 'scope:1',
        speakerSeparated: true,
      ),
    );
    await tester.pump();
    expect(vm.record!.utterances.first.turnStatus, 'complete');
    expect(pendingSpeechCompletionIds(vm.record!.utterances), isEmpty);
    vm.dispose();
  });

  testWidgets('A以破折号或省略号断句后B接话，A标为被打断并显示待补全', (tester) async {
    for (final cut in ['上线前必须先——', '上线前必须先...', '上线前必须先—。']) {
      final recorder = FakeMeetingRecorder();
      final vm = await createMeeting(
        FakeMeetingRemote(),
        MemoryMeetingStore(),
        recorder: recorder,
        disposeViewModel: false,
      );
      await vm.start(demo: false);
      recorder.transcriptEvents.add(
        MeetingTranscript(
          0,
          cut,
          isFinal: true,
          speakerId: 'scope:0',
          speakerSeparated: true,
        ),
      );
      recorder.transcriptEvents.add(
        const MeetingTranscript(
          1,
          '客户还没确认。',
          isFinal: true,
          speakerId: 'scope:1',
          speakerSeparated: true,
        ),
      );
      await tester.pump();
      final a = vm.record!.utterances.first;
      expect(a.raw, cut, reason: cut);
      expect(a.turnStatus, 'interrupted', reason: cut);
      expect(pendingSpeechCompletionIds(vm.record!.utterances), {
        a.id,
      }, reason: cut);
      vm.dispose();
    }
  });

  test('待补状态从证据恢复；有合法补齐、纠错或撤回时不继续显示', () {
    MeetingUtterance source(
      String id, {
      String status = 'interrupted',
      SpeechRepair? repair,
      bool withdrawn = false,
      String? correction,
    }) => MeetingUtterance(
      id: id,
      speaker: '发言人 A',
      speakerId: 'scope:0',
      speakerSeparated: true,
      raw: '交期定在',
      at: Duration.zero,
      turnId: 'a-turn',
      turnStatus: status,
      repair: repair,
      withdrawn: withdrawn,
      correction: correction,
    );
    final original = [source('a'), source('tail')];
    final restored = original
        .map((u) => MeetingUtterance.fromJson(u.toJson()))
        .toList();
    expect(pendingSpeechCompletionIds(restored), {'tail'});
    expect(
      pendingSpeechCompletionIds([source('tail', withdrawn: true)]),
      isEmpty,
    );
    expect(
      pendingSpeechCompletionIds([source('tail', correction: '交期另行确定。')]),
      isEmpty,
    );
    expect(
      pendingSpeechCompletionIds([source('tail', status: 'complete')]),
      isEmpty,
    );
    expect(
      pendingSpeechCompletionIds([
        source(
          'tail',
          repair: const SpeechRepair(
            start: 4,
            end: 4,
            text: '周三',
            evidenceIds: ['tail', 'resume'],
          ),
        ),
      ]),
      isEmpty,
    );
  });
}
