// Explicit identity events verify persistence and rendering, not voice accuracy.
import 'package:flutter_test/flutter_test.dart';
import 'package:yanshu/features/meeting/meeting_models.dart';
import 'package:yanshu/features/meeting/meeting_store.dart';
import 'package:yanshu/features/meeting/meeting_remote.dart';
import 'package:yanshu/features/meeting/live_speaker_identity.dart';
import 'package:yanshu/features/meeting/speech_recognizer.dart';
import 'meeting_remote_test.dart' show FakeMeetingRemote, createMeeting;
import 'meeting_test.dart' show FakeMeetingRecorder;

class IdentityRemote extends FakeMeetingRemote
    implements MeetingSpeakerIdentityRemote {
  int identityRevision = 0;
  Map<String, dynamic> identities = {};
  @override
  Future<Map<String, dynamic>> readSpeakerIdentities(
    MeetingRecord record,
  ) async => {'revision': identityRevision, 'identities': identities};
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'saved mapping survives finish and reopening; sync never uploads identity',
    () async {
      final remote = IdentityRemote();
      final store = MemoryMeetingStore();
      final recorder = FakeMeetingRecorder();
      final vm = await createMeeting(remote, store, recorder: recorder);
      await vm.start(demo: false);
      void emit(LiveSpeakerIdentityEvent event) => recorder.transcriptEvents
          .add(MeetingTranscript(-1, '', isFinal: false, identityEvent: event));
      emit(
        const LiveSpeakerIdentityEvent(
          sessionId: 's',
          scope: 'scope',
          isSession: true,
          status: 'enabled',
        ),
      );
      await Future<void>.delayed(Duration.zero);
      recorder.transcriptEvents.add(
        const MeetingTranscript(
          0,
          '测试来源原文',
          isFinal: true,
          speakerId: 'asr:scope:0',
          speakerSeparated: true,
        ),
      );
      remote.identityRevision = 1;
      remote.identities = {
        'asr:scope:0': {'identity': 'self', 'source': 'voiceprint'},
      };
      emit(
        const LiveSpeakerIdentityEvent(
          sessionId: 's',
          scope: 'scope',
          speakerId: 'asr:scope:0',
          identity: 'self',
          revision: 1,
          persisted: true,
          meetingRevision: 1,
        ),
      );
      expect(vm.speakerDisplayName(vm.record!.utterances.single), '我（A）');
      expect(
        meetingSyncPayload(vm.record!, paused: false),
        isNot(contains('speakerIdentities')),
      );
      expect(vm.record!.utterances.single.speaker, '发言人 A');
      expect(await vm.finish(), isTrue);
      expect(vm.speakerDisplayName(vm.record!.utterances.single), '我（A）');
      expect(vm.minutes(), contains('我（A）'));
      final id = vm.record!.id;
      await vm.open(id);
      expect(vm.record!.speakerIdentityRevision, 1);
      expect(
        vm.record!.speakerDisplayName(vm.record!.utterances.single),
        '我（A）',
      );
      final restored = MeetingRecord.fromJson(vm.record!.toJson());
      expect(restored.speakerDisplayName(restored.utterances.single), '我（A）');
      remote.identityRevision = 2;
      remote.identities = {
        'asr:scope:0': {'identity': 'unknown'},
      };
      await vm.open(id);
      expect(
        vm.record!.speakerDisplayName(vm.record!.utterances.single),
        '发言人 A',
      );
    },
  );
}
