import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:yanshu/features/offline_recordings/offline_recordings_model.dart';
import 'package:yanshu/features/offline_recordings/transfer_space_page.dart';
import 'package:yanshu/features/meeting/meeting_view_model.dart';
import 'package:yanshu/features/meeting/meeting_remote.dart';
import 'package:yanshu/features/meeting/meeting_models.dart';
import 'package:yanshu/features/meeting/meeting_store.dart';
import 'package:yanshu/features/meeting/local_speech.dart';
import 'package:yanshu/features/knowledge/viewmodels/knowledge_view_model.dart';
import 'package:yanshu/features/knowledge/repositories/knowledge_repository.dart';
import 'package:yanshu/features/notifications/notification_model.dart';
import 'package:yanshu/features/home/viewmodels/home_view_model.dart';
import 'package:yanshu/features/recording_device/recorder_device_view_model.dart';
import 'meeting_test.dart' show FakeMeetingRecorder, FakeMeetingCalendar;
import 'support/recorder_device_fakes.dart';

class TransferRemote
    implements MeetingRemoteRepository, CancelableMeetingAudioRemote {
  @override
  String? accountId = 'owner';
  int uploads = 0, syncs = 0, analyses = 0;
  @override
  Future<void> sync(MeetingRecord record, {required bool paused}) async {
    syncs++;
  }

  @override
  Future<void> uploadAudioCancelable(
    MeetingRecord record,
    bool Function() current,
  ) async {
    expect(current(), true);
    uploads++;
  }

  @override
  Future<Map<String, dynamic>> analyze(MeetingRecord record) async {
    analyses++;
    throw StateError('must not analyze');
  }

  @override
  Future<Map<String, dynamic>> archive(MeetingRecord record) async {
    analyses++;
    throw StateError('must not archive');
  }

  @override
  Future<Map<String, dynamic>?> readArchive(MeetingRecord record) async => null;
  @override
  Future<List<MeetingRecord>> history() async => [];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late OfflineRecordingsModel model;
  late RecorderDeviceViewModel device;
  late MeetingViewModel meeting;
  late Directory root;
  late TransferRemote remote;
  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('agenote-transfer-');
    device = RecorderDeviceViewModel(
      DeviceServiceFake(),
      repository: MemoryRecorderRepository(),
    );
    remote = TransferRemote();
    meeting = MeetingViewModel(
      store: MemoryMeetingStore(),
      recorder: FakeMeetingRecorder(),
      calendar: FakeMeetingCalendar(),
      knowledge: KnowledgeViewModel(
        KnowledgeRepository(MemoryKnowledgeStore()),
      ),
      notifications: NotificationModel(),
      home: HomeViewModel(),
      remote: remote,
    );
    await meeting.knowledge.load();
    model = OfflineRecordingsModel(device, meeting, directory: root)
      ..refreshAccount();
    await Future<void>.delayed(Duration.zero);
  });
  tearDown(() async {
    model.dispose();
    meeting.dispose();
    device.dispose();
    await root.delete(recursive: true);
  });
  test(
    'rename preserves card identity; deletion tombstone survives reload',
    () async {
      final item = OfflineRecording(
        id: 'stable',
        name: 'card.opus',
        deviceId: 'card',
        size: 80,
        seconds: 5,
        startedAt: DateTime.now(),
      );
      model.items.add(item);
      await model.updateInfo(item, '我的录音', '项目资料', '备注');
      expect(item.name, 'card.opus');
      expect(item.displayName, '我的录音');
      await model.removeRecord(item);
      final second = OfflineRecordingsModel(device, meeting, directory: root)
        ..refreshAccount();
      await Future<void>.delayed(Duration.zero);
      expect(second.items.single.hidden, true);
      expect(second.items.single.note, '备注');
      expect(second.items.single.name, 'card.opus');
      second.dispose();
      expect(meeting.knowledge.data.documents, isEmpty);
    },
  );
  test(
    'WAV upload never invokes analysis or archive and keeps recovery held',
    () async {
      final file = File('${root.path}/input.wav');
      await file.writeAsBytes([
        ...meetingWavHeader(64000),
        ...List.filled(64000, 0),
      ]);
      await model.importWav(file, '短录音.wav');
      await model.sync();
      expect(remote.uploads, 1);
      expect(remote.analyses, 0);
      expect(model.items.single.complete, true);
      final record = (await meeting.store.read()).single;
      expect(record.offlineSyncHeld, true);
      expect(record.recoveryPendingSync, false);
      expect(record.cloudAudioUploaded, true);
    },
  );
  test(
    'unsupported formats and oversize documents never enter queue',
    () async {
      final file = File('${root.path}/unsupported.bin');
      await file.writeAsBytes([1, 2, 3]);
      await expectLater(
        model.importDocument(file, 'invalid.exe'),
        throwsFormatException,
      );
      expect(model.items, isEmpty);
    },
  );
  testWidgets('transfer list edit and delete sheets fit narrow screens', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final item = OfflineRecording(
      id: 'a',
      name: '早间站会录音.wav',
      deviceId: 'card',
      size: 100000,
      seconds: 15,
      startedAt: DateTime.now(),
    );
    model.items.add(item);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: model),
          ChangeNotifierProvider.value(value: device),
        ],
        child: const MaterialApp(home: TransferSpacePage()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('传输空间'), findsOneWidget);
    await tester.tap(find.byTooltip('编辑文件信息'));
    await tester.pumpAndSettle();
    expect(find.text('文件信息'), findsOneWidget);
    await tester.drag(find.byType(ListView).last, const Offset(0, -450));
    await tester.pumpAndSettle();
    expect(find.text('还没有改动'), findsOneWidget);
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.byTooltip('删除传输记录'));
    await tester.pumpAndSettle();
    expect(find.text('删除这条传输记录？'), findsOneWidget);
    await tester.tap(find.text('确认删除'));
    await tester.pumpAndSettle();
    expect(item.hidden, true);
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });
    await tester.pumpAndSettle();
    expect(find.text('早间站会录音.wav'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
