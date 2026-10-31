import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yanshu/features/offline_recordings/card_file_transport.dart';
import 'package:yanshu/features/recording_device/recorder_device_view_model.dart';
import 'package:yanshu/features/recording_device/recorder_models.dart';
import 'package:yanshu/features/recording_device/soninote_device_adapter.dart';
import 'support/recorder_device_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late DeviceServiceFake sdk;
  late RecorderDeviceViewModel device;
  late CardFileTransport transport;
  late Directory directory;
  late List<MethodCall> calls;
  late Completer<void> submitted;
  Future<void> Function(MethodCall)? onCall;
  setUp(() async {
    sdk = DeviceServiceFake();
    device =
        RecorderDeviceViewModel(sdk, repository: MemoryRecorderRepository())
          ..selected = const RecorderDevice('sdk-id', 'CB08')
          ..connection = RecorderConnection.connected
          ..recording = RecorderState.idle;
    transport = CardFileTransport(device);
    directory = await Directory.systemTemp.createTemp('offline-transfer-test-');
    calls = [];
    submitted = Completer<void>();
    onCall = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SoniNoteDeviceAdapter.method, (call) async {
          calls.add(call);
          if (!submitted.isCompleted) submitted.complete();
          await onCall?.call(call);
          return null;
        });
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SoniNoteDeviceAdapter.method, null);
    device.dispose();
    await directory.delete(recursive: true);
  });
  Map<String, Object> file(String name) => {
    'name': name,
    'size': '80',
    'time': '10',
  };
  void emitFiles(
    List<Map<String, Object>> files,
    String finish, [
    int? generation,
  ]) => sdk.emit('files', {
    'items': jsonEncode(files),
    'finish': finish,
  }, generation);
  void emitBytes(List<int> bytes) =>
      sdk.emit('file_bytes', {'bytes': Uint8List.fromList(bytes)});
  void finish([String name = 'a.opus']) =>
      sdk.emit('file_state', {'state': '0', 'name': name});
  Future<void> download(
    File target, {
    int bytes = 80,
    bool Function()? current,
  }) => transport.download(
    CardRecording('a.opus', bytes, 10),
    target,
    current: current ?? () => true,
    progress: (_) {},
  );

  test(
    'file list waits for finish, ignores stale epochs and deduplicates names',
    () async {
      var finished = false;
      final operation = transport.list()..then((_) => finished = true);
      await submitted.future;
      emitFiles([file('stale.opus')], '1', 99);
      emitFiles([file('a.opus')], '0');
      await Future<void>.delayed(Duration.zero);
      expect(finished, isFalse);
      emitFiles([file('a.opus'), file('b.opus')], '1');
      expect((await operation).map((r) => r.name), ['a.opus', 'b.opus']);
    },
  );
  test(
    'a disconnect cancels a pending file list instead of publishing an empty success',
    () async {
      final operation = transport.list();
      final checked = expectLater(operation, throwsStateError);
      await submitted.future;
      device.connection = RecorderConnection.disconnected;
      sdk.emit('connection', {'connected': false});
      await checked;
    },
  );
  test(
    'partial download resumes from actual local bytes and requires hardware completion',
    () async {
      final target = File('${directory.path}/a.opus');
      await target.writeAsBytes(List.filled(40, 1));
      var finished = false;
      final operation = download(target)..then((_) => finished = true);
      await submitted.future;
      expect(calls.single.method, 'downloadFile');
      expect(calls.single.arguments, {'name': 'a.opus', 'offset': 40});
      emitBytes(List.filled(40, 2));
      await Future<void>.delayed(Duration.zero);
      expect(finished, isFalse);
      finish('unrelated.opus');
      expect(finished, isFalse);
      finish();
      await operation;
      expect(await target.readAsBytes(), [
        ...List.filled(40, 1),
        ...List.filled(40, 2),
      ]);
    },
  );
  test(
    'incomplete hardware success is rejected and requires reconnection before retry',
    () async {
      final target = File('${directory.path}/a.opus');
      final operation = download(target);
      final checked = expectLater(operation, throwsStateError);
      await submitted.future;
      emitBytes(List.filled(40, 7));
      finish();
      await checked;
      expect(await target.length(), 40);
      expect(calls.map((c) => c.method), contains('stopDownload'));
      await expectLater(download(target), throwsStateError);
    },
  );
  test('oversized callback never writes past declared length', () async {
    final target = File('${directory.path}/a.opus');
    final operation = download(target);
    final checked = expectLater(operation, throwsStateError);
    await submitted.future;
    emitBytes(List.filled(81, 7));
    await checked;
    expect(await target.length(), 0);
  });
  test(
    'parallel SDK transfers are rejected and device recording blocks downloads',
    () async {
      final operation = transport.list();
      await submitted.future;
      await expectLater(transport.list(), throwsStateError);
      await expectLater(
        download(File('${directory.path}/a.opus')),
        throwsStateError,
      );
      emitFiles([], '1');
      await operation;
      device.recording = RecorderState.recording;
      await expectLater(
        download(File('${directory.path}/a.opus')),
        throwsStateError,
      );
    },
  );
  test('account cancellation stops download and keeps partial bytes', () async {
    var current = true;
    final target = File('${directory.path}/a.opus');
    final operation = download(target, current: () => current);
    final checked = expectLater(operation, throwsStateError);
    await submitted.future;
    emitBytes(List.filled(40, 3));
    current = false;
    emitBytes(List.filled(40, 4));
    await checked;
    expect(await target.readAsBytes(), List.filled(40, 3));
  });
}
