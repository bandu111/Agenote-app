import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yanshu/core/network/api_client.dart';
import 'package:yanshu/features/meeting/meeting_models.dart';
import 'package:yanshu/features/meeting/meeting_remote.dart';
import 'dio_auth_repository_test.dart' show envelope;

class JobEventsAdapter implements HttpClientAdapter {
  final output = StreamController<Uint8List>();
  final paths = <String>[];
  final attached = Completer<void>();
  bool unavailable = false;
  Map<String, dynamic> job(String status) => {
    'id': 'j1',
    'revision': 0,
    'operation': 'analysis',
    'status': status,
    'result': status == 'succeeded' ? {'analysis': <String, dynamic>{}} : null,
    'error': null,
  };
  void push(Map<String, dynamic> value) => output.add(
    Uint8List.fromList(
      utf8.encode('data: ${jsonEncode({'event': 'job', 'data': value})}\n\n'),
    ),
  );
  @override
  void close({bool force = false}) {}
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    paths.add(options.path);
    if (options.path.endsWith('/events') && !unavailable) {
      attached.complete();
      return ResponseBody(
        output.stream,
        200,
        headers: {
          'content-type': ['text/event-stream'],
        },
      );
    }
    if (options.path.endsWith('/events')) {
      return ResponseBody.fromString('{}', 404);
    }
    return ResponseBody.fromString(
      jsonEncode(
        envelope(job(options.path.endsWith('/jobs') ? 'running' : 'succeeded')),
      ),
      200,
      headers: {
        'content-type': ['application/json'],
      },
    );
  }
}

void main() {
  test('模型正文增量不等待两秒轮询，也不等待完整分析结束', () async {
    final adapter = JobEventsAdapter();
    final client =
        ApiClient(
            baseUrl: 'https://test.example/',
            dio: Dio()..httpClientAdapter = adapter,
          )
          ..accountId = (() => 'owner')
          ..accessToken = (() async => 'synthetic-token');
    final remote = DioMeetingRepository(
      client,
      pollInterval: const Duration(hours: 1),
    );
    final record = MeetingRecord(
      id: 'm',
      startedAt: DateTime(2026),
      ownerId: 'owner',
      demo: false,
    );
    final seen = Completer<void>();
    final texts = <String>[];
    var done = false;
    final result = remote
        .analyzeWithUpdates(record, (value) {
          texts.add((value['insights'] as List).single['body'] as String);
          if (!seen.isCompleted) seen.complete();
        })
        .whenComplete(() => done = true);
    await adapter.attached.future;
    Map<String, dynamic> preview(String text) => {
      ...adapter.job('running'),
      'preview': {
        'kind': 'source_checked_inference_only',
        'insights': [
          {'body': text},
        ],
      },
    };
    adapter.push(preview('建议'));
    await seen.future.timeout(const Duration(seconds: 2));
    expect(done, isFalse);
    adapter.push(preview('建议确认交期'));
    adapter.push(adapter.job('succeeded'));
    await result.timeout(const Duration(seconds: 2));
    expect(texts, ['建议', '建议确认交期']);
    expect(adapter.paths, ['meetings/m/jobs', 'meetings/jobs/j1/events']);
    await adapter.output.close();
    client.dio.close(force: true);
  });

  test('旧服务端不支持事件时，继续查询同一个任务而非重新提交', () async {
    final adapter = JobEventsAdapter()..unavailable = true;
    final client =
        ApiClient(
            baseUrl: 'https://test.example/',
            dio: Dio()..httpClientAdapter = adapter,
          )
          ..accountId = (() => 'owner')
          ..accessToken = (() async => 'synthetic-token');
    final remote = DioMeetingRepository(client, pollInterval: Duration.zero);
    await remote.analyzeWithUpdates(
      MeetingRecord(
        id: 'm',
        startedAt: DateTime(2026),
        ownerId: 'owner',
        demo: false,
      ),
      (_) {},
    );
    expect(adapter.paths, [
      'meetings/m/jobs',
      'meetings/jobs/j1/events',
      'meetings/jobs/j1',
    ]);
    client.dio.close(force: true);
  });
}
