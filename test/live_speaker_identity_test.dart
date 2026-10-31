// Simulated identity events verify protocol and display only, never real voice accuracy.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:yanshu/core/network/api_client.dart';
import 'package:yanshu/features/meeting/live_speaker_identity.dart';
import 'package:yanshu/features/meeting/speech_recognizer.dart';
import 'package:yanshu/features/meeting/meeting_store.dart';
import 'package:yanshu/features/meeting/meeting_remote.dart';
import 'package:yanshu/features/meeting/tencent_speech.dart';
import 'meeting_remote_test.dart' show FakeMeetingRemote, createMeeting;
import 'meeting_test.dart' show FakeMeetingRecorder;

LiveSpeakerIdentityEvent ready(String session) => LiveSpeakerIdentityEvent(
  sessionId: session,
  scope: 'test-scope',
  isSession: true,
  status: 'enabled',
);
LiveSpeakerIdentityEvent update(
  String session,
  int revision,
  String identity,
) => LiveSpeakerIdentityEvent(
  sessionId: session,
  scope: 'test-scope',
  speakerId: 'asr:test-scope:0',
  revision: revision,
  identity: identity,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('revisions, uncertainty and reconnect do not retain stale identity', () {
    final store = LiveSpeakerIdentityStore();
    store.accept(ready('one'));
    expect(store.label('asr:test-scope:0', '发言人 A'), '发言人 A');
    expect(store.accept(update('one', 1, 'self')), isTrue);
    expect(store.label('asr:test-scope:0', '发言人 A'), '我（A）');
    expect(store.label('asr:test-scope:1', '发言人 B'), '发言人 B');
    store.accept(update('one', 2, 'unknown'));
    expect(store.accept(update('one', 1, 'self')), isFalse);
    expect(store.label('asr:test-scope:0', '发言人 A'), '发言人 A');
    store.accept(ready('two'));
    expect(store.accept(update('one', 3, 'self')), isFalse);
    store.accept(update('two', 1, 'self'));
    store.accept(
      const LiveSpeakerIdentityEvent(
        sessionId: 'two',
        scope: 'test-scope',
        status: 'template_changed',
      ),
    );
    expect(store.label('asr:test-scope:0', '发言人 A'), '发言人 A');
    expect(store.accept(update('two', 2, 'self')), isFalse);
  });

  test(
    'ViewModel displays self without mutating transcript or sync and clears on finish',
    () async {
      final recorder = FakeMeetingRecorder();
      final vm = await createMeeting(
        FakeMeetingRemote(),
        MemoryMeetingStore(),
        recorder: recorder,
      );
      await vm.start(demo: false);
      void emit(LiveSpeakerIdentityEvent identity) =>
          recorder.transcriptEvents.add(
            MeetingTranscript(-1, '', isFinal: false, identityEvent: identity),
          );
      emit(ready('one'));
      recorder.transcriptEvents.add(
        const MeetingTranscript(
          0,
          '测试原话，不是声纹识别证据。',
          isFinal: true,
          speakerId: 'asr:test-scope:0',
          speakerSeparated: true,
        ),
      );
      emit(update('one', 1, 'self'));
      final source = vm.record!.utterances.single;
      expect(vm.speakerDisplayName(source), '我（A）');
      expect(source.speaker, '发言人 A');
      expect(
        jsonEncode(meetingSyncPayload(vm.record!, paused: false)),
        isNot(contains('我（')),
      );
      expect(
        jsonEncode(vm.record!.toJson()),
        isNot(contains('identity_session_id')),
      );
      expect(vm.record!.utterances, hasLength(1));
      await vm.finish();
      expect(vm.speakerDisplayName(source), '发言人 A');
      expect(vm.selfIdentificationHint, isEmpty);
    },
  );

  test(
    'real WebSocket parser isolates malformed and stale identity events from ASR',
    () async {
      final previousHttp = HttpOverrides.current;
      HttpOverrides.global = null;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      WebSocket? socket;
      server.listen((request) async {
        if (!WebSocketTransformer.isUpgradeRequest(request)) {
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode({'code': 200, 'data': {}}));
          await request.response.close();
          return;
        }
        socket = await WebSocketTransformer.upgrade(request);
        void send(Map<String, dynamic> data) => socket!.add(jsonEncode(data));
        send({
          'type': 'ready',
          'speaker_scope': 'test-scope',
          'identity_session_id': 'new',
          'self_identification': 'enabled',
        });
        final event = {
          'type': 'speaker_identity_update',
          'identity_session_id': 'new',
          'speaker_scope': 'test-scope',
          'speaker_id': 0,
          'identity': 'self',
          'identity_revision': 1,
        };
        send({...event, 'speaker_id': 'malformed'});
        send({...event, 'identity_session_id': 'old'});
        send(event);
        send({
          'type': 'transcript',
          'segment': 0,
          'speaker_id': 0,
          'text': '原文正常返回',
          'is_final': true,
          'start_ms': 0,
          'end_ms': 1000,
        });
        socket!.listen((message) {
          if (message == '{"type":"end"}') send({'type': 'done'});
        });
      });
      final api = ApiClient(baseUrl: 'http://127.0.0.1:${server.port}/api/v1/');
      api.accountId = () => 'test-owner';
      api.accessToken = () async => 'test-only-token';
      final worker = TencentSpeechWorker(api, 'test-meeting');
      final events = <MeetingTranscript>[], errors = <Object>[];
      final arrived = Completer<void>();
      final subscription = worker.transcripts.listen((event) {
        events.add(event);
        if (event.isFinal && !arrived.isCompleted) arrived.complete();
      }, onError: errors.add);
      try {
        await worker.start();
        await arrived.future.timeout(const Duration(seconds: 3));
        expect(
          events.where((e) => e.identityEvent?.identity == 'self'),
          hasLength(1),
        );
        expect(events.where((e) => e.isFinal).single.text, '原文正常返回');
        expect(errors, isEmpty);
        await worker.flush();
      } finally {
        await subscription.cancel();
        await worker.abort();
        await socket?.close();
        await server.close(force: true);
        api.dio.close(force: true);
        HttpOverrides.global = previousHttp;
      }
    },
  );
}
