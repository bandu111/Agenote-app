import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:provider/provider.dart';
import 'package:yanshu/app/app.dart';
import 'package:yanshu/core/network/api_client.dart';
import 'package:yanshu/core/network/api_config.dart';
import 'package:yanshu/features/knowledge/repositories/knowledge_repository.dart';
import 'package:yanshu/features/meeting/meeting_models.dart';
import 'package:yanshu/features/meeting/meeting_page.dart';
import 'package:yanshu/features/meeting/meeting_services.dart';
import 'package:yanshu/features/meeting/meeting_store.dart';
import 'package:yanshu/features/meeting/meeting_view_model.dart';
import 'package:yanshu/features/profile/models/profile_data.dart';
import 'package:yanshu/features/profile/repositories/profile_repository.dart';
import 'package:yanshu/features/recording_device/recorder_device_page.dart';
import 'package:yanshu/features/recording_device/recorder_device_view_model.dart';
import 'package:yanshu/features/recording_device/recorder_models.dart';

class _LiveLifecycleProbe with WidgetsBindingObserver {
  final states = <AppLifecycleState>[];
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) => states.add(state);
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'CB08 starts a real meeting and streams its own audio to Tencent ASR',
    (tester) async {
      final report = <String, dynamic>{
        'sdkMocked': false,
        'asrMocked': false,
        'phoneMicrophoneUsed': false,
        'separateTestAccount': true,
      };
      final checks = <String, bool>{};
      report['checks'] = checks;
      final api = ApiClient(baseUrl: ApiEnvironment.cloudUrl);
      const password = 'SoniNote-device-qa-only-2026';
      String? owner;
      RecorderDeviceViewModel? card;
      MeetingViewModel? meeting;
      Future<void> waitFor(
        bool Function() condition, {
        int seconds = 30,
      }) async {
        final deadline = DateTime.now().add(Duration(seconds: seconds));
        while (DateTime.now().isBefore(deadline)) {
          await tester.pump(const Duration(milliseconds: 50));
          if (condition()) return;
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        fail('硬件会议状态等待超时');
      }

      try {
        final registered = (await api.post(
          'auth/register',
          data: {
            'email':
                'soninote-live-${DateTime.now().microsecondsSinceEpoch}@example.com',
            'name': '录音卡联调',
            'password': password,
          },
        ))['data'];
        owner = registered['user']['id'] as String;
        final token = registered['access_token'] as String;
        api.accountId = () => owner;
        api.accessToken = () async => token;
        await tester.pumpWidget(
          YanShuApp(
            initialLocation: '/profile/recording-device',
            apiClient: api,
            profileRepository: ProfileRepository(
              MemoryProfileStore(
                value: jsonEncode(
                  ProfileData(accountId: owner, name: '录音卡联调').toJson(),
                ),
              ),
            ),
            knowledgeRepository: KnowledgeRepository(
              MemoryKnowledgeStore(),
              seedExamples: false,
            ),
            meetingStore: MemoryMeetingStore(),
          ),
        );
        await waitFor(
          () => find.byType(RecorderDevicePage).evaluate().isNotEmpty,
        );
        final context = tester.element(find.byType(RecorderDevicePage));
        card = context.read<RecorderDeviceViewModel>();
        meeting = context.read<MeetingViewModel>();
        final device = card;
        final vm = meeting;
        await device.initialize();
        if (!device.permissionGranted) await device.requestPermissions();
        await waitFor(
          () => device.permissionGranted && device.bluetoothEnabled,
        );
        await device.startScan();
        await waitFor(() => device.devices.isNotEmpty);
        expect(device.devices.length, 1);
        await device.connect(device.devices.single);
        await waitFor(
          () => device.connected && device.recording != RecorderState.unknown,
        );
        expect(device.recording, RecorderState.idle);
        checks['realCardConnectedIdle'] = true;
        final start = find.text('开始录音');
        await tester.ensureVisible(start);
        await tester.tap(start);
        await waitFor(() => find.byType(MeetingPage).evaluate().isNotEmpty);
        checks['appStartNavigatesToMeeting'] = true;
        await waitFor(
          () => vm.phase == MeetingPhase.recording || vm.error != null,
          seconds: 45,
        );
        expect(vm.error, isNull);
        expect(vm.inputStatus, '录音卡麦克风');
        final recorder = vm.recorder as DeviceMeetingRecorder;
        expect(recorder.usingExternalInput, true);
        checks['realOpusDecodedAndCardInputVerified'] = true;
        if (const bool.fromEnvironment('SONINOTE_LIVE_TEST_RECOVERY')) {
          final lifecycle = _LiveLifecycleProbe();
          WidgetsBinding.instance.addObserver(lifecycle);
          try {
            for (final stage in ['BACKGROUND', 'LOCKSCREEN']) {
              lifecycle.states.clear();
              final before = recorder.diagnostics['samples'] as int;
              debugPrint('SONINOTE_MEETING_QA_$stage');
              await waitFor(
                () =>
                    lifecycle.states.contains(AppLifecycleState.paused) &&
                    lifecycle.states.contains(AppLifecycleState.resumed),
                seconds: 45,
              );
              final after = recorder.diagnostics['samples'] as int;
              report['${stage.toLowerCase()}AudioSamples'] = after - before;
              expect(
                after - before,
                greaterThan(16000 * 2),
                reason: '后台或锁屏期间应继续收到真实录音卡 PCM',
              );
              expect(vm.phase, MeetingPhase.recording);
              checks['real${stage}AudioContinues'] = true;
            }
            debugPrint('SONINOTE_MEETING_QA_BLUETOOTH_OFF');
            await waitFor(
              () => vm.phase == MeetingPhase.paused && !device.connected,
            );
            expect(vm.inputStatus, '采音设备已断开');
            checks['disconnectPausesMeetingWithoutPhoneFallback'] = true;
            debugPrint('SONINOTE_MEETING_QA_BLUETOOTH_ON');
            await waitFor(() => device.bluetoothEnabled);
            await device.startScan();
            await waitFor(() => device.devices.isNotEmpty);
            expect(device.devices.length, 1);
            await device.connect(device.devices.single);
            await waitFor(
              () =>
                  device.connected && device.recording != RecorderState.unknown,
            );
            await vm.resume();
            await waitFor(() => vm.phase == MeetingPhase.recording);
            expect(vm.inputStatus, '录音卡麦克风');
            expect(recorder.usingExternalInput, true);
            expect(vm.record!.audioPaths.length, 2);
            await waitFor(
              () => (recorder.diagnostics['samples'] as int) >= 16000,
            );
            checks['reconnectedMeetingRetainsRecordingCardInput'] = true;
          } finally {
            WidgetsBinding.instance.removeObserver(lifecycle);
          }
        } else {
          debugPrint('SONINOTE_MEETING_QA_READ_NOW');
          await waitFor(
            () => vm.record!.utterances.any((u) => u.raw.trim().length > 5),
            seconds: 180,
          );
          report['transcriptCharacters'] = vm.record!.utterances.fold<int>(
            0,
            (n, u) => n + u.raw.length,
          );
          checks['realTencentTranscriptFromRecordingCard'] = true;
        }
        // Leave enough time for a complete spoken test sentence before stopping.
        for (var i = 0; i < 40; i++) {
          await tester.pump(const Duration(milliseconds: 50));
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        expect(await vm.finish(), true);
        await waitFor(() => device.recording == RecorderState.idle);
        var wavBytes = 0;
        for (final path in vm.record!.audioPaths) {
          final wav = File(path);
          expect(await wav.length(), greaterThan(3244));
          wavBytes += await wav.length();
        }
        report['wavBytes'] = wavBytes;
        checks['meetingFinishStopsCardAndPersistsWav'] = true;
        if (const bool.fromEnvironment('SONINOTE_LIVE_TEST_PHYSICAL')) {
          debugPrint('SONINOTE_MEETING_QA_PHYSICAL_START');
          final previous = vm.record!.id;
          await waitFor(
            () => vm.active && vm.record!.id != previous,
            seconds: 180,
          );
          expect(vm.inputStatus, '录音卡麦克风');
          checks['physicalStartCreatesNewCardMeeting'] = true;
          expect(find.byType(MeetingPage), findsOneWidget);
          await waitFor(() => (recorder.diagnostics['samples'] as int) > 16000);
          expect(await vm.finish(), true);
          await waitFor(() => device.recording == RecorderState.idle);
          checks['physicalMeetingStoppedAndSaved'] = true;
        }
        report['passed'] = true;
      } catch (error) {
        report['passed'] = false;
        report['error'] = error.toString();
        report['meetingError'] = meeting?.error;
        report['cardError'] = card?.error;
        rethrow;
      } finally {
        if (meeting?.active == true) {
          await meeting!.finish();
        }
        if (card?.connected == true) {
          if (card!.recording != RecorderState.idle) {
            await card.stopRecording();
          }
          await card.disconnect();
        }
        if (owner != null) {
          try {
            await api.post(
              'auth/delete-account',
              authenticated: true,
              accountId: owner,
              data: {'current_password': password, 'confirmation': 'DELETE'},
            );
            report['testAccountDeleted'] = true;
          } catch (_) {
            report['testAccountDeleted'] = false;
          }
        }
        binding.reportData = report;
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      }
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
