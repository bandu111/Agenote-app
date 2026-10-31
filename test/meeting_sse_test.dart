import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yanshu/core/network/api_client.dart';
import 'package:yanshu/core/network/api_config.dart';
import 'package:yanshu/features/meeting/meeting_models.dart';
import 'package:yanshu/features/meeting/meeting_remote.dart';

class SseAdapter implements HttpClientAdapter {
  final bytes = StreamController<Uint8List>();
  final connected = Completer<RequestOptions>();
  @override
  void close({bool force = false}) {}
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    connected.complete(options);
    return ResponseBody(
      bytes.stream,
      200,
      headers: {
        'content-type': ['text/event-stream'],
      },
    );
  }

  void send(Map<String, dynamic> value) {
    final data = utf8.encode('data: ${jsonEncode(value)}\n\n');
    // 故意逐字节切包，验证 UTF-8 汉字和表情不会因网络分包损坏。
    for (final byte in data) {
      bytes.add(Uint8List.fromList([byte]));
    }
  }
}

void main() {
  test('Dio 在连接未关闭前逐条交付 SSE，不等完整响应', () async {
    final adapter = SseAdapter();
    final client = ApiClient(
      baseUrl: 'https://synthetic.example/api/v1/',
      dio: Dio()..httpClientAdapter = adapter,
    );
    client.accessToken = () async => 'synthetic-token';
    client.accountId = () => 'owner';
    final remote = DioMeetingRepository(client);
    final source = MeetingRecord(
      id: 'm',
      startedAt: DateTime.now(),
      demo: false,
      ownerId: 'owner',
      utterances: const [
        MeetingUtterance(
          id: 'u',
          speaker: '发言人 A',
          raw: 'Windows 尚未批准。',
          at: Duration.zero,
        ),
      ],
    );
    final prefix = Completer<Map<String, dynamic>>();
    var ended = false;
    final work = remote
        .liveHints(source, (event) {
          if (!prefix.isCompleted) prefix.complete(event);
        })
        .then((_) {
          ended = true;
        });
    final request = await adapter.connected.future;
    expect(request.headers['Accept'], 'text/event-stream');
    expect(request.headers['Authorization'], 'Bearer synthetic-token');
    adapter.send({
      'event': 'preview',
      'insights': [
        {
          'id': 'i',
          'kind': 'risk',
          'title': '范围',
          'body': '可能增加工作量😊',
          'evidence_ids': ['u'],
          'streaming': true,
        },
      ],
    });
    final value = await prefix.future.timeout(const Duration(seconds: 2));
    expect(value['insights'][0]['body'], '可能增加工作量😊');
    expect(ended, isFalse);
    adapter.send({'event': 'done', 'insights': []});
    await adapter.bytes.close();
    await work;
    expect(ended, isTrue);
  });

  test('SSE 途中切换账户，旧账户后续文字被丢弃', () async {
    final adapter = SseAdapter();
    var owner = 'a';
    final client = ApiClient(
      baseUrl: 'https://synthetic.example/',
      dio: Dio()..httpClientAdapter = adapter,
    )..accountId = () => owner;
    final received = Completer<void>();
    final values = <Map<String, dynamic>>[];
    final work = client.postEvents('stream', data: {}, accountId: 'a').forEach((
      v,
    ) {
      values.add(v);
      received.complete();
    });
    final failure = expectLater(work, throwsA(isA<ApiFailure>()));
    await adapter.connected.future;
    adapter.send({'text': '原账户首段'});
    await received.future;
    owner = 'b';
    adapter.send({'text': '不能进入新账户'});
    await failure;
    expect(values, [
      {'text': '原账户首段'},
    ]);
    await adapter.bytes.close();
  });

  test('完整分析不包含旧提示时，增量合并仍保留历史提示', () {
    final record = MeetingRecord(
      id: 'm',
      startedAt: DateTime.now(),
      demo: false,
      utterances: const [
        MeetingUtterance(
          id: 'u',
          speaker: '发言人 A',
          raw: '原范围仅双端',
          at: Duration.zero,
        ),
      ],
      insights: const [
        MeetingInsight(
          id: 'live',
          kind: InsightKind.risk,
          title: '范围待核对',
          body: '可能增加范围',
          evidenceIds: ['u'],
        ),
      ],
    );
    final merged = applyMeetingAnalysis(record, {
      'insights': [],
      'repairs': [],
    }, preserveInferences: true);
    expect(merged.insights.single.id, 'live');
    expect(merged.utterances.single.raw, record.utterances.single.raw);
  });
}
