import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:yanshu/features/meeting/meeting_models.dart';
import 'package:yanshu/features/meeting/meeting_remote.dart';
import 'package:yanshu/features/meeting/meeting_store.dart';
import 'package:yanshu/features/meeting/local_speech.dart';
import 'meeting_remote_test.dart'
    show FakeMeetingRemote, createMeeting, NoisyMeetingRecorder;
import 'meeting_test.dart' show FakeMeetingRecorder;

class SemanticRemote extends FakeMeetingRemote implements SemanticMeetingTurn {
  bool? answer;
  Completer<bool?>? gate;
  int calls = 0;
  @override
  Future<bool?> isTurnComplete(MeetingRecord record, String text) async {
    calls++;
    return gate?.future ?? answer;
  }
}

void main() {
  testWidgets('同一段原话受背景音影响重新计时，也不反复请求语义模型', (tester) async {
    final remote = SemanticRemote()..answer = false;
    final recorder = NoisyMeetingRecorder();
    final vm = await createMeeting(
      remote,
      MemoryMeetingStore(),
      recorder: recorder,
      disposeViewModel: false,
    );
    await vm.start(demo: false);
    recorder.transcriptEvents.add(
      const MeetingTranscript(0, '今天讨论三个问题，第一个是系统运行情况。', isFinal: true),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 5));
    await tester.pump(const Duration(seconds: 1));
    recorder.amplitudes.add(.025);
    await tester.pump();
    await tester.pump(const Duration(seconds: 5));
    expect(remote.calls, 1);
    vm.dispose();
  });
  testWidgets('列举中的完整句号不等于说完，思考后接着说仍为同轮', (tester) async {
    final remote = SemanticRemote()..answer = false;
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
        '今天讨论三个问题，第一个是系统运行情况。',
        isFinal: true,
        speakerId: 'a',
        speakerSeparated: true,
        audioStart: Duration.zero,
        audioEnd: Duration(seconds: 2),
      ),
    );
    await tester.pump();
    final turn = vm.record!.utterances.first.turnId;
    await tester.pump(const Duration(seconds: 6));
    expect(remote.calls, 1);
    expect(vm.record!.utterances.first.turnStatus, 'pending');
    recorder.transcriptEvents.add(
      const MeetingTranscript(
        1,
        '第二个是目前仍待处理的事项。',
        isFinal: true,
        speakerId: 'a',
        speakerSeparated: true,
        audioStart: Duration(seconds: 8),
        audioEnd: Duration(seconds: 10),
      ),
    );
    await tester.pump();
    expect(vm.record!.utterances.last.turnId, turn);
    expect(recorder.pauses, 0);
    vm.dispose();
  });

  testWidgets('晚到的说完判断不能关闭新发言，真正完整才自然收尾', (tester) async {
    final gate = Completer<bool?>();
    final remote = SemanticRemote()..gate = gate;
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
        '目前门店反馈比较积极，统计口径正在整理。',
        isFinal: true,
        speakerId: 'a',
        speakerSeparated: true,
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 5));
    recorder.transcriptEvents.add(
      const MeetingTranscript(1, '另外还有一件事情', isFinal: false),
    );
    await tester.pump();
    gate.complete(true);
    await tester.pump();
    expect(vm.record!.utterances.first.turnStatus, 'pending');
    expect(vm.partial, isNotEmpty);
    remote.gate = null;
    remote.answer = true;
    recorder.transcriptEvents.add(
      const MeetingTranscript(
        1,
        '另外门店统计表已经整理完毕，这部分说明完了。',
        isFinal: true,
        speakerId: 'a',
        speakerSeparated: true,
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 5));
    await tester.pump();
    expect(
      vm.record!.utterances.every((u) => u.turnStatus == 'complete'),
      isTrue,
    );
    vm.dispose();
  });

  testWidgets('离线未知有界收尾，不反复调模型或无限等待', (tester) async {
    final remote = SemanticRemote();
    final recorder = FakeMeetingRecorder();
    final vm = await createMeeting(
      remote,
      MemoryMeetingStore(),
      recorder: recorder,
      disposeViewModel: false,
    );
    await vm.start(demo: false);
    recorder.transcriptEvents.add(
      const MeetingTranscript(0, '目前门店反馈比较积极，统计口径正在整理。', isFinal: true),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 5));
    await tester.pump(const Duration(seconds: 15));
    expect(remote.calls, 1);
    expect(vm.record!.utterances.single.turnStatus, 'complete');
    vm.dispose();
  });
}
