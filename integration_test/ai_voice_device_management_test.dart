import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:provider/provider.dart';
import 'package:yanshu/app/app.dart';
import 'package:yanshu/features/knowledge/repositories/knowledge_repository.dart';
import 'package:yanshu/features/profile/repositories/profile_repository.dart';
import 'package:yanshu/features/recording_device/recorder_device_add_sheet.dart';
import 'package:yanshu/features/recording_device/recorder_device_detail_page.dart';
import 'package:yanshu/features/recording_device/recorder_device_page.dart';
import 'package:yanshu/features/recording_device/recorder_device_repository.dart';
import 'package:yanshu/features/recording_device/recorder_device_view_model.dart';
import 'package:yanshu/features/recording_device/recorder_models.dart';

/// Real SDK / real hardware. Isolated application ID; never starts/stops recording.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('AI Voice V2：真实设备只读信息、添加、重连和移除', (tester) async {
    const storage = FlutterSecureStorage();
    final checks = <String, dynamic>{
      'sdkMocked': false,
      'recordingCommandsSent': false,
      'cloudAccountUsed': false,
      'iosTested': false,
    };
    RecorderDeviceViewModel? model;
    String? backup;
    var backedUp = false;
    Future<void> waitFor(bool Function() condition, {int seconds = 30}) async {
      for (var i = 0; i < seconds * 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        if (condition()) return;
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      fail('真机状态等待超时：${jsonEncode(checks)}');
    }

    Future<void> tap(Finder target) async {
      if (target.evaluate().isEmpty) {
        await tester.scrollUntilVisible(
          target,
          150,
          scrollable: find.byType(Scrollable).last,
        );
      }
      await tester.ensureVisible(target);
      await tester.pump(const Duration(milliseconds: 200));
      await tester.tap(target);
      await tester.pump();
    }

    try {
      backup = await storage.read(key: SecureRecorderDeviceRepository.key);
      backedUp = true;
      await tester.pumpWidget(
        YanShuApp(
          connectRecordingCardToMeetings: false,
          initialLocation: '/profile/recording-device',
          profileRepository: ProfileRepository(MemoryProfileStore()),
          knowledgeRepository: KnowledgeRepository(
            MemoryKnowledgeStore(),
            seedExamples: false,
          ),
        ),
      );
      await waitFor(
        () => find.byType(RecorderDevicePage).evaluate().isNotEmpty,
      );
      model = tester
          .element(find.byType(RecorderDevicePage))
          .read<RecorderDeviceViewModel>();
      final m = model;
      await waitFor(() => m.recordsReady);
      final before = m.savedDevices.map((r) => r.recordId).toSet();
      checks['recordsLoaded'] = true;
      expect(m.scanning, false);
      await tap(find.byTooltip('添加设备'));
      await waitFor(
        () => find.byType(RecorderDeviceAddSheet).evaluate().isNotEmpty,
      );
      if (!m.permissionGranted) {
        if (find.text('允许蓝牙访问').evaluate().isNotEmpty) {
          await tap(find.text('允许蓝牙访问'));
        }
        await waitFor(() => m.permissionGranted, seconds: 60);
      }
      checks['bluetoothPermission'] = true;
      await waitFor(() => m.bluetoothEnabled, seconds: 60);
      checks['bluetoothPoweredOn'] = true;
      await waitFor(() => m.devices.isNotEmpty, seconds: 25);
      expect(m.devices.length, 1, reason: '多台设备时必须人工选择，不自动猜测');
      checks['compatibleScan'] = true;
      if (m.savedFor(m.devices.single.id) != null) {
        await tap(find.text('取消'));
        await m.reconnect(m.savedFor(m.devices.single.id)!);
      } else {
        await tap(find.text('AI Voice').last);
      }
      await waitFor(() => m.connected && m.savedFor(m.selected!.id) != null);
      await waitFor(
        () => find.byType(RecorderDeviceAddSheet).evaluate().isEmpty,
      );
      expect(find.byType(RecorderDeviceDetailPage), findsNothing);
      checks['addedAndReturnedToList'] = true;
      await waitFor(
        () =>
            m.info.serialNumber != null &&
            m.info.firmware != null &&
            m.info.totalKb != null &&
            (m.info.battery != null || m.info.charging == true) &&
            m.recording != RecorderState.unknown,
      );
      checks['fiveRealFields'] = true;
      checks['serialRead'] = m.info.serialNumber!.isNotEmpty;
      checks['firmware'] = m.info.firmware;
      checks['capacityValid'] = m.info.usage != null;
      checks['batteryValid'] =
          m.info.battery != null || m.info.charging == true;
      checks['recordingState'] = m.recording.name;
      final record = m.savedFor(m.selected!.id)!;
      await tap(find.text('AI Voice').first);
      await waitFor(
        () => find.byType(RecorderDeviceDetailPage).evaluate().isNotEmpty,
      );
      expect(find.text('开始录音'), findsNothing);
      expect(find.text('暂停录音'), findsNothing);
      checks['readOnlyDetail'] = true;
      await tap(find.text('断开连接'));
      if (m.recording == RecorderState.recording ||
          m.recording == RecorderState.paused) {
        await waitFor(() => find.text('断开连接？').evaluate().isNotEmpty);
        await tap(find.text('断开连接').last);
      }
      await waitFor(() => m.connection == RecorderConnection.disconnected);
      expect(m.savedDevices.any((r) => r.recordId == record.recordId), true);
      checks['disconnectRetainsRecord'] = true;
      await tap(find.text('连接'));
      await waitFor(() => m.connected && !m.managementBusy);
      await waitFor(() => m.info.serialNumber == record.serialNumber);
      checks['reconnectAndIdentity'] = true;
      // WidgetTester.pageBack hard-codes the English tooltip "Back";
      // this app uses Chinese localizations on the physical phone.
      await tap(find.byType(BackButton));
      await waitFor(
        () => find.byType(RecorderDeviceDetailPage).evaluate().isEmpty,
      );
      expect(m.connected, true);
      checks['pageExitKeepsConnection'] = true;
      await tap(find.text('AI Voice').first);
      await waitFor(
        () => find.byType(RecorderDeviceDetailPage).evaluate().isNotEmpty,
      );
      if (!before.contains(record.recordId)) {
        await tap(find.text('移除设备'));
        await waitFor(() => find.text('移除 AI Voice？').evaluate().isNotEmpty);
        await tap(find.text('移除设备').last);
        await waitFor(
          () => m.savedDevices.every((r) => r.recordId != record.recordId),
        );
        expect(
          (await SecureRecorderDeviceRepository().load()).any(
            (r) => r.recordId == record.recordId,
          ),
          false,
        );
        checks['removePersisted'] = true;
      } else {
        checks['removePersisted'] = 'skipped: pre-existing record';
      }
      checks['completed'] = true;
    } finally {
      try {
        if (model != null &&
            model.connection != RecorderConnection.disconnected) {
          await model.disconnect();
          await waitFor(
            () => model!.connection == RecorderConnection.disconnected,
            seconds: 15,
          );
        }
      } catch (_) {
        checks['cleanupConnection'] = 'disconnect not confirmed';
      }
      if (backedUp) {
        if (backup == null) {
          await storage.delete(key: SecureRecorderDeviceRepository.key);
        } else {
          await storage.write(
            key: SecureRecorderDeviceRepository.key,
            value: backup,
          );
        }
      }
      binding.reportData = checks;
      debugPrint('AI_VOICE_V2_REPORT ${jsonEncode(checks)}');
    }
  });
}
