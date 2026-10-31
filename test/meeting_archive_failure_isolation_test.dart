import 'dart:async';
import 'package:yanshu/features/meeting/local_speech.dart';
import 'meeting_test.dart' show FakeMeetingRecorder;
import 'package:flutter_test/flutter_test.dart';
import 'package:yanshu/core/network/api_config.dart';
import 'package:yanshu/features/meeting/meeting_models.dart';
import 'package:yanshu/features/meeting/meeting_store.dart';
import 'meeting_remote_test.dart' show BusinessMeetingRemote;
import 'meeting_remote_test.dart' show FakeMeetingRemote, FakeTranscriptPolisher, createMeeting;

class InvalidAnalysisRemote extends FakeMeetingRemote {
  @override
  Future<Map<String, dynamic>> archive(MeetingRecord record) async => {
    ...await super.archive(record),
    'meetingTitle': 'ERP接口修复与上线安排',
  };
  @override
  Future<Map<String, dynamic>> analyze(MeetingRecord record) async {
    analyses++;
    throw const ApiFailure('Agent 输出格式校验失败');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('five-minute meeting archives while display polishing is still blocked', () async {
    final gate = Completer<String>();
    final remote = FakeTranscriptPolisher()..gate = gate;
    final vm = await createMeeting(remote,MemoryMeetingStore());
    await vm.start(demo:false);
    (vm.recorder as FakeMeetingRecorder).transcriptEvents.add(
      const MeetingTranscript(0,'我负责明天提交测试报告。',isFinal:true));
    final utteranceId = vm.record!.utterances.single.id;
    await vm.correct(utteranceId,'我负责后天提交测试报告。');
    vm.phase = MeetingPhase.ended;
    vm.record = vm.record!.copy(ended:true,elapsed:const Duration(minutes:5));
    try {
      await vm.syncCloud().timeout(const Duration(seconds:2));
      expect(gate.isCompleted,isFalse);
      expect(vm.record!.cloudMinutes,contains('云端纪要'));
      expect(remote.sent.last.utterances.single.raw,'我负责明天提交测试报告。');
      expect(remote.sent.last.utterances.single.correction,'我负责后天提交测试报告。');
      expect(remote.sent.last.elapsed,const Duration(minutes:5));
      expect(vm.cloudError,isNull);
    } finally {
      gate.complete('不得覆盖人工修改');
      await Future<void>.delayed(Duration.zero);
    }
  });
  test('final archive does not wait for a blocked realtime business review', () async {
    final remote = BusinessMeetingRemote();
    final store = MemoryMeetingStore();
    await store.save(MeetingRecord(id:'business-delay',startedAt:DateTime(2030),
      demo:false,ownerId:'account-a',elapsed:const Duration(seconds:90),
      utterances:[const MeetingUtterance(id:'u1',speaker:'A',raw:'明天提交接口报告。',at:Duration.zero)]));
    final vm = await createMeeting(remote,store);
    await vm.open('business-delay');
    vm.phase = MeetingPhase.ended;
    vm.record = vm.record!.copy(ended:true);
    try {
      await vm.syncCloud().timeout(const Duration(seconds:2));
      expect(remote.firstBusiness.isCompleted,isTrue);
      expect(remote.release.isCompleted,isFalse);
      expect(vm.record!.cloudMinutes,contains('云端纪要'));
      expect(vm.cloudError,isNull);
    } finally {
      remote.release.complete();
      await Future<void>.delayed(Duration.zero);
    }
  });
  test(
    'end flag and final duration sync even when phase and utterances stay unchanged',
    () async {
      final remote = BusinessMeetingRemote();
      remote.release.complete();
      final store = MemoryMeetingStore();
      await store.save(
        MeetingRecord(
          id: 'end-state-sync',
          startedAt: DateTime.utc(2030, 10, 22),
          demo: false,
          ownerId: 'account-a',
          elapsed: const Duration(seconds: 90),
          utterances: [
            MeetingUtterance(
              id: 'u1',
              speaker: '甲',
              raw: '明天提交报告。',
              cleaned: '明天提交报告。',
              at: const Duration(seconds: 10),
            ),
          ],
        ),
      );
      final vm = await createMeeting(remote, store);
      await vm.open('end-state-sync');
      vm.phase = MeetingPhase.ended;
      await vm.syncCloud();
      final before = remote.sent.length;
      vm.record = vm.record!.copy(ended: true);
      await vm.syncCloud();
      expect(remote.sent.length, greaterThan(before));
      expect(remote.sent.last.ended, isTrue);
      expect(vm.record!.cloudMinutes, contains('云端纪要'));
      expect(vm.cloudError, isNull);
    },
  );
  test(
    'ended minutes and home refresh do not depend on failing full Agent analysis',
    () async {
      final remote = InvalidAnalysisRemote();
      final store = MemoryMeetingStore();
      await store.save(
        MeetingRecord(
          id: 'ended-archive-test',
          startedAt: DateTime.utc(2030, 10, 22),
          demo: false,
          ownerId: 'account-a',
          elapsed: const Duration(seconds: 90),
          ended: true,
          utterances: [
            MeetingUtterance(
              id: 'u1',
              speaker: '甲',
              raw: '我负责明天提交评估报告。',
              cleaned: '我负责明天提交评估报告。',
              at: const Duration(seconds: 10),
            ),
          ],
        ),
      );
      var refreshed = 0;
      final vm = await createMeeting(
        remote,
        store,
        onProgressChanged: () async {
          refreshed++;
        },
      );
      await vm.open('ended-archive-test');
      await vm.syncCloud();
      expect(remote.analyses, 0);
      expect(vm.record!.title, 'ERP接口修复与上线安排');
      expect(vm.record!.cloudMinutes, contains('云端纪要'));
      expect(vm.record!.ended, true);
      expect(vm.cloudError, isNull);
      expect(refreshed, greaterThan(0));
    },
  );
}
