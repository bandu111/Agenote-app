import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:provider/provider.dart';
import 'package:path_provider/path_provider.dart';
import 'package:yanshu/app/theme/app_theme.dart';
import 'package:yanshu/core/network/api_client.dart';
import 'package:yanshu/core/network/api_config.dart';
import 'package:yanshu/features/auth/repositories/dio_auth_repository.dart';
import 'package:yanshu/features/auth/services/session_store.dart';
import 'package:yanshu/features/home/viewmodels/home_view_model.dart';
import 'package:yanshu/features/knowledge/repositories/dio_knowledge_repository.dart';
import 'package:yanshu/features/knowledge/viewmodels/knowledge_view_model.dart';
import 'package:yanshu/features/meeting/meeting_remote.dart';
import 'package:yanshu/features/meeting/meeting_store.dart';
import 'package:yanshu/features/meeting/meeting_view_model.dart';
import 'package:yanshu/features/notifications/notification_model.dart';
import 'package:yanshu/features/offline_recordings/offline_recordings_model.dart';
import 'package:yanshu/features/offline_recordings/transfer_space_page.dart';
import 'package:yanshu/features/recording_device/recorder_device_view_model.dart';
import 'package:yanshu/features/recording_device/soninote_device_adapter.dart';
import '../test/meeting_test.dart'
    show FakeMeetingRecorder, FakeMeetingCalendar;

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('传输空间：真实 Android、云端文件传输与本机记录管理，不调用 ASR', (tester) async {
    final api = ApiClient(baseUrl: ApiConfig.baseUrl);
    final auth = DioAuthRepository(
      api,
      SecureSessionStore('${ApiConfig.baseUrl}#transfer-phone'),
    );
    final email =
        'transfer-${DateTime.now().microsecondsSinceEpoch}@example.com';
    await auth.register('传输空间验证', email, 'Transfer-Phone-2026!');
    final knowledge = KnowledgeViewModel(
      DioKnowledgeRepository(api),
      accountId: () => auth.accountId,
    );
    await knowledge.load();
    final device = RecorderDeviceViewModel(SoniNoteDeviceAdapter());
    final meeting = MeetingViewModel(
      store: MemoryMeetingStore(),
      recorder: FakeMeetingRecorder(),
      calendar: FakeMeetingCalendar(),
      knowledge: knowledge,
      notifications: NotificationModel(),
      home: HomeViewModel(),
      remote: DioMeetingRepository(api),
    );
    final model = OfflineRecordingsModel(device, meeting)..refreshAccount();
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: device),
          ChangeNotifierProvider.value(value: model),
        ],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: AppTheme.light(),
          home: const TransferSpacePage(),
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 1));
    final root = await getApplicationSupportDirectory();
    final source = File('${root.path}/transfer-test-note.txt');
    await source.writeAsString('传输空间自动化验证资料。此文件只验证上传和管理，不触发会议转写。');
    await model.importDocument(source, '传输空间验证.txt');
    await tester.pump(const Duration(milliseconds: 500));
    expect(model.items.where((r) => !r.hidden).length, 1);
    await model.sync();
    expect(model.items.single.complete, true, reason: model.items.single.error);
    expect(model.items.single.documentId, isNotNull);
    await knowledge.load();
    expect(knowledge.document(model.items.single.documentId!), isNotNull);
    await tester.pump(const Duration(seconds: 1));
    debugPrint('TRANSFER_LIST_READY');
    await Future<void>.delayed(const Duration(seconds: 3));
    await tester.tap(find.byTooltip('编辑文件信息'));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.enterText(find.byType(TextField).at(1), '传输空间已编辑.txt');
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.scrollUntilVisible(
      find.text('保存修改'),
      180,
      scrollable: find
          .descendant(
            of: find.byKey(const ValueKey('transfer-editor-scroll')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('保存修改'));
    await tester.pump(const Duration(seconds: 1));
    expect(model.items.single.displayName, '传输空间已编辑.txt');
    await tester.tap(find.byTooltip('删除传输记录'));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('确认删除'));
    await tester.pump(const Duration(seconds: 1));
    expect(model.items.single.hidden, true);
    expect(knowledge.document(model.items.single.documentId!), isNotNull);
    await device.initialize();
    await device.requestPermissions();
    await device.checkBluetooth();
    await device.startScan();
    for (var i = 0; i < 60 && device.devices.isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }
    final card = device.devices
        .where(
          (d) =>
              d.name.toUpperCase().contains('CB08') ||
              d.name.toUpperCase().contains('AI VOICE'),
        )
        .firstOrNull;
    var cardRead = false;
    if (card != null) {
      await device.connect(card);
      for (var i = 0; i < 80 && !device.connected; i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }
      if (device.connected) {
        await tester.pump(const Duration(seconds: 3));
        await model.refreshCard();
        cardRead = model.error == null;
      }
    }
    binding.reportData = {
      'realDevice': true,
      'realCloudUpload': true,
      'rename': true,
      'deleteRecordOnly': true,
      'knowledgePreserved': true,
      'asrInvoked': false,
      'testAccount': email,
      'hardwareFound': card != null,
      'hardwareConnected': device.connected,
      'hardwareFileReadTested': cardRead,
      'cardFileCount': model.items.where((r) => r.deviceId != 'phone').length,
    };
    debugPrint('TRANSFER_QA_RESULT: ${binding.reportData}');
    await tester.pump(const Duration(milliseconds: 500));
    unawaited(
      showTransferEditor(
        tester.element(find.byType(TransferSpacePage)),
        model.items.first,
      ),
    );
    await tester.pumpAndSettle();
    debugPrint('TRANSFER_EDITOR_READY');
    await Future<void>.delayed(const Duration(seconds: 10));
    await tester.pumpWidget(const SizedBox.shrink());
    model.dispose();
    meeting.dispose();
    device.dispose();
    knowledge.dispose();
  });
}
