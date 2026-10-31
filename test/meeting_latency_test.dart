import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:yanshu/features/meeting/local_speech.dart';
import 'package:yanshu/features/meeting/meeting_models.dart';
import 'package:yanshu/features/meeting/meeting_remote.dart';
import 'package:yanshu/features/meeting/meeting_store.dart';
import 'meeting_remote_test.dart' show FakeMeetingRemote, createMeeting;
import 'meeting_test.dart' show FakeMeetingRecorder;

class PreviewPolishRemote extends IncrementalPreviewRemote
    implements MeetingTranscriptPolisher {
  int polishes = 0;
  final release = Completer<Map<String, dynamic>>();
  void Function(Map<String, dynamic>)? preview;
  @override
  Future<Map<String, dynamic>> analyzeWithUpdates(
    MeetingRecord record,
    void Function(Map<String, dynamic>) onPreview,
  ) {
    preview = onPreview;
    return release.future;
  }

  @override
  Future<String> polish(
    MeetingRecord record,
    MeetingUtterance utterance,
  ) async {
    polishes++;
    return utterance.raw;
  }
}

class IncrementalPreviewRemote extends FakeMeetingRemote
    implements LiveMeetingAnalysis, StreamingMeetingAnalysis {
  @override
  Future<void> liveHints(
    MeetingRecord record,
    void Function(Map<String, dynamic>) onUpdate,
  ) async {
    onUpdate({'event': 'done', 'insights': [], 'repairs': []});
  }

  @override
  Future<Map<String, dynamic>> analyzeWithUpdates(
    MeetingRecord record,
    void Function(Map<String, dynamic>) onPreview,
  ) => analyze(record);
}

void main() {
  for (final withPreview in [true, false]) {
    testWidgets(
      withPreview ? '字词整理先让路，核心提示首段到达就恢复，不等完整复核' : '核心提示没返回也有有界整理兜底，不无限饿死整理',
      (tester) async {
        final remote = PreviewPolishRemote();
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
            '乙方负责处理同步延迟，接口今天无法确认，可能影响交付。',
            isFinal: true,
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 1200));
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pump();
        expect(remote.preview, isNotNull);
        expect(remote.polishes, 0);
        if (withPreview) {
          remote.preview!({
            'insights': [
              {
                'id': 'fast',
                'kind': 'risk',
                'title': '交付待核对',
                'body': '接口确认受阻。',
                'evidence_ids': [vm.record!.utterances.first.id],
              },
            ],
          });
          await tester.pump();
        } else {
          await tester.pump(const Duration(seconds: 6));
          await tester.pump();
        }
        expect(remote.polishes, 1);
        expect(remote.release.isCompleted, isFalse);
        expect(vm.phase, MeetingPhase.recording);
        vm.dispose();
        remote.release.complete({
          'insights': [],
          'repairs': [],
          'withdrawals': [],
        });
        await tester.pump();
      },
    );
  }
  testWidgets('已支持独立流式预览的远端不额外等3秒，300毫秒启动且不暂停收音', (tester) async {
    final remote = IncrementalPreviewRemote();
    final vm = await createMeeting(
      remote,
      MemoryMeetingStore(),
      disposeViewModel: false,
    );
    await vm.start(demo: false);
    await vm.addManual('发言人 A', '接口今天无法确认，可能影响交付。');
    await tester.pump(const Duration(milliseconds: 299));
    expect(remote.analyses, 0);
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump();
    expect(remote.analyses, 1);
    expect(vm.phase, MeetingPhase.recording);
    vm.dispose();
  });
}
