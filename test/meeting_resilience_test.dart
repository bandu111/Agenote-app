import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yanshu/core/network/api_client.dart';
import 'package:yanshu/features/meeting/meeting_models.dart';
import 'package:yanshu/features/meeting/meeting_remote.dart';
import 'package:yanshu/features/meeting/meeting_store.dart';
import 'dio_auth_repository_test.dart' show TestAdapter, envelope;

class BrokenEventClient extends ApiClient {
  BrokenEventClient({required super.baseUrl, super.dio});
  @override
  Stream<Map<String, dynamic>> postEvents(
    String path, {
    required Map<String, dynamic> data,
    required String accountId,
  }) async* {
    throw DioException(
      requestOptions: RequestOptions(path: path),
      type: DioExceptionType.receiveTimeout,
    );
  }
}

void main() {
  test('archive polling tolerates temporary outage without duplicate jobs', () async {
    var posts = 0, reads = 0;
    final client = BrokenEventClient(baseUrl: 'https://test.example/', dio: Dio()
      ..httpClientAdapter = TestAdapter((request) async {
        if (request.method == 'POST') {
          posts++;
          return (200, envelope({'id':'j', 'revision':1, 'status':'running'}));
        }
        reads++;
        if (reads <= 3) return (503, envelope(null, status:503));
        return (200, envelope({'id':'j', 'revision':1, 'status':'succeeded',
          'result':{'markdown':'# 已归档','revision':1}}));
      }))..accountId = () => 'owner';
    final remote = DioMeetingRepository(client, pollInterval: Duration.zero);
    final result = await remote.archive(MeetingRecord(id:'m', demo:false,
      startedAt:DateTime(2026), ownerId:'owner', syncRevision:1));
    expect(result['markdown'], '# 已归档');
    expect(posts, 1);
    expect(reads, 4);
    client.dio.close(force:true);
  });

  test('archive read retries connection errors but never hides forbidden response', () async {
    var reads = 0;
    var forbidden = false;
    final client = ApiClient(baseUrl:'https://test.example/', dio:Dio()
      ..httpClientAdapter = TestAdapter((request) async {
        reads++;
        if (forbidden) return (403, envelope(null, status:403));
        if (reads < 3) return (502, envelope(null, status:502));
        return (200, envelope({'revision':1, 'markdown':'# 已保存'}));
      }))..accountId = () => 'owner';
    final remote = DioMeetingRepository(client, pollInterval:Duration.zero);
    final record = MeetingRecord(id:'m',demo:false,startedAt:DateTime(2026),ownerId:'owner',syncRevision:1);
    expect((await remote.readArchive(record))!['markdown'], '# 已保存');
    expect(reads, 3);
    forbidden = true;
    await expectLater(remote.readArchive(record), throwsA(isA<Exception>()));
    expect(reads, 4);
    client.dio.close(force:true);
  });

  test(
    'SSE Dio timeout polls the same job and retry reuses submission',
    () async {
      var posts = 0, reads = 0;
      final client = BrokenEventClient(
        baseUrl: 'https://test.example/',
        dio: Dio()
          ..httpClientAdapter = TestAdapter((request) async {
            if (request.method == 'POST') {
              posts++;
              return (
                200,
                envelope({'id': 'job-1', 'revision': 1, 'status': 'running'}),
              );
            }
            reads++;
            if (reads == 1) return (503, envelope(null, status: 503));
            return (
              200,
              envelope({
                'id': 'job-1',
                'revision': 1,
                'status': 'succeeded',
                'result': {'analysis': <String, dynamic>{}},
              }),
            );
          }),
      )..accountId = () => 'owner';
      final remote = DioMeetingRepository(client, pollInterval: Duration.zero);
      final record = MeetingRecord(
        demo: false,
        id: 'meeting',
        startedAt: DateTime(2026),
        ownerId: 'owner',
        syncRevision: 1,
      );
      await remote.analyzeWithUpdates(record, (_) {});
      expect(posts, 1);
      expect(reads, 2);
      client.dio.close(force: true);
    },
  );

  test(
    'corrupt record does not block valid history; old empty lists load',
    () async {
      final folder = await Directory.systemTemp.createTemp(
        'meeting-resilience',
      );
      addTearDown(() => folder.delete(recursive: true));
      final store = LocalMeetingStore(directory: folder);
      await store.save(
        MeetingRecord(demo: false, id: 'valid', startedAt: DateTime(2026)),
      );
      final dir = Directory('${folder.path}/meetings');
      await File('${dir.path}/bad.json').writeAsString('{broken');
      await File('${dir.path}/old.json').writeAsString(
        jsonEncode({'id': 'old', 'startedAt': '2025-01-01T00:00:00'}),
      );
      final rows = await store.read();
      expect(rows.map((r) => r.id), containsAll(['valid', 'old']));
      expect(await File('${dir.path}/bad.json').exists(), true);
    },
  );

  test('malformed and unknown insight rows are skipped independently', () {
    final record = MeetingRecord(
      demo: false,
      id: 'meeting',
      startedAt: DateTime(2026),
    );
    final result = applyMeetingAnalysis(record, {
      'insights': [
        null,
        {'kind': 'future_kind'},
        {'id': 42, 'kind': 'risk'},
      ],
    });
    expect(result.insights, isEmpty);
    expect(
      parseMeetingInsights([
        null,
        {'kind': 'future_kind'},
      ]),
      isEmpty,
    );
  });
}
