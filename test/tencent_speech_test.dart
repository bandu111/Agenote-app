import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:yanshu/core/network/api_client.dart';
import 'package:yanshu/features/meeting/tencent_speech.dart';
import 'package:yanshu/features/meeting/speech_recognizer.dart';

void main() {
  test('云端识别暂停刷尾，续录使用新连接且片段和音频时间连续', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final sockets = <WebSocket>[];
    final authorizations = <String?>[];
    final sizes = <int>[];
    server.listen((request) async {
      authorizations.add(request.headers.value('authorization'));
      if (!WebSocketTransformer.isUpgradeRequest(request)) {
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({'code': 200, 'message': 'ok', 'data': {}}),
        );
        await request.response.close();
        return;
      }
      final socket = await WebSocketTransformer.upgrade(request);
      sockets.add(socket);
      var bytes = 0;
      socket.add(
        jsonEncode({
          'type': 'ready',
          'speaker_scope': 'scope-${sockets.length}',
        }),
      );
      socket.listen((dynamic message) {
        if (message is List<int>) {
          bytes += message.length;
          socket.add(
            jsonEncode({
              'type': 'transcript',
              'segment': 0,
              'text': '不要取消',
              'is_final': false,
              'start_ms': 0,
              'end_ms': bytes * 1000 ~/ 32000,
            }),
          );
        } else {
          sizes.add(bytes);
          socket.add(
            jsonEncode({
              'type': 'transcript',
              'segment': 0,
              'text': '不要取消原计划',
              'is_final': true,
              'speaker_id': 0,
              'start_ms': 0,
              'end_ms': bytes * 1000 ~/ 32000,
            }),
          );
          socket.add(jsonEncode({'type': 'done'}));
        }
      });
    });
    final api = ApiClient(baseUrl: 'http://127.0.0.1:${server.port}/api/v1/');
    api.accountId = () => 'owner-a';
    api.accessToken = () async => 'test-token';
    final worker = TencentSpeechWorker(
      api,
      '9c786926-569e-4660-8f7c-1ad18c1bd609',
    );
    final results = <MeetingTranscript>[];
    final subscription = worker.transcripts.listen(results.add);
    try {
      await worker.start();
      worker.accept(Uint8List(3200));
      await worker.flush();
      await worker.start();
      worker.accept(Uint8List(6400));
      await worker.flush();
      final finals = results.where((e) => e.isFinal).toList();
      expect(finals.map((e) => e.speakerId), [
        'asr:scope-1:0',
        'asr:scope-2:0',
      ]);
      expect(finals.every((e) => e.speakerSeparated), isTrue);
      expect(sockets.length, 2);
      expect(sizes, [3200, 6400]);
      expect(finals.map((e) => e.segment), [0, 1]);
      expect(finals.map((e) => e.audioStart!.inMilliseconds), [0, 100]);
      expect(finals.map((e) => e.audioEnd!.inMilliseconds), [100, 300]);
      expect(finals.every((e) => e.text == '不要取消原计划'), isTrue);
      expect(results.where((e) => !e.isFinal).length, 2);
      expect(authorizations.every((e) => e == 'Bearer test-token'), isTrue);
    } finally {
      await worker.close();
      await subscription.cancel();
      for (final socket in sockets) {
        await socket.close();
      }
      api.dio.close(force: true);
      await server.close(force: true);
    }
  });

  test('同一连接连续返回多人发言，不需要暂停刷尾；提前结束触发自动恢复信号', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    WebSocket? socket;
    var frame = 0, endings = 0;
    server.listen((request) async {
      if (!WebSocketTransformer.isUpgradeRequest(request)) {
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({'code': 200, 'message': 'ok', 'data': {}}),
        );
        await request.response.close();
        return;
      }
      socket = await WebSocketTransformer.upgrade(request);
      socket!.add(
        jsonEncode({'type': 'ready', 'speaker_scope': 'same-meeting'}),
      );
      socket!.listen((dynamic message) {
        if (message is List<int>) {
          final i = frame++;
          socket!.add(
            jsonEncode({
              'type': 'transcript',
              'segment': i,
              'text': '连续发言$i',
              'is_final': true,
              'speaker_id': i % 2,
              'start_ms': i * 100,
              'end_ms': (i + 1) * 100,
            }),
          );
        } else {
          endings++;
        }
      });
    });
    final api = ApiClient(baseUrl: 'http://127.0.0.1:${server.port}/api/v1/')
      ..accountId = (() => 'owner')
      ..accessToken = (() async => 'test-token');
    final worker = TencentSpeechWorker(api, 'continuous-meeting');
    final results = <MeetingTranscript>[];
    final received = Completer<void>(), interrupted = Completer<void>();
    final subscription = worker.transcripts.listen(
      (event) {
        results.add(event);
        if (results.length == 3) received.complete();
      },
      onError: (Object _) {
        if (!interrupted.isCompleted) interrupted.complete();
      },
    );
    try {
      await worker.start();
      for (var i = 0; i < 3; i++) {
        worker.accept(Uint8List(3200));
      }
      await received.future.timeout(const Duration(seconds: 3));
      expect(endings, 0);
      expect(results.map((e) => e.speakerId), [
        'asr:same-meeting:0',
        'asr:same-meeting:1',
        'asr:same-meeting:0',
      ]);
      socket!.add(jsonEncode({'type': 'done'}));
      await interrupted.future.timeout(const Duration(seconds: 3));
    } finally {
      await worker.abort();
      await subscription.cancel();
      await socket?.close();
      api.dio.close(force: true);
      await server.close(force: true);
    }
  });

  test('未登录不能创建计费识别连接', () async {
    final api = ApiClient(baseUrl: 'https://invalid.example/api/v1/');
    final worker = TencentSpeechWorker(api, 'test');
    await expectLater(worker.start(), throwsStateError);
    await worker.close();
    api.dio.close(force: true);
  });
}
