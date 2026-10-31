import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:yanshu/core/network/api_client.dart';
import 'package:yanshu/features/meeting/tencent_speech.dart';
import 'package:yanshu/features/meeting/speech_recognizer.dart';

void main() {
  test('新注释协议不重复转写，无效注释不导致ASR失败，绘制回执仅一次', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final acknowledgments = <Map<String, dynamic>>[];
    WebSocket? socket;
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
      socket!.add(jsonEncode({'type': 'ready', 'speaker_scope': 'test'}));
      socket!.add(
        jsonEncode({
          'type': 'transcript',
          'segment': 0,
          'text': '乙负责周五提交报告。',
          'is_final': true,
          'start_ms': 0,
          'end_ms': 1000,
        }),
      );
      socket!.add(
        jsonEncode({
          'type': 'transcript_highlights',
          'segment': 'broken',
          'text': null,
        }),
      );
      socket!.add(
        jsonEncode({
          'type': 'transcript_highlights',
          'segment': 0,
          'text': '乙负责周五提交报告。',
          'revision': 'v1',
          'trace_id': 'trace-test',
          'highlights': [
            {
              'start': 3,
              'end': 9,
              'quote': '周五提交报告',
              'kind': 'commitment',
              'reason': '交付时间',
            },
          ],
        }),
      );
      socket!.listen((message) {
        if (message is! String) return;
        final data = jsonDecode(message) as Map<String, dynamic>;
        if (data['type'] == 'highlight_displayed') acknowledgments.add(data);
        if (data['type'] == 'end') socket!.add(jsonEncode({'type': 'done'}));
      });
    });
    final api = ApiClient(baseUrl: 'http://127.0.0.1:${server.port}/api/v1/');
    api.accountId = () => 'test';
    api.accessToken = () async => 'synthetic';
    final worker = TencentSpeechWorker(api, 'test-highlights');
    final events = <MeetingTranscript>[];
    final errors = <Object>[];
    final arrived = Completer<MeetingTranscript>();
    final subscription = worker.transcripts.listen((e) {
      events.add(e);
      if (e.highlightBatch != null && !arrived.isCompleted) arrived.complete(e);
    }, onError: errors.add);
    try {
      await worker.start();
      final annotation = await arrived.future.timeout(
        const Duration(seconds: 3),
      );
      expect(events.where((e) => e.isFinal), hasLength(1));
      expect(annotation.segment, events.first.segment);
      annotation.highlightBatch!.displayed();
      annotation.highlightBatch!.displayed();
      await worker.flush();
      expect(acknowledgments, hasLength(1));
      expect(acknowledgments.single['render_ms'], greaterThanOrEqualTo(0));
      expect(errors, isEmpty);
    } finally {
      await subscription.cancel();
      await worker.abort();
      await socket?.close();
      await server.close(force: true);
      api.dio.close(force: true);
    }
  });
}
