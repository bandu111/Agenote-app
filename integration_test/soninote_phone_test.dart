import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:integration_test/integration_test.dart';
import 'package:provider/provider.dart';
import 'package:yanshu/app/app.dart';
import 'package:yanshu/features/knowledge/repositories/knowledge_repository.dart';
import 'package:yanshu/features/profile/repositories/profile_repository.dart';
import 'package:yanshu/features/recording_device/recorder_device_page.dart';
import 'package:yanshu/features/recording_device/recorder_device_add_sheet.dart';
import 'package:yanshu/features/recording_device/recorder_device_view_model.dart';
import 'package:yanshu/features/recording_device/recorder_models.dart';

class _LifecycleProbe with WidgetsBindingObserver {
  final states = <AppLifecycleState>[];
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) => states.add(state);
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('Android真实SDK：手机侧流程及可选CB08硬件验证', (tester) async {
    final checks = <String, bool>{};
    final report = <String, dynamic>{
      'sdkMocked': false,
      'isolatedLocalProfile': true,
      'cloudApiUsed': false,
      'phoneMicrophoneUsed': false,
      'hardwareConnected': false,
      'recordingCommandSent': false,
      'firmwareModified': false,
      'checks': checks,
    };
    void save() {
      final screenshots = binding.reportData?['screenshots'];
      if (screenshots != null) report['screenshots'] = screenshots;
      binding.reportData = report;
    }

    Future<void> waitFor(bool Function() condition, {int seconds = 30}) async {
      for (var i = 0; i < seconds * 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        if (condition()) return;
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      fail('真机状态等待超时');
    }

    var converted = false;
    Future<void> screenshot(String name) async {
      // Surface-to-image capture affects the live Android surface. Keep the
      // normal surface while a person follows physical-button instructions.
      if (const bool.fromEnvironment('SONINOTE_TEST_PHYSICAL')) return;
      if (!converted) {
        await binding.convertFlutterSurfaceToImage();
        converted = true;
      }
      await tester.pump(const Duration(milliseconds: 300));
      await binding.takeScreenshot(name);
    }

    Future<void> tapText(String label) async {
      final target = find.text(label);
      await tester.ensureVisible(target);
      await tester.pump(const Duration(milliseconds: 200));
      await tester.tap(target);
      await tester.pump();
    }

    Future<void> physicalButtons(
      RecorderDeviceViewModel device,
      BuildContext context,
    ) async {
      final instruction = ValueNotifier('等待按键验证');
      var skipped = false;
      final buttons = <String>[];
      final observations = <Map<String, dynamic>>[];
      report['buttonObservations'] = observations;
      final subscription = device.service.events.listen((event) {
        if (event.type == 'button_observed') {
          observations.add({
            'button': event.data['button'],
            'atMs': event.data['atMs'],
          });
        }
        if (event.type == 'button') buttons.add('${event.data['button']}');
      });
      final overlay = OverlayEntry(
        builder: (_) => Positioned(
          top: MediaQuery.paddingOf(context).top + 10,
          left: 12,
          right: 12,
          child: Material(
            elevation: 3,
            borderRadius: BorderRadius.circular(16),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ValueListenableBuilder(
                    valueListenable: instruction,
                    builder: (_, text, _) =>
                        Text(text, style: const TextStyle(fontSize: 18)),
                  ),
                  TextButton(
                    onPressed: () => skipped = true,
                    child: const Text('设备不支持／跳过'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      // Integration tests drop real screen touches by default. The manual
      // hardware stage must let the user operate the skip button.
      final previousPointerPolicy = binding.shouldPropagateDevicePointerEvents;
      binding.shouldPropagateDevicePointerEvents = true;
      Overlay.of(context).insert(overlay);
      try {
        for (final step in [
          ('1', RecorderState.recording, '开始录音'),
          ('5', RecorderState.paused, '暂停录音'),
          ('7', RecorderState.recording, '继续录音'),
          ('3', RecorderState.idle, '停止并保存'),
        ]) {
          skipped = false;
          final before = buttons.length;
          instruction.value = '请在 CB08 上执行：${step.$3}';
          debugPrint('SONINOTE_QA_PHYSICAL_${step.$1}');
          await waitFor(
            () =>
                skipped ||
                (device.recording == step.$2 &&
                    buttons.skip(before).contains(step.$1)),
            seconds: 180,
          );
          report['physicalButton_${step.$1}'] = skipped
              ? 'skipped'
              : 'sdk_button_and_state_confirmed';
          if (skipped) break;
        }
        report['physicalButtonEvents'] = buttons;
      } finally {
        binding.shouldPropagateDevicePointerEvents = previousPointerPolicy;
        report['physicalButtonEvents'] = buttons;
        overlay.remove();
        overlay.dispose();
        instruction.dispose();
        await subscription.cancel();
      }
    }

    RecorderDeviceViewModel? model;
    try {
      await tester.pumpWidget(
        YanShuApp(
          connectRecordingCardToMeetings: false,
          initialLocation: '/profile',
          profileRepository: ProfileRepository(MemoryProfileStore()),
          knowledgeRepository: KnowledgeRepository(
            MemoryKnowledgeStore(),
            seedExamples: false,
          ),
        ),
      );
      await waitFor(
        () => find
            .byKey(const ValueKey('profile-recording-device'))
            .evaluate()
            .isNotEmpty,
      );
      final entry = find.byKey(const ValueKey('profile-recording-device'));
      await tester.ensureVisible(entry);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(entry);
      await waitFor(
        () => find.byType(RecorderDevicePage).evaluate().isNotEmpty,
      );
      final page = tester.element(find.byType(RecorderDevicePage));
      final router = GoRouter.of(page);
      model = page.read<RecorderDeviceViewModel>();
      final device = model;
      await device.initialize();
      await waitFor(() => !device.initializing);
      expect(device.error, isNull);
      checks['profileRouteAndNativeChannel'] = true;
      report['initialPermissionGranted'] = device.permissionGranted;
      await tester.tap(find.byTooltip('添加设备'));
      await waitFor(
        () => find.byType(RecorderDeviceAddSheet).evaluate().isNotEmpty,
      );
      if (!device.permissionGranted) {
        await device.startScan();
        expect(device.scanning, false);
        expect(device.error, contains('允许蓝牙'));
        checks['unauthorizedScanBlocked'] = true;
        await screenshot('permission-required');
        await tapText('允许蓝牙访问');
        await waitFor(() => device.permissionGranted, seconds: 45);
      }
      checks['realAndroidNearbyPermission'] = device.permissionGranted;
      report['bluetoothEnabled'] = device.bluetoothEnabled;
      expect(device.bluetoothEnabled, true, reason: '需开启手机系统蓝牙后才能验收真实扫描');
      if (!device.scanning) await device.startScan();
      expect(device.scanning, true);
      await waitFor(() => !device.scanning, seconds: 22);
      expect(device.error, isNull);
      expect(device.message, isNotNull);
      expect(device.connected, false);
      report['compatibleDevicesObserved'] =
          device.devices.length; // No device identities in the report.
      checks['realSdkScanAndTimeout'] = true;
      checks['noAutomaticConnection'] =
          device.connection == RecorderConnection.disconnected;
      await screenshot('scan-completed');
      await device.startScan();
      await device.stopScan();
      expect(device.scanning, false);
      expect(device.error, isNull);
      checks['manualScanStopAndRetry'] = true;
      await device.startScan();
      await tapText('取消');
      await waitFor(
        () => find.byType(RecorderDeviceAddSheet).evaluate().isEmpty,
      );
      router.go('/profile');
      await waitFor(() => find.byType(RecorderDevicePage).evaluate().isEmpty);
      await waitFor(() => !device.scanning);
      checks['leavingSheetStopsScan'] = true;
      router.go('/profile/recording-device');
      await waitFor(
        () => find.byType(RecorderDevicePage).evaluate().isNotEmpty,
      );
      final again = tester
          .element(find.byType(RecorderDevicePage))
          .read<RecorderDeviceViewModel>();
      expect(identical(device, again), true);
      await device.checkBluetooth();
      expect(device.error, isNull);
      checks['pageReentryKeepsSingleViewModel'] = true;
      expect(device.info.firmware, isNull);
      expect(device.info.battery, isNull);
      expect(device.recording, RecorderState.unknown);
      checks['noInventedDeviceInformation'] = true;
      if (const bool.fromEnvironment('SONINOTE_TEST_HARDWARE')) {
        await device.startScan();
        await waitFor(() => device.devices.isNotEmpty, seconds: 20);
        expect(device.devices.length, 1, reason: '多个目标设备时需人工选择，不能自动猜测');
        final target = device.devices.single;
        expect(target.name.toUpperCase().startsWith('CB08'), true);
        await device.connect(target);
        await waitFor(() => device.connected, seconds: 25);
        report['hardwareConnected'] = true;
        checks['realCb08ConnectionCallback'] = true;
        await waitFor(
          () => device.info.firmware != null && device.info.totalKb != null,
          seconds: 25,
        );
        report['deviceInformation'] = {
          'productType': target.productType,
          'firmware': device.info.firmware,
          'firmwareCode': device.info.firmwareCode,
          'batteryPercent': device.info.battery,
          'charging': device.info.charging,
          'totalKb': device.info.totalKb,
          'freeKb': device.info.freeKb,
        };
        expect(device.info.usage, isNotNull);
        checks['realBatteryCapacityFirmware'] =
            device.info.battery != null || device.info.charging == true;
        await screenshot('cb08-connected');
        await waitFor(
          () => device.recording != RecorderState.unknown,
          seconds: 20,
        );
        expect(
          device.recording,
          RecorderState.idle,
          reason: '设备已有录音或暂停时不打断用户，需确认后另测',
        );
        if (const bool.fromEnvironment('SONINOTE_TEST_RECOVERY')) {
          final lifecycle = _LifecycleProbe();
          var recordingQueries = 0, durationReplies = 0;
          final subscription = device.service.events.listen((event) {
            if (event.type == 'recording' && event.data['query'] == true) {
              recordingQueries++;
            }
            if (event.type == 'duration') durationReplies++;
          });
          WidgetsBinding.instance.addObserver(lifecycle);
          try {
            report['recordingCommandSent'] = true;
            report['recordingCardMicrophoneUsed'] = true;
            await device.startRecording();
            await waitFor(() => device.recording == RecorderState.recording);
            debugPrint('SONINOTE_QA_BACKGROUND_READY');
            await waitFor(
              () => lifecycle.states.contains(AppLifecycleState.paused),
            );
            await waitFor(
              () => lifecycle.states.contains(AppLifecycleState.resumed),
            );
            final beforeQueries = recordingQueries,
                beforeDuration = durationReplies;
            await device.queryRecording();
            await device.service.queryDuration();
            await waitFor(
              () =>
                  recordingQueries > beforeQueries &&
                  durationReplies > beforeDuration,
            );
            expect(device.connected, true);
            expect(device.recording, RecorderState.recording);
            checks['realBackgroundResumeAndFreshRecordingQuery'] = true;
            report['observedLifecycleStates'] = lifecycle.states
                .map((s) => s.name)
                .toList();
            await device.stopRecording();
            await waitFor(() => device.recording == RecorderState.idle);
            expect(device.message, contains('已确认停止并保存'));
            checks['recoveryRecordingStoppedAndSaved'] = true;
            debugPrint('SONINOTE_QA_BLUETOOTH_OFF_READY');
            await waitFor(() => !device.bluetoothEnabled && !device.connected);
            expect(device.recording, RecorderState.unknown);
            checks['realBluetoothOffInvalidatesConnection'] = true;
            debugPrint('SONINOTE_QA_BLUETOOTH_ON_READY');
            await waitFor(() => device.bluetoothEnabled);
            await device.startScan();
            await waitFor(() => device.devices.isNotEmpty);
            expect(device.devices.length, 1);
            await device.connect(device.devices.single);
            await waitFor(
              () =>
                  device.connected &&
                  device.info.firmware != null &&
                  device.recording != RecorderState.unknown,
            );
            expect(device.recording, RecorderState.idle);
            checks['realBluetoothReenableReconnectAndFreshInfo'] = true;
          } finally {
            WidgetsBinding.instance.removeObserver(lifecycle);
            await subscription.cancel();
          }
        } else if (const bool.fromEnvironment('SONINOTE_TEST_PHYSICAL')) {
          report['recordingCardMicrophoneUsed'] = true;
          await physicalButtons(
            device,
            tester.element(find.byType(RecorderDevicePage)),
          );
          if (device.recording != RecorderState.idle) {
            report['cleanupCommandSent'] = true;
            await device.stopRecording();
            await waitFor(
              () => device.recording == RecorderState.idle,
              seconds: 20,
            );
            report['cleanupStopConfirmed'] = true;
          }
        } else {
          report['recordingCommandSent'] = true;
          report['recordingCardMicrophoneUsed'] = true;
          await device.startRecording();
          await waitFor(
            () => device.recording == RecorderState.recording,
            seconds: 20,
          );
          checks['realStartRecordingCallback'] = true;
          await Future<void>.delayed(const Duration(seconds: 3));
          await device.pauseRecording();
          await waitFor(
            () => device.recording == RecorderState.paused,
            seconds: 20,
          );
          checks['realPauseRecordingCallback'] = true;
          await screenshot('cb08-paused');
          await device.resumeRecording();
          await waitFor(
            () => device.recording == RecorderState.recording,
            seconds: 20,
          );
          checks['realResumeRecordingCallback'] = true;
          await Future<void>.delayed(const Duration(seconds: 2));
          await device.stopRecording();
          await waitFor(
            () => device.recording == RecorderState.idle,
            seconds: 20,
          );
          expect(device.message, contains('已确认停止并保存'));
          checks['realStopSaveCallback'] = true;
          await screenshot('cb08-saved');
        }
        await device.disconnect();
        await waitFor(
          () => device.connection == RecorderConnection.disconnected,
        );
        checks['realDisconnectCallback'] = true;
      }
      expect(tester.takeException(), isNull);
      report['passed'] = true;
    } catch (error) {
      report['passed'] = false;
      report['failureType'] = error.runtimeType.toString();
      report['deviceError'] = model?.error;
      report['connectionState'] = model?.connection.name;
      report['recordingState'] = model?.recording.name;
      report['lastDiagnostic'] = model?.lastDiagnostic;
      rethrow;
    } finally {
      final cleanup = model;
      if (cleanup?.scanning == true) await cleanup!.stopScan();
      if (cleanup != null &&
          cleanup.connected &&
          report['recordingCardMicrophoneUsed'] == true &&
          cleanup.recording != RecorderState.idle) {
        await cleanup.stopRecording();
        // Preserve the test file: never delete recordings during cleanup.
        for (
          var i = 0;
          i < 30 && cleanup.recording != RecorderState.idle;
          i++
        ) {
          await tester.pump(const Duration(milliseconds: 100));
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }
        report['cleanupStopConfirmed'] =
            cleanup.recording == RecorderState.idle;
      }
      if (cleanup?.connected == true) await cleanup!.disconnect();
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: Center(child: Text('设备手机侧测试结束'))),
        ),
      );
      await tester.pump();
      save();
    }
  }, timeout: const Timeout(Duration(minutes: 16)));
}
