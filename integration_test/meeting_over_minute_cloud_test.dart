import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:provider/provider.dart';
import 'package:go_router/go_router.dart';
import 'package:yanshu/app/app.dart';
import 'package:yanshu/core/network/api_client.dart';
import 'package:yanshu/core/network/api_config.dart';
import 'package:yanshu/features/knowledge/repositories/dio_knowledge_repository.dart';
import 'package:yanshu/features/meeting/meeting_recorder_factory.dart';
import 'package:yanshu/features/meeting/meeting_remote.dart';
import 'package:yanshu/features/meeting/meeting_store.dart';
import 'package:yanshu/features/meeting/meeting_view_model.dart';
import 'package:yanshu/features/profile/models/profile_data.dart';
import 'package:yanshu/features/profile/repositories/profile_repository.dart';
import 'live_meeting_flow_test.dart' show PublicPcmInput;

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    '70 seconds real-time PCM through cloud ASR, finish, sync and archive',
    (tester) async {
      final api = ApiClient(baseUrl: ApiEnvironment.cloudUrl);
      const password = 'Archive-70s-Isolated-2026!';
      String? owner;
      PublicPcmInput? input;
      MeetingViewModel? vm;
      try {
        final auth = (await api.post(
          'auth/register',
          data: {
            'name': '长于一分钟归档验证',
            'email':
                'archive70-${DateTime.now().microsecondsSinceEpoch}@example.com',
            'password': password,
          },
        ))['data'];
        owner = auth['user']['id'] as String;
        api.accountId = () => owner;
        api.accessToken = () async => auth['access_token'] as String;
        final wav = await rootBundle.load('assets/qa/asr_reference.wav');
        final pcm = wav.buffer.asUint8List(
          wav.offsetInBytes + 44,
          wav.lengthInBytes - 44,
        );
        final bytes = Uint8List(16000 * 2 * 70);
        for (var i = 0; i < bytes.length; i++) {
          bytes[i] = pcm[i % pcm.length];
        }
        input = PublicPcmInput(
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger,
          bytes,
        )..install();
        final remote = DioMeetingRepository(api);
        await tester.pumpWidget(
          YanShuApp(
            apiClient: api,
            meetingRemote: remote,
            meetingStore: MemoryMeetingStore(),
            meetingRecorder: createDeviceMeetingRecorder(
              apiClient: api,
              provider: 'tencent',
            ),
            knowledgeRepository: DioKnowledgeRepository(api),
            connectRecordingCardToMeetings: false,
            profileRepository: ProfileRepository(
              MemoryProfileStore(
                value: jsonEncode(
                  ProfileData(accountId: owner, name: '归档验证').toJson(),
                ),
              ),
            ),
          ),
        );
        await tester.pump(const Duration(seconds: 1));
        vm = tester
            .element(find.byType(Scaffold).first)
            .read<MeetingViewModel>();
        await vm.start(demo: false);
        final deadline = DateTime.now().add(const Duration(seconds: 100));
        while (input.offset < bytes.length &&
            DateTime.now().isBefore(deadline)) {
          await tester.pump(const Duration(milliseconds: 100));
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        expect(input.offset, bytes.length);
        expect(await vm.finish(), isTrue);
        expect(vm.record!.elapsed.inSeconds, greaterThanOrEqualTo(60));
        expect(vm.record!.utterances, isNotEmpty);
        // Reproduce the legacy live-finish bug: ended locally but upload held.
        vm.record = vm.record!.copy(offlineSyncHeld: true);
        await vm.store.save(vm.record!);
        final homeContext = tester.element(find.byType(Scaffold).first);
        GoRouter.of(homeContext).go('/meetings/${vm.record!.id}/minutes?processing=1');
        final generationDeadline = DateTime.now().add(const Duration(minutes: 5));
        while (find.text('查看纪要').evaluate().isEmpty && DateTime.now().isBefore(generationDeadline)) {
          await tester.pump(const Duration(milliseconds: 100));
          await Future<void>.delayed(const Duration(milliseconds: 100));
          if (find.text('重新生成').evaluate().isNotEmpty) break;
        }
        expect(find.text('生成会议纪要失败'), findsNothing);
        expect(find.text('查看纪要'), findsOneWidget);
        expect(vm.record!.offlineSyncHeld, isFalse);
        expect(vm.cloudError, isNull);
        final saved = vm.record!;
        final cloud =
            (await api.get(
                  'meetings/${saved.id}',
                  authenticated: true,
                  accountId: owner,
                ))['data']
                as Map;
        expect(cloud['ended'], isTrue);
        final archive = await remote.readArchive(saved);
        expect(archive, isNotNull);
        expect(archive!['markdown'], isNotEmpty);
        binding.reportData = {
          'realCloudASR': true,
          'microphoneUsed': false,
          'input': 'local reference PCM repeated at real-time speed',
          'elapsedSeconds': saved.elapsed.inSeconds,
          'utteranceCount': saved.utterances.length,
          'serverEnded': cloud['ended'],
          'archiveVerified': true,
        };
        debugPrint('OVER_MINUTE_RESULT ${jsonEncode(binding.reportData)}');
      } finally {
        input?.timer?.cancel();
        await vm?.suspendForLogout();
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
    timeout: const Timeout(Duration(minutes: 12)),
  );
}
