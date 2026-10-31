import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:go_router/go_router.dart';
import 'package:yanshu/features/recording_status/recording_status_snapshot.dart';
import 'package:yanshu/features/recording_status/recording_activity_coordinator.dart';
import 'package:yanshu/features/recording_status/system_recording_activity.dart';
import 'package:yanshu/features/recording_status/recording_status_host.dart';
import 'package:yanshu/features/meeting/meeting_services.dart';
import 'package:yanshu/features/meeting/audio_input_route.dart';
import 'package:yanshu/features/meeting/meeting_view_model.dart';
import 'package:yanshu/features/meeting/meeting_store.dart';
import 'package:yanshu/features/home/viewmodels/home_view_model.dart';
import 'package:yanshu/features/knowledge/viewmodels/knowledge_view_model.dart';
import 'package:yanshu/features/knowledge/repositories/knowledge_repository.dart';
import 'package:yanshu/features/notifications/notification_model.dart';
import 'package:yanshu/features/profile/repositories/profile_repository.dart';
import 'package:yanshu/features/profile/viewmodels/profile_view_model.dart';
import 'package:yanshu/features/recording_device/recorder_device_view_model.dart';
import 'package:yanshu/features/recording_device/soninote_meeting_coordinator.dart';
import 'package:yanshu/app/theme/app_theme.dart';
import 'package:yanshu/app/app.dart';
import 'package:yanshu/features/home/views/home_page.dart';
import 'package:flutter/foundation.dart';
import 'meeting_test.dart' show FakeMeetingCalendar, FakeMeetingRecorder;
import 'support/recorder_device_fakes.dart';

class ActivityFake implements SystemRecordingActivity {
  final calls = <Map<String, dynamic>?>[];
  bool fail = false;
  Completer<void>? gate;
  @override
  Future<Map<String, dynamic>> synchronize(Map<String, dynamic>? s) async {
    calls.add(s);
    await gate?.future;
    if (fail) throw StateError('disabled');
    return {'presentation': 'inAppOnly'};
  }

  @override
  Future<Map<String, dynamic>> capabilities() async => {};
  @override
  Future<String?> takeOpenMeeting() async => null;
  @override
  Future<void> requestNotifications() async {}
}

class CaptureFake extends DeviceMeetingRecorder {
  int stops = 0;
  final events = StreamController<String>.broadcast(sync: true);
  bool confirmed = false, lost = false, pending = false;
  Completer<void>? startGate, flushGate;
  @override
  bool get captureConfirmed => confirmed;
  @override
  bool get inputLost => lost;
  @override
  bool get transcriptionPending => pending;
  @override
  Stream<String> get states => events.stream;
  @override
  Stream<double> get levels => const Stream.empty();
  @override
  Stream<MeetingTranscript> get transcripts => const Stream.empty();
  @override
  Future<String> start(String id) async {
    await startGate?.future;
    captureStopping = false;
    confirmed = true;
    backgroundActive = true;
    captureConfirmedAt = DateTime.now();
    return '/private/$id.wav';
  }

  @override
  Future<void> pause() async {
    confirmed = false;
  }

  @override
  Future<void> resume() async {
    confirmed = true;
  }

  @override
  Future<void> stop() async {
    stops++;
    confirmed = false;
    captureStopping = true;
    events.add('capture_stopped');
    await flushGate?.future;
  }

  @override
  Future<void> dispose() async {
    await events.close();
  }
}

class RestartCaptureFake extends FakeMeetingRecorder {
  final stateEvents = StreamController<String>.broadcast(sync: true);
  final levelEvents = StreamController<double>.broadcast(sync: true);
  @override
  Stream<String> get states => stateEvents.stream;
  @override
  Stream<double> get levels => levelEvents.stream;
  Completer<void>? startGate;
  @override
  Future<String> start(String id) async {
    await startGate?.future;
    return super.start(id);
  }
}

