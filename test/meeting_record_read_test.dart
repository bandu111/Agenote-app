import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yanshu/core/network/api_client.dart';
import 'package:yanshu/core/network/api_config.dart';
import 'package:yanshu/features/meeting/meeting_models.dart';
import 'package:yanshu/features/meeting/meeting_remote.dart';
import 'package:yanshu/features/meeting/meeting_store.dart';
import 'dio_auth_repository_test.dart' show TestAdapter, envelope;
import 'meeting_remote_test.dart' show FakeMeetingRemote, createMeeting;

class DetailRemote extends FakeMeetingRemote implements MeetingRecordReader {
  bool historyFails = true;
  int reads = 0;
  Completer<MeetingRecord>? detailPending;
  MeetingRecord get archived => MeetingRecord(
    id: 'archived',
    ownerId: 'account-a',
    startedAt: DateTime(2026, 10, 31),
    demo: false,
    ended: true,
    cloudMinutes: '# 已归档',
  );
  @override
  Future<List<MeetingRecord>> history() async {
    if (historyFails) throw const ApiFailure('历史服务暂不可用');
    return [];
  }

  @override
  Future<MeetingRecord> readMeeting(String id) async {
    reads++;
    return detailPending == null ? archived : await detailPending!.future;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('历史接口失败仍按 ID 恢复纪要，不切换正在录音的会议', () async {
    final remote = DetailRemote();
    final store = MemoryMeetingStore();
    final vm = await createMeeting(remote, store);
    await vm.start(demo: false);
    final activeId = vm.record!.id;
    final saved = await vm.readMeeting('archived');
    expect(saved!.cloudMinutes, '# 已归档');
    expect(vm.record!.id, activeId);
    expect(vm.active, isTrue);
    expect((await store.read()).any((r) => r.id == 'archived'), isTrue);
    expect(remote.reads, 1);
    await vm.readMeeting('archived');
    expect(remote.reads, 1);
    expect(remote.analyses, 0);
  });

  test('会议不在历史列表时也可读取，换号后不写入旧账户回包', () async {
    final remote = DetailRemote()..historyFails = false;
    final store = MemoryMeetingStore();
    final vm = await createMeeting(remote, store);
    remote.detailPending = Completer<MeetingRecord>();
    final read = vm.readMeeting('archived');
    while (remote.reads == 0) {
      await Future<void>.delayed(Duration.zero);
    }
    remote.accountId = 'account-b';
    remote.detailPending!.complete(remote.archived);
    expect(await read, isNull);
    expect(await store.read(), isEmpty);
    expect(vm.history, isEmpty);
  });

  test('历史中一条损坏记录不影响其他会议，详情请求保留账户认证', () async {
    final paths = <String>[];
    final payload = {
      'id': 'archived',
      'startedAt': '2026-10-31T10:00:00+08:00',
      'ended': true,
      'revision': 3,
      'utterances': [],
    };
    final client =
        ApiClient(
            baseUrl: 'https://test.example/',
            dio: Dio()
              ..httpClientAdapter = TestAdapter((options) async {
                paths.add(options.path);
                expect(options.headers['Authorization'], 'Bearer test-token');
                if (options.path == 'meetings') {
                  return (
                    200,
                    envelope([
                      {'id': 'broken'},
                      payload,
                    ]),
                  );
                }
                return (200, envelope(payload));
              }),
          )
          ..accountId = (() => 'account-a')
          ..accessToken = (() async => 'test-token');
    final remote = DioMeetingRepository(client);
    expect((await remote.history()).map((r) => r.id), ['archived']);
    final record = await remote.readMeeting('archived');
    expect(record.ownerId, 'account-a');
    expect(record.syncRevision, 3);
    expect(paths, ['meetings', 'meetings/archived']);
  });
}
