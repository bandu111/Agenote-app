import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yanshu/app/app.dart';
import 'package:yanshu/core/network/api_client.dart';
import 'package:yanshu/features/knowledge/repositories/dio_knowledge_repository.dart';
import 'package:yanshu/features/meeting/local_speech.dart';
import 'package:yanshu/features/meeting/meeting_models.dart';
import 'package:yanshu/features/meeting/meeting_remote.dart';
import 'package:yanshu/features/meeting/meeting_store.dart';
import 'package:yanshu/features/meeting/minutes/meeting_minutes_data.dart';
import 'package:yanshu/features/meeting/minutes/meeting_minutes_page.dart';
import 'package:yanshu/features/profile/models/profile_data.dart';
import 'package:yanshu/features/profile/repositories/profile_repository.dart';
import '../test/support/minutes_fixture.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  testWidgets('真实后端纪要与原始音频分段在Android显示定位并回放', (tester) async {
    final api = ApiClient(baseUrl: 'http://127.0.0.1:18861/api/v1/');
    const password = 'Minutes-device-test-2026';
    String? owner;
    final checks = <String, bool>{};
    final report = <String, dynamic>{
      'isolatedAccount': true,
      'scriptedTranscript': true,
      'syntheticTestTone': true,
      'microphoneUsed': false,
      'checks': checks,
    };
    Future<void> waitFor(bool Function() check, {int seconds = 60}) async {
      final end = DateTime.now().add(Duration(seconds: seconds));
      while (DateTime.now().isBefore(end)) {
        await tester.pump(const Duration(milliseconds: 100));
        if (check()) return;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      fail('真机等待超时');
    }

    try {
      final auth = (await api.post(
        'auth/register',
        data: {
          'name': '纪要真机验证',
          'email':
              'minutes-${DateTime.now().microsecondsSinceEpoch}@example.com',
          'password': password,
        },
      ))['data'];
      owner = auth['user']['id'] as String;
      final token = auth['access_token'] as String;
      api.accountId = () => owner;
      api.accessToken = () async => token;
      final fixture = minutesFixture();
      final record = MeetingRecord(
        id: 'phone-minutes',
        title: fixture.title,
        startedAt: DateTime.now(),
        demo: false,
        ownerId: owner,
        ended: true,
        elapsed: fixture.elapsed,
        syncRevision: 1,
        utterances: [
          for (final u in fixture.utterances)
            MeetingUtterance(
              id: u.id,
              speaker: u.speaker,
              raw: u.raw,
              at: u.at + const Duration(seconds: 3),
            ),
        ],
      );
      final remote = DioMeetingRepository(api);
      await remote.sync(record, paused: false);
      final archive = await remote.archive(record);
      expect(archive['details'], isA<Map>());
      final details = Map<String, dynamic>.from(archive['details']);
      expect(details['topics'], isNotEmpty);
      checks['realModelStructuredMinutesAndMarkdown'] =
          archive['markdown'] is String;
      // Each original-source range has an actual tiny WAV on the server. No pretend speech or ASR result.
      final pcm = ByteData(96000);
      for (var i = 0; i < 48000; i++) {
        pcm.setInt16(
          i * 2,
          (math.sin(i * 2 * math.pi * 440 / 16000) * 100).round(),
          Endian.little,
        );
      }
      final bytes = Uint8List.fromList([
        ...meetingWavHeader(96000),
        ...pcm.buffer.asUint8List(),
      ]);
      // Unique recordings are required: one recording cannot represent multiple unrelated timeline offsets.
      for (final u in record.utterances) {
        final perSource = Uint8List.fromList(bytes);
        perSource[44] = u.id.codeUnits.last;
        final hash = await _hash(perSource);
        final initialized = (await api.post(
          'meetings/${record.id}/audio',
          authenticated: true,
          accountId: owner,
          data: {
            'sha256': hash,
            'size': perSource.length,
            'sources': [
              {
                'id': u.id,
                'hash': await _textHash(u.raw),
                'start': 0,
                'end': 3000,
              },
            ],
          },
        ))['data'];
        final id = initialized['id'];
        await api.post(
          'meetings/audio/$id/chunk',
          authenticated: true,
          accountId: owner,
          data: {'offset': 0, 'data': base64Encode(perSource)},
        );
        await api.post(
          'meetings/audio/$id/complete',
          authenticated: true,
          accountId: owner,
        );
      }
      final restored = (await remote.history()).singleWhere(
        (r) => r.id == record.id,
      );
      final saved = restored.copy(
        cloudMinutes: archive['markdown'] as String,
        minutesDetails: details,
      );
      final store = MemoryMeetingStore();
      await store.save(saved);
      final profile = ProfileRepository(
        MemoryProfileStore(
          value: jsonEncode(
            ProfileData(accountId: owner, name: '纪要验证').toJson(),
          ),
        ),
      );
      await tester.pumpWidget(
        YanShuApp(
          initialLocation: '/meeting?id=${saved.id}',
          profileRepository: profile,
          knowledgeRepository: DioKnowledgeRepository(api),
          meetingRemote: remote,
          meetingStore: store,
          connectRecordingCardToMeetings: false,
        ),
      );
      await waitFor(
        () => find.byType(MeetingMinutesPage).evaluate().isNotEmpty,
      );
      await waitFor(() => find.text('一页读懂会议').evaluate().isNotEmpty);
      checks['historyUsesMinutesInsteadOfOldRecordingPage'] = true;
      debugPrint('MINUTES_STAGE summary');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('思维导图'));
      await tester.pump(const Duration(milliseconds: 400));
      await waitFor(() => find.text('会议结构').evaluate().isNotEmpty);
      checks['mindmapTab'] = true;
      await tester.pump(const Duration(milliseconds: 500));
      debugPrint('MINUTES_STAGE mindmap');
      await tester.tap(find.text('AI 纪要'));
      await tester.pump(const Duration(milliseconds: 400));
      debugPrint('MINUTES_STAGE summary_returned');
      final link = find.textContaining('查看原始依据').first;
      await Scrollable.ensureVisible(
        tester.element(link),
        alignment: .5,
        duration: Duration.zero,
      );
      await tester.pump(const Duration(milliseconds: 300));
      debugPrint('MINUTES_STAGE source_scrolled');
      await tester.tap(link);
      await tester.pump();
      debugPrint('MINUTES_STAGE source_tapped');
      await waitFor(() => find.text('正在回听').evaluate().isNotEmpty, seconds: 30);
      checks['sourceSwitchesTranscriptAndNativeAudioPlays'] = true;
      debugPrint('MINUTES_STAGE source_playback');
      expect(tester.takeException(), isNull);
      checks['noFlutterExceptions'] = true;
      final short = record.copy(elapsed: const Duration(seconds: 59));
      final shortBody = {
        ...meetingSyncPayload(short, paused: false),
        'id': 'phone-short',
      };
      await api.post(
        'meetings/sync',
        authenticated: true,
        accountId: owner,
        data: shortBody,
      );
      final skipped = (await api.post(
        'meetings/phone-short/archive',
        authenticated: true,
        accountId: owner,
      ))['data'];
      expect(skipped['reason'], 'meeting_too_short');
      checks['underOneMinuteDoesNotGenerateMinutes'] = true;
      final source = MeetingMinutesData.fromRecord(
        saved,
      ).topics.first.evidenceIds.first;
      expect(
        saved.utterances.singleWhere((u) => u.id == source).hasAudio,
        true,
      );
      checks['originalSliceReferencesRetained'] = true;
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 300));
      if (owner != null) {
        await api.post(
          'auth/delete-account',
          authenticated: true,
          accountId: owner,
          data: {'current_password': password, 'confirmation': 'DELETE'},
        );
        checks['temporaryAccountRemoved'] = true;
      }
      binding.reportData = {...?binding.reportData, ...report};
      api.dio.close(force: true);
    }
  }, timeout: const Timeout(Duration(minutes: 6)));
}

// Small fixtures only; no external corpus or large recordings are downloaded.
Future<String> _hash(List<int> value) async => sha256.convert(value).toString();
Future<String> _textHash(String value) async =>
    sha256.convert(utf8.encode(value)).toString();
