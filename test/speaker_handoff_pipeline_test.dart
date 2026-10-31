import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:yanshu/core/network/api_client.dart';
import 'package:yanshu/features/meeting/meeting_store.dart';
import 'package:yanshu/features/meeting/speech_turn.dart';
import 'package:yanshu/features/meeting/tencent_speech.dart';
import 'meeting_remote_test.dart' show FakeMeetingRemote, createMeeting;
import 'meeting_test.dart' show FakeMeetingRecorder;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final lateCorrection in [false, true]) {
    test(
      lateCorrection
          ? '真实接收器收到后续B更正后拆开段落，保留原话'
          : 'A说完B零停顿接话经过WebSocket和ViewModel仍为A/B/A，不跨人合段',
      () async {
        final previousHttp = HttpOverrides.current;
        HttpOverrides.global = null;
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final sockets = <WebSocket>[];
        final allSent = Completer<void>();
        server.listen((request) async {
          if (!WebSocketTransformer.isUpgradeRequest(request)) {
            request.response.headers.contentType = ContentType.json;
            request.response.write(jsonEncode({'code': 200, 'data': {}}));
            await request.response.close();
            return;
          }
          final socket = await WebSocketTransformer.upgrade(request);
          sockets.add(socket);
          socket.add(jsonEncode({'type': 'ready', 'speaker_scope': 'handoff'}));
          for (var n = 0; n < 3; n++) {
            socket.add(
              jsonEncode({
                'type': 'transcript',
                'segment': n,
                'text': ['甲方说明原范围。', '乙方立即说明验收要求。', '甲方再回复。'][n],
                'is_final': true,
                'speaker_id': n == 1 && !lateCorrection ? 1 : 0,
                'start_ms': n * 1000,
                'end_ms': (n + 1) * 1000,
              }),
            );
          }
          if (lateCorrection) {
            socket.add(
              jsonEncode({
                'type': 'speaker_update',
                'segment': 1,
                'text': '更正不得篡改原话',
                'is_final': true,
                'speaker_id': 1,
                'speaker_revision': 1,
                'start_ms': 1000,
                'end_ms': 2000,
              }),
            );
          }
          allSent.complete();
        });
        final api = ApiClient(
          baseUrl: 'http://127.0.0.1:${server.port}/api/v1/',
        );
        api.accountId = () => 'account-a';
        api.accessToken = () async => 'synthetic-only';
        final recorder = FakeMeetingRecorder();
        final vm = await createMeeting(
          FakeMeetingRemote(),
          MemoryMeetingStore(),
          recorder: recorder,
          disposeViewModel: false,
        );
        final worker = TencentSpeechWorker(api, 'handoff');
        final subscription = worker.transcripts.listen(
          recorder.transcriptEvents.add,
        );
        try {
          await vm.start(demo: false);
          await worker.start();
          await allSent.future;
          for (var n = 0; n < 100; n++) {
            if (vm.record!.utterances.length == 3 &&
                vm.record!.utterances[1].speaker == '发言人 B') {
              break;
            }
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          final utterances = vm.record!.utterances;
          expect(utterances.map((u) => u.speaker), ['发言人 A', '发言人 B', '发言人 A']);
          expect(utterances[0].audioEnd, utterances[1].audioStart);
          expect(utterances[1].audioEnd, utterances[2].audioStart);
          expect(speechTurnGroups(utterances).length, 3);
          expect(speechParagraphs(utterances).length, 3);
          expect(utterances[1].raw, '乙方立即说明验收要求。');
          if (lateCorrection) {
            expect(utterances[1].speakerRevision, 1);
            expect(utterances[1].speakerHistory.length, 2);
          }
        } finally {
          vm.dispose();
          await subscription.cancel();
          await worker.abort();
          for (final socket in sockets) {
            await socket.close();
          }
          await server.close(force: true);
          api.dio.close(force: true);
          HttpOverrides.global = previousHttp;
        }
      },
    );
  }
}