class Fixture {
  final capture = CaptureFake();
  final profile = ProfileViewModel(
    repository: ProfileRepository(MemoryProfileStore()),
  );
  final device = RecorderDeviceViewModel(
    DeviceServiceFake(),
    repository: MemoryRecorderRepository(),
  );
  final knowledge = KnowledgeViewModel(
    KnowledgeRepository(MemoryKnowledgeStore(), seedExamples: false),
  );
  final notifications = NotificationModel();
  final home = HomeViewModel();
  final platform = ActivityFake();
  late final vm = MeetingViewModel(
    store: MemoryMeetingStore(),
    recorder: capture,
    calendar: FakeMeetingCalendar(),
    knowledge: knowledge,
    notifications: notifications,
    home: home,
  );
  late final coordinator = RecordingActivityCoordinator(
    meeting: vm,
    profile: profile,
    device: device,
    platform: platform,
  );
  Future<void> init() async {
    await profile.load();
    await knowledge.load();
    await coordinator.settled;
  }

  void dispose() {
    coordinator.dispose();
    vm.dispose();
    device.dispose();
    knowledge.dispose();
    profile.dispose();
    notifications.dispose();
    home.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('xyz.luan/audioplayers.global/events'),
      (_) async => null,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('xyz.luan/audioplayers.global'),
      (_) async => null,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('xyz.luan/audioplayers'),
      (call) async {
        if (call.method == 'create') {
          final id = (call.arguments as Map)['playerId'];
          messenger.setMockMethodCallHandler(
            MethodChannel('xyz.luan/audioplayers/events/$id'),
            (_) async => null,
          );
        }
        return null;
      },
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('yanshu/soninote/events'),
          (_) async => null,
        );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(NativeRecordingActivity.channel, (
          call,
        ) async {
          if (call.method == 'takeOpenMeeting') return null;
          return <String, dynamic>{'presentation': 'inAppOnly'};
        });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('yanshu/soninote/events'),
          null,
        );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(NativeRecordingActivity.channel, null);
  });
  test(
    'only confirmed session starts status; connected hardware alone is not recording',
    () async {
      final f = Fixture();
      await f.init();
      expect(f.coordinator.snapshot, isNull);
      f.capture.startGate = Completer<void>();
      final start = f.vm.start(demo: false);
      expect(f.coordinator.snapshot, isNull);
      f.capture.startGate!.complete();
      await start;
      await f.coordinator.settled;
      expect(f.coordinator.snapshot!.capturing, isTrue);
      expect(f.platform.calls.whereType<Map>().length, 1);
      for (var i = 0; i < 100; i++) {
        f.coordinator.refresh();
      }
      await f.coordinator.settled;
      expect(f.platform.calls.whereType<Map>().length, 1);
      await f.vm.finish();
      await f.coordinator.settled;
      expect(f.coordinator.snapshot, isNull);
      expect(f.platform.calls.last, isNull);
      f.dispose();
    },
  );
  test(
    'ASR failure leaves recording true, audio loss does not, pause/resume keep ID',
    () async {
      final f = Fixture();
      await f.init();
      await f.vm.start(demo: false);
      final id = f.coordinator.snapshot!.meetingId;
      f.capture.pending = true;
      f.capture.events.add('transcription_pending');
      await f.coordinator.settled;
      expect(f.coordinator.snapshot!.capturing, isTrue);
      expect(f.coordinator.snapshot!.transcription, 'interrupted');
      await f.vm.pause();
      expect(f.coordinator.snapshot!.state, 'paused');
      await f.vm.resume();
      expect(f.coordinator.snapshot!.meetingId, id);
      f.capture.lost = true;
      f.capture.confirmed = false;
      f.capture.events.add('input_lost');
      await Future<void>.delayed(Duration.zero);
      expect(f.coordinator.snapshot!.capturing, isFalse);
      expect(f.coordinator.snapshot!.state, 'interrupted');
      await f.vm.finish();
      f.dispose();
    },
  );
  test(
    'platform disabled/errors never change capture; delayed start cannot outlive final end',
    () async {
      final f = Fixture();
      await f.init();
      f.platform.gate = Completer<void>();
      await f.vm.start(demo: false);
      final done = f.vm.finish();
      f.platform.gate!.complete();
      await done;
      await f.coordinator.settled;
      expect(f.platform.calls.last, isNull);
      f.platform.fail = true;
      await f.vm.start(demo: false);
      await f.coordinator.settled;
      expect(f.vm.active, isTrue);
      expect(f.coordinator.snapshot!.capturing, isTrue);
      expect(f.coordinator.platformError, isNotNull);
      await f.vm.finish();
      f.dispose();
    },
  );
  test('capture stop is published before slow ASR flush/archive', () async {
    final f = Fixture();
    await f.init();
    await f.vm.start(demo: false);
    f.capture.flushGate = Completer<void>();
    final finishing = f.vm.finish();
    await Future<void>.delayed(Duration.zero);
    await f.coordinator.settled;
    expect(f.coordinator.snapshot!.state, 'processing');
    expect(f.coordinator.snapshot!.capturing, isFalse);
    f.capture.flushGate!.complete();
    await finishing;
    await f.coordinator.settled;
    expect(f.coordinator.snapshot, isNull);
    f.dispose();
  });
  test('untrusted links cannot open/start arbitrary sessions', () {
    expect(
      recordingMeetingFromUri(Uri.parse('agenote://recording/abc-123')),
      'abc-123',
    );
    for (final text in [
      'https://recording/abc',
      'agenote://other/abc',
      'agenote://recording/a/b',
      'agenote://recording/%2F',
      'agenote://recording/abc?record=1',
      'agenote://recording/..%2Fetc',
    ]) {
      expect(recordingMeetingFromUri(Uri.parse(text)), isNull);
    }
  });
  test(
    'source metadata follows verified input and never leaks card fields into phone or headset',
    () async {
      final f = Fixture();
      await f.init();
      await f.vm.start(demo: false);
      f.device.info.battery = 78;
      f.device.info.firmware = '2.4.1';
      f.capture.inputRoute = const AudioInputRoute(
        id: 'phone',
        name: 'Built-in Mic',
        type: 'builtIn',
        verified: true,
        sampleRate: 16000,
        channels: 1,
      );
      f.coordinator.refresh();
      expect(f.coordinator.snapshot!.source, 'phone');
      expect(f.coordinator.snapshot!.details, {'audio': '16000 Hz · 1 声道'});
      f.capture.inputRoute = const AudioInputRoute(
        id: 'headset',
        name: 'X5 Pro',
        type: 'bluetooth',
        verified: true,
        sampleRate: 16000,
        channels: 1,
      );
      f.coordinator.refresh();
      expect(f.coordinator.snapshot!.sourceLabel, contains('X5 Pro'));
      expect(f.coordinator.snapshot!.details.containsKey('battery'), false);
      expect(f.coordinator.snapshot!.details.containsKey('firmware'), false);
      f.capture.inputRoute = const AudioInputRoute(
        id: 'usb',
        name: 'USB Audio',
        type: 'usb',
        verified: true,
      );
      f.coordinator.refresh();
      expect(f.coordinator.snapshot!.source, 'usb');
      expect(f.coordinator.snapshot!.sourceLabel, contains('USB Audio'));
      expect(f.coordinator.snapshot!.details.containsKey('battery'), false);
      f.capture.lost = true;
      f.coordinator.refresh();
      expect(f.coordinator.snapshot!.state, 'interrupted');
      expect(f.coordinator.snapshot!.capturing, false);
      await f.vm.finish();
      f.dispose();
    },
  );
  test(
    'physical start opens meeting once and shares the explicit App session',
    () async {
      final f = Fixture();
      await f.init();
      final sdk = f.device.service as DeviceServiceFake;
      await f.device.initialize();
      sdk.emit('bluetooth', {'authorized': true, 'enabled': true});
      await f.device.startScan();
      sdk.emit('discovered', {'name': 'CB08', 'productType': 'test'});
      await f.device.connect(f.device.devices.single);
      sdk.emit('connection', {'connected': true});
      await Future<void>.delayed(const Duration(milliseconds: 650));
      var navigations = 0;
      final hardware = SoniNoteMeetingCoordinator(
        device: f.device,
        meeting: f.vm,
        openMeeting: () => navigations++,
        sessionActive: () => true,
      );
      sdk.emit('button', {'button': '1'});
      sdk.emit('recording', {'state': 'recording'});
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(f.vm.active, true);
      expect(navigations, 1);
      final id = f.vm.record!.id;
      sdk.emit('button', {'button': '1'});
      sdk.emit('recording', {'state': 'recording'});
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(f.vm.record!.id, id);
      expect(navigations, 1);
      await hardware.startMeeting();
      expect(f.vm.record!.id, id);
      expect(navigations, 2);
      sdk.emit('recording', {'state': 'idle', 'saved': true});
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(f.vm.record!.ended, true);
      final stops = f.capture.stops;
      sdk.emit('recording', {'state': 'idle', 'saved': true});
      sdk.emit('recording', {'state': 'idle', 'saved': true});
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await f.vm.finish();
      expect(f.capture.stops, stops);
      expect(f.vm.record!.id, id);
      expect(navigations, 2);
      hardware.dispose();
      f.dispose();
    },
  );
  for (final spec in [
    (360.0, 780.0, 24.0, 1.0, Brightness.light),
    (393.0, 852.0, 59.0, 1.0, Brightness.light),
    (320.0, 640.0, 44.0, 2.0, Brightness.dark),
    (844.0, 390.0, 0.0, 1.0, Brightness.light),
  ]) {
    testWidgets(
      'native-only status leaves appbar, page insets, popup and navigation unchanged $spec',
      (t) async {
        final (w, h, inset, scale, brightness) = spec;
        t.view.physicalSize = Size(w, h);
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.resetPhysicalSize);
        addTearDown(t.view.resetDevicePixelRatio);
        final f = Fixture();
        await f.init();
        await f.vm.start(demo: false);
        final key = GlobalKey<NavigatorState>();
        final router = GoRouter(
          initialLocation: '/home',
          navigatorKey: key,
          routes: [
            GoRoute(
              path: '/home',
              builder: (ctx, _) => Scaffold(
                appBar: AppBar(
                  title: const Text('页面标题'),
                  actions: [
                    IconButton(
                      key: const ValueKey('action'),
                      onPressed: () => showDialog<void>(
                        context: ctx,
                        builder: (_) =>
                            const AlertDialog(content: Text('Existing modal')),
                      ),
                      icon: const Icon(Icons.search),
                    ),
                  ],
                ),
                body: const Column(children: [Text('Page content')]),
              ),
            ),
            GoRoute(
              path: '/meeting',
              builder: (_, _) =>
                  const Scaffold(body: Text('Existing recording page')),
            ),
          ],
        );
        await t.pumpWidget(
          MultiProvider(
            providers: [
              ChangeNotifierProvider.value(value: f.vm),
              ChangeNotifierProvider.value(value: f.profile),
              ChangeNotifierProvider.value(value: f.device),
            ],
            child: MaterialApp.router(
              theme: brightness == Brightness.dark
                  ? AppTheme.dark()
                  : AppTheme.light(),
              routerConfig: router,
              builder: (_, child) => MediaQuery(
                data: MediaQueryData(
                  size: Size(w, h),
                  padding: EdgeInsets.only(top: inset),
                  viewPadding: EdgeInsets.only(top: inset),
                  textScaler: TextScaler.linear(scale),
                  disableAnimations: true,
                ),
                child: RecordingStatusHost(router: router, child: child!),
              ),
            ),
          ),
        );
        await t.pumpAndSettle();
        expect(t.getTopLeft(find.text('页面标题')).dy, greaterThanOrEqualTo(inset));
        expect(t.takeException(), isNull);
        await t.tap(find.byKey(const ValueKey('action')));
        await t.pumpAndSettle();
        expect(find.text('Existing modal'), findsOneWidget);
        key.currentState!.pop();
        await t.pumpAndSettle();
        router.go('/meeting');
        await t.pumpAndSettle();
        await f.vm.finish();
        await t.pumpWidget(const SizedBox());
        router.dispose();
        f.dispose();
      },
    );
  }
  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    testWidgets('rapid restart never opens previous minutes $platform', (
      t,
    ) async {
      debugDefaultTargetPlatformOverride = platform;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final capture = RestartCaptureFake();
      await t.pumpWidget(
        YanShuApp(
          profileRepository: ProfileRepository(MemoryProfileStore()),
          meetingStore: MemoryMeetingStore(),
          meetingRecorder: capture,
          knowledgeRepository: KnowledgeRepository(
            MemoryKnowledgeStore(),
            seedExamples: false,
          ),
        ),
      );
      await t.pumpAndSettle();
      final home = t.element(find.byType(HomePage));
      final vm = home.read<MeetingViewModel>();
      final router = GoRouter.of(home);
      await vm.start(demo: false);
      unawaited(vm.finish());
      for (var tick = 0; tick < 20; tick++) {
        await t.pump(const Duration(milliseconds: 20));
      }
      var previousId = vm.record!.id;
      for (final hardware in [true, false, true, false]) {
        router.go('/home');
        await t.pumpAndSettle();
        capture.startGate = Completer<void>();
        if (hardware) unawaited(vm.start(demo: false));
        unawaited(
          router.push<void>(hardware ? '/meeting' : '/meeting?record=1'),
        );
        await t.pump(const Duration(milliseconds: 400));
        await t.pump(const Duration(milliseconds: 400));
        expect(router.routerDelegate.state.uri.path, '/meeting');
        expect(vm.busy, true);
        capture.startGate!.complete();
        for (var tick = 0; tick < 20; tick++) {
          await t.pump(const Duration(milliseconds: 20));
        }
        expect(vm.active, true);
        expect(vm.record!.id, isNot(previousId));
        expect(router.routerDelegate.state.uri.path, '/meeting');
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)),
        );
        await t.pumpAndSettle();
        expect(vm.busy, false, reason: 'startup must settle');
        final id = vm.record!.id;
        unawaited(vm.finish());
        for (var tick = 0; tick < 20; tick++) {
          await t.pump(const Duration(milliseconds: 20));
        }
        await t.pumpAndSettle();
        expect(vm.record!.ended, true, reason: vm.error);
        expect(router.routerDelegate.state.uri.path, '/meetings/$id/minutes');
        previousId = id;
      }
      await t.pumpWidget(const SizedBox());
      debugDefaultTargetPlatformOverride = null;
    });
    testWidgets(
      'leaving a pushed meeting by button and platform gesture preserves capture $platform',
      (t) async {
        debugDefaultTargetPlatformOverride = platform;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        final capture = CaptureFake();
        await t.pumpWidget(
          YanShuApp(
            profileRepository: ProfileRepository(MemoryProfileStore()),
            meetingStore: MemoryMeetingStore(),
            meetingRecorder: capture,
            knowledgeRepository: KnowledgeRepository(
              MemoryKnowledgeStore(),
              seedExamples: false,
            ),
          ),
        );
        await t.pumpAndSettle();
        final home = t.element(find.byType(HomePage));
        final vm = home.read<MeetingViewModel>();
        final router = GoRouter.of(home);
        await vm.start(demo: false);
        final id = vm.record!.id;
        unawaited(router.push<void>('/meeting'));
        await t.pumpAndSettle();
        await t.tap(find.byType(BackButton).first);
        await t.pumpAndSettle();
        expect(router.routerDelegate.state.uri.path, '/home');
        expect(vm.active, true);
        unawaited(router.push<void>('/meeting'));
        await t.pumpAndSettle();
        if (platform == TargetPlatform.iOS) {
          final size = t.view.physicalSize / t.view.devicePixelRatio;
          await t.dragFrom(
            Offset(1, size.height / 2),
            Offset(size.width * .85, 0),
          );
        } else {
          await t.binding.handlePopRoute();
        }
        await t.pumpAndSettle();
        expect(router.routerDelegate.state.uri.path, '/home');
        expect(vm.active, true);
        expect(vm.record!.id, id);
        await vm.finish();
        await t.pumpAndSettle();
        final stops = capture.stops;
        // Delayed native stop callbacks and repeated UI finish must not reopen
        // processing after the user has already returned home.
        capture.events.add('capture_stopped');
        capture.events.add('capture_stopped');
        await vm.finish();
        await t.pumpAndSettle();
        expect(capture.stops, stops);
        expect(router.routerDelegate.state.uri.path, '/home');
        expect(vm.record!.id, id);
        expect(vm.record!.ended, true);
        await t.pumpWidget(const SizedBox());
        debugDefaultTargetPlatformOverride = null;
      },
    );
  }
}
