import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:yanshu/features/recording_device/recorder_device_repository.dart';
import 'package:yanshu/features/recording_device/recorder_models.dart';
import 'package:yanshu/features/recording_device/soninote_device_adapter.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const permissions = MethodChannel('flutter.baseflow.com/permissions/methods');
  const events = MethodChannel('yanshu/soninote/events');
  late List<MethodCall> calls;
  late List<int> requestedPermissions;
  late SoniNoteDeviceAdapter adapter;
  setUp(() {
    calls = [];
    requestedPermissions = [];
    adapter = SoniNoteDeviceAdapter();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SoniNoteDeviceAdapter.method,
      (call) async {
        calls.add(call);
        return call.method == 'androidApi' ? 33 : null;
      },
    );
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      events,
      (_) async => null,
    );
    binding.defaultBinaryMessenger.setMockMethodCallHandler(permissions, (
      call,
    ) async {
      if (call.method == 'requestPermissions') {
        requestedPermissions.addAll(List<int>.from(call.arguments as List));
        return {for (final id in requestedPermissions) id: 1};
      }
      return 1;
    });
  });
  tearDown(() async {
    await adapter.dispose();
    for (final channel in [SoniNoteDeviceAdapter.method, events, permissions]) {
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    }
  });

  testWidgets(
    '双端权限使用平台入口，信息查询包含SN且不控制录音',
    (tester) async {
      await tester.runAsync(() async {
        await adapter.initialize();
        await adapter.requestPermissions();
        await adapter.connect(
          const RecorderDevice('real-platform-id', 'CB08'),
          12,
        );
        await adapter.refreshDeviceInfo();
      });
      final names = calls.map((c) => c.method).toList();
      expect(
        names,
        containsAllInOrder([
          'battery',
          'capacity',
          'firmware',
          'firmwareCode',
          'serial',
          'recording',
          'duration',
        ]),
      );
      expect(names, isNot(contains('startRecording')));
      expect(names, isNot(contains('stopRecording')));
      final args =
          calls.singleWhere((c) => c.method == 'connect').arguments as Map;
      expect(args['device_id'], 'real-platform-id');
      expect(
        args['name'],
        'CB08',
      ); // UI branding must not replace the broadcast name.
      if (defaultTargetPlatform == TargetPlatform.iOS) {
        expect(names, contains('requestPermissions'));
        expect(requestedPermissions, isEmpty);
      } else {
        expect(names, contains('androidApi'));
        expect(requestedPermissions.length, 2);
      }
    },
    variant: TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.iOS,
    }),
  );

  testWidgets(
    '双端SN事件保留连接世代和原始标识，断开取消剩余读取',
    (tester) async {
      await tester.runAsync(() async {
        await adapter.initialize();
        final next = adapter.events.first;
        ServicesBinding.instance.channelBuffers.push(
          events.name,
          const StandardMethodCodec().encodeSuccessEnvelope({
            'event_type': 'serial',
            'epoch': 12,
            'device_id': 'real-id',
            'data': {'sn': 'SN-1234'},
          }),
          (_) {},
        );
        final event = await next;
        expect(event.epoch, 12);
        expect(event.deviceId, 'real-id');
        expect(event.data['sn'], 'SN-1234');
        calls.clear();
        final reading = adapter.refreshDeviceInfo();
        await Future<void>.delayed(const Duration(milliseconds: 10));
        await adapter.disconnect();
        await reading;
        expect(calls.map((c) => c.method), ['battery', 'disconnect']);
      });
    },
    variant: TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.iOS,
    }),
  );

  test('真实存储适配器可恢复多设备并持久化移除，无连接状态落盘', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final repository = SecureRecorderDeviceRepository();
    final record = SavedRecorderDevice(
      recordId: 'one',
      platform: 'ios',
      device: const RecorderDevice('peripheral-uuid', 'CB08', productType: '3'),
      addedAt: DateTime.utc(2026),
      serialNumber: 'SERIAL',
    );
    await repository.save([record]);
    final restored = await SecureRecorderDeviceRepository().load();
    expect(restored.single.device.id, 'peripheral-uuid');
    expect(restored.single.serialNumber, 'SERIAL');
    expect(restored.single.toJson().containsKey('connected'), false);
    await repository.save([]);
    expect(await SecureRecorderDeviceRepository().load(), isEmpty);
  });

  test('不支持的存储版本不静默丢弃或覆盖原记录', () async {
    FlutterSecureStorage.setMockInitialValues({
      SecureRecorderDeviceRepository.key: '{"version":999,"devices":[]}',
    });
    expect(SecureRecorderDeviceRepository().load(), throwsFormatException);
  });
}
