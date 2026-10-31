import 'package:flutter/services.dart' as services;
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:go_router/go_router.dart';
import 'package:yanshu/app/app.dart';
import 'package:yanshu/features/meeting/meeting_services.dart';
import 'package:yanshu/features/meeting/speech_recognizer.dart';
import 'package:yanshu/features/meeting/meeting_view_model.dart';
import 'package:yanshu/features/meeting/meeting_store.dart';
import 'package:yanshu/features/profile/repositories/profile_repository.dart';
import 'package:yanshu/features/knowledge/repositories/knowledge_repository.dart';
import 'package:yanshu/features/recording_status/system_recording_activity.dart';

/// ASR is deliberately stubbed; PCM capture, input verification, FGS and OS notifications are real.
class _NoNetworkAsr implements MeetingSpeechRecognizer {
  int bytes = 0;
  @override
  Stream<MeetingTranscript> get transcripts => const Stream.empty();
  @override
  int get pendingMilliseconds => 0;
  @override
  Future<void> start() async {}
  @override
  void accept(Uint8List data) {
    bytes += data.length;
  }

  @override
  Future<void> flush() async {}
  @override
  Future<void> close() async {}
}

Future<void> main() async {
  if (const bool.fromEnvironment('MANUAL_RECORDING_STATUS_QA')) {
    WidgetsFlutterBinding.ensureInitialized();
    final cache = await getTemporaryDirectory();
    final dir = await Directory(
      '${cache.path}/recording-status-manual-qa',
    ).create();
    runApp(
      YanShuApp(
        initialLocation: '/profile/recording-device',
        connectRecordingCardToMeetings: true,
        profileRepository: ProfileRepository(MemoryProfileStore()),
        meetingStore: MemoryMeetingStore(),
        meetingRecorder: DeviceMeetingRecorder(
          directory: dir,
          recognizerFactory: (_) => _NoNetworkAsr(),
          recoverNetwork: false,
        ),
        knowledgeRepository: KnowledgeRepository(
          MemoryKnowledgeStore(),
          seedExamples: false,
        ),
      ),
    );
    return;
  }
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('real OS microphone/FGS/notification status with local ASR stub', (
    t,
  ) async {
    final cache = await getTemporaryDirectory();
    final dir = await Directory(
      '${cache.path}/recording-status-qa-${DateTime.now().microsecondsSinceEpoch}',
    ).create();
    final asr = _NoNetworkAsr();
    final recorder = DeviceMeetingRecorder(
      directory: dir,
      recognizerFactory: (_) => asr,
      recoverNetwork: false,
    );
    const system = NativeRecordingActivity();
    MeetingViewModel? vm;
    try {
      await t.pumpWidget(
        RepaintBoundary(
          key: const ValueKey('native-shot'),
          child: YanShuApp(
            initialLocation: '/meeting',
            connectRecordingCardToMeetings: false,
            profileRepository: ProfileRepository(MemoryProfileStore()),
            meetingStore: MemoryMeetingStore(),
            meetingRecorder: recorder,
            knowledgeRepository: KnowledgeRepository(
              MemoryKnowledgeStore(),
              seedExamples: false,
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      vm = t
          .element(find.byKey(const ValueKey('meeting-start-recording')))
          .read<MeetingViewModel>();
      final router = GoRouter.of(
        t.element(find.byKey(const ValueKey('meeting-start-recording'))),
      );
      final before = await system.capabilities();
      expect(before['serviceRunning'], false);
      await system.requestNotifications();
      for (var i = 0; i < 150; i++) {
        if ((await system.capabilities())['notificationsAllowed'] == true) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      await vm.start(demo: false);
      await t.pumpAndSettle();
      expect(vm.active, isTrue, reason: vm.error);
      expect(recorder.captureConfirmed, isTrue);
      for (var i = 0; i < 30 && asr.bytes == 0; i++) {
        await t.pump(const Duration(milliseconds: 100));
      }
      expect(asr.bytes, greaterThan(0));
      final input = recorder.inputRoute!;
      expect(input.verified, isTrue);
      expect(input.silenced, isFalse);
      var caps = await system.capabilities();
      for (var i = 0; i < 20 && caps['presentation'] == 'inAppOnly'; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        caps = await system.capabilities();
      }
      debugPrint('RECORDING_STATUS_CAPABILITIES ${jsonEncode(caps)}');
      expect(caps['serviceRunning'], true);
      expect(caps['presentation'], isIn(['ongoingNotification', 'liveUpdate']));
      if (const bool.fromEnvironment('RECORDING_STATUS_LOCKSCREEN_QA')) {
        debugPrint('RECORDING_STATUS_LOCKSCREEN_READY');
        // Allow the test operator to inspect the real system/lock-screen card.
        // No fake system surface is drawn by Flutter.
        await Future<void>.delayed(const Duration(seconds: 90));
      }
      router.go('/home');
      await t.pumpAndSettle();
      expect(router.routerDelegate.state.uri.path, '/home');
      final boundary = t.renderObject<RenderRepaintBoundary>(
        find.byKey(const ValueKey('native-shot')),
      );
      final im = await boundary.toImage(pixelRatio: 1);
      final png = await im.toByteData(format: ui.ImageByteFormat.png);
      final http = HttpClient();
      try {
        final request = await http.postUrl(
          Uri.parse('http://127.0.0.1:18776/banner'),
        );
        request.contentLength = png!.lengthInBytes;
        request.add(png.buffer.asUint8List());
        await (await request.close()).drain<void>();
      } finally {
        http.close(force: true);
        im.dispose();
      }
      // The lock-screen notification opens this same native intent/channel path.
      services.ServicesBinding.instance.channelBuffers.push(
        'agenote/recording_activity',
        const services.StandardMethodCodec().encodeMethodCall(
          services.MethodCall('openMeeting', vm.record!.id),
        ),
        (_) {},
      );
      await t.pumpAndSettle();
      expect(router.routerDelegate.state.uri.path, '/meeting');
      await vm.finish();
      await t.pumpAndSettle();
      caps = await system.capabilities();
      expect(caps['serviceRunning'], false);
      expect(caps['presentation'], 'inAppOnly');
      final result = {
        'platform': before['platform'],
        'apiLiveUpdates': before['liveUpdatesApi'],
        'recordingVerified': true,
        'sampleRate': input.sampleRate,
        'channels': input.channels,
        'actualPcmBytes': asr.bytes,
        'stoppedService': caps['serviceRunning'] == false,
        'asr': 'stub_not_verified',
      };
      binding.reportData = result;
      debugPrint('RECORDING_STATUS_NATIVE_QA ${jsonEncode(result)}');
    } finally {
      if (vm?.active == true) await vm!.finish();
      await t.pumpWidget(const SizedBox());
      if (await dir.exists()) await dir.delete(recursive: true);
    }
  });
}
