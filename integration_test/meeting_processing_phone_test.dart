import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yanshu/app/app.dart';
import 'package:yanshu/core/network/api_client.dart';
import 'package:yanshu/core/network/api_config.dart';
import 'package:yanshu/features/meeting/meeting_remote.dart';
import 'package:yanshu/features/meeting/meeting_models.dart';
import 'package:yanshu/features/meeting/meeting_store.dart';
import 'package:yanshu/features/meeting/minutes/meeting_processing_view.dart';
import 'package:yanshu/features/profile/models/profile_data.dart';
import 'package:yanshu/features/profile/repositories/profile_repository.dart';
import '../test/support/minutes_fixture.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'cloud archive progress reaches real Android processing screen',
    (tester) async {
      final api = ApiClient(baseUrl: ApiEnvironment.cloudUrl);
      const password = 'Processing-Phone-QA-2026!';
      String? owner;
      final events = <Map<String, dynamic>>[];
      final watch = Stopwatch()..start();
      Future<void> waitFor(bool Function() condition) async {
        final limit = DateTime.now().add(const Duration(minutes: 5));
        while (!condition()) {
          if (DateTime.now().isAfter(limit)) fail('processing timeout');
          await tester.pump(const Duration(milliseconds: 100));
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      }

      try {
        final auth = (await api.post(
          'auth/register',
          data: {
            'name': '纪要进度临时测试',
            'email':
                'processing-${DateTime.now().microsecondsSinceEpoch}@example.com',
            'password': password,
          },
        ))['data'];
        owner = auth['user']['id'] as String;
        final token = auth['access_token'] as String;
        api.accountId = () => owner;
        api.accessToken = () async => token;
        final remote = DioMeetingRepository(api);
        remote.archiveProgress.addListener(() {
          final value = remote.archiveProgress.value;
          if (value != null) {
            events.add({
              'ms': watch.elapsedMilliseconds,
              'status': value['status'],
              'progress': value['progress'],
            });
            debugPrint('ARCHIVE_PROGRESS ${jsonEncode(events.last)}');
          }
        });
        final fixture = minutesFixture();
        final record = MeetingRecord(
          id: 'processing-phone-${DateTime.now().millisecondsSinceEpoch}',
          title: fixture.title,
          startedAt: DateTime.now(),
          demo: false,
          ended: true,
          ownerId: owner,
          elapsed: fixture.elapsed,
          syncRevision: 1,
          utterances: fixture.utterances,
        );
        await remote.sync(record, paused: false);
        final store = MemoryMeetingStore();
        await store.save(record);
        await tester.pumpWidget(
          YanShuApp(
            initialLocation: '/meetings/${record.id}/minutes?processing=1',
            profileRepository: ProfileRepository(
              MemoryProfileStore(
                value: jsonEncode(
                  ProfileData(accountId: owner, name: '进度验证').toJson(),
                ),
              ),
            ),
            meetingRemote: remote,
            meetingStore: store,
            connectRecordingCardToMeetings: false,
          ),
        );
        await waitFor(
          () => find.byType(MeetingProcessingView).evaluate().isNotEmpty,
        );
        await waitFor(
          () =>
              find.text('查看纪要').evaluate().isNotEmpty ||
              find.text('重新生成').evaluate().isNotEmpty,
        );
        expect(find.text('生成会议纪要失败'), findsNothing);
        await waitFor(() => find.text('100%').evaluate().isNotEmpty);
        expect(find.text('100%'), findsOneWidget);
        expect(
          events.any((e) => (e['progress'] as Map?)?['percent'] == 100),
          isTrue,
        );
        expect(
          events.any(
            (e) =>
                ((e['progress'] as Map?)?['percent'] as num? ?? 0) > 0 &&
                ((e['progress'] as Map?)?['percent'] as num? ?? 100) < 100,
          ),
          isTrue,
        );
        await tester.tap(find.text('查看纪要'));
        await tester.pumpAndSettle();
        expect(find.text('一页读懂会议'), findsOneWidget);
        expect(tester.takeException(), isNull);
        binding.reportData = {
          'actualCloud': true,
          'scriptedTranscript': true,
          'microphoneUsed': false,
          'events': events,
          'elapsedMs': watch.elapsedMilliseconds,
        };
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        if (owner != null) {
          await api.post(
            'auth/delete-account',
            authenticated: true,
            accountId: owner,
            data: {'current_password': password, 'confirmation': 'DELETE'},
          );
        }
        api.dio.close(force: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 8)),
  );
}
