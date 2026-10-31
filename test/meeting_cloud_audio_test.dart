import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yanshu/core/network/api_client.dart';
import 'package:yanshu/features/meeting/meeting_cloud_audio.dart';
import 'package:yanshu/features/meeting/meeting_models.dart';
import 'package:yanshu/features/meeting/local_speech.dart';
import 'package:yanshu/features/meeting/meeting_remote.dart';
import 'package:yanshu/features/meeting/meeting_store.dart';
import 'meeting_remote_test.dart' show FakeMeetingRemote, createMeeting;
import 'dio_auth_repository_test.dart' show TestAdapter, envelope;

void main() {
  testWidgets('录音上传未结束时，纪要仍能先完成，结束后保存上传状态', (tester) async {
    final remote = GatedAudioRemote();
    final vm = await createMeeting(remote, MemoryMeetingStore());
    await vm.start(demo: false);
    await vm.addManual('A', '我方承诺提交报告。');
    await vm.finish();
    // 纪要只对超过一分钟的会议生成；让该 fixture 覆盖录音上传与纪要并行。
    await vm.store.save(vm.record!.copy(elapsed: const Duration(seconds: 90)));
    vm.record = vm.record!.copy(elapsed: const Duration(seconds: 90));
    await vm.syncCloud();
    expect(remote.uploads, 1);
    expect(vm.record!.cloudMinutes, isNotNull);
    expect(vm.record!.cloudAudioUploaded, isFalse);
    remote.done.complete();
    await tester.pump(const Duration(milliseconds: 100));
    expect(vm.record!.cloudAudioUploaded, isTrue);
  });
  test('云端历史恢复原话片段，不依赖本机文件路径', () async {
    final api = ApiClient(
      baseUrl: 'https://test.example/',
      dio: Dio()
        ..httpClientAdapter = TestAdapter(
          (o) async => (
            200,
            envelope([
              {
                'id': 'meeting',
                'revision': 1,
                'startedAt': '2026-10-23T10:00:00+08:00',
                'title': '会议',
                'elapsed': 1000,
                'ended': true,
                'utterances': [
                  {'id': 'u', 'speaker': 'A', 'raw': '原话', 'at': 0},
                ],
                'audioSources': {
                  'u': {'audioId': 'audio', 'start': 100, 'end': 900},
                },
              },
            ]),
          ),
        ),
    )..accountId = () => 'owner';
    final history = await DioMeetingRepository(api).history();
    expect(history.single.utterances.single.audioPath, 'yanshu-audio:audio');
    expect(
      history.single.utterances.single.audioStart,
      const Duration(milliseconds: 100),
    );
    expect(history.single.utterances.single.hasAudio, isTrue);
  });
  test('新会议停止后上传整场，断点只续传缺失块，不发送设备路径', () async {
    final directory = await Directory.systemTemp.createTemp(
      'audio-upload-test-',
    );
    try {
      final bytes = Uint8List.fromList([
        ...meetingWavHeader(64000),
        ...List.filled(64000, 0),
      ]);
      final file = await File(
        '${directory.path}/record.wav',
      ).writeAsBytes(bytes);
      var offset = 32000;
      var complete = false;
      final requests = <RequestOptions>[];
      final api = ApiClient(
        baseUrl: 'https://test.example/',
        dio: Dio()
          ..httpClientAdapter = TestAdapter((o) async {
            requests.add(o);
            if (o.path.endsWith('/audio')) {
              return (
                200,
                envelope({
                  'id': 'audio',
                  'offset': offset,
                  'state': 'uploading',
                }),
              );
            }
            if (o.path.endsWith('/chunk')) {
              expect((o.data as Map)['offset'], offset);
              final chunk = base64Decode(o.data['data']);
              expect(chunk, bytes.sublist(offset));
              offset += chunk.length;
              return (200, envelope({'offset': offset}));
            }
            complete = true;
            return (200, envelope({'id': 'audio', 'state': 'complete'}));
          }),
      )..accountId = () => 'owner';
      final source = MeetingRecord(
        id: 'meeting',
        startedAt: DateTime(2026),
        demo: false,
        ownerId: 'owner',
        ended: true,
        cloudAudioEnabled: true,
        audioPaths: [file.path],
        utterances: [
          MeetingUtterance(
            id: 'u',
            speaker: 'A',
            raw: '原始发言',
            at: Duration.zero,
            audioPath: file.path,
            audioStart: Duration.zero,
            audioEnd: const Duration(seconds: 1),
          ),
        ],
      );
      await uploadMeetingAudio(api, source);
      expect(complete, isTrue);
      expect(offset, bytes.length);
      expect(jsonEncode(requests.first.data), isNot(contains(directory.path)));
      expect(requests.first.data['sources'][0]['id'], 'u');
      requests.clear();
      await uploadMeetingAudio(
        api,
        MeetingRecord(
          id: 'old',
          startedAt: DateTime(2026),
          demo: false,
          ownerId: 'owner',
          ended: true,
          audioPaths: [file.path],
        ),
      );
      expect(requests, isEmpty); // 历史本机录音不会因升级被自动上传。
    } finally {
      await directory.delete(recursive: true);
    }
  });
}

class GatedAudioRemote extends FakeMeetingRemote implements MeetingAudioRemote {
  final done = Completer<void>();
  int uploads = 0;
  @override
  Future<void> uploadAudio(MeetingRecord record) {
    uploads++;
    return done.future;
  }
}
