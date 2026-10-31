import 'package:flutter_test/flutter_test.dart';
import 'package:yanshu/core/network/api_config.dart';
import 'package:yanshu/features/meeting/meeting_models.dart';
import 'package:yanshu/features/meeting/meeting_store.dart';
import 'meeting_remote_test.dart' show BusinessMeetingRemote;
import 'meeting_remote_test.dart' show FakeMeetingRemote, createMeeting;

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
