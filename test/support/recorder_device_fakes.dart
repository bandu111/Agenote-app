import 'dart:async';
import 'package:yanshu/features/recording_device/recorder_device_service.dart';
import 'package:yanshu/features/recording_device/recorder_device_repository.dart';
import 'package:yanshu/features/recording_device/recorder_models.dart';

class MemoryRecorderRepository implements RecorderDeviceRepository {
  List<SavedRecorderDevice> records = [];
  bool failLoad = false, failSave = false;
  Completer<void>? writeGate;
  @override
  Future<List<SavedRecorderDevice>> load() async {
    if (failLoad) throw StateError('read failure');
    return records
        .map((r) => SavedRecorderDevice.fromJson(r.toJson()))
        .toList();
  }

  @override
  Future<void> save(List<SavedRecorderDevice> value) async {
    if (writeGate != null) await writeGate!.future;
    if (failSave) throw StateError('write failure');
    records = value
        .map((r) => SavedRecorderDevice.fromJson(r.toJson()))
        .toList();
  }
}

// Test double only; production always uses native SoniNote SDK.
class DeviceServiceFake implements RecorderDeviceService {
  final controller = StreamController<RecorderEvent>.broadcast(sync: true);
  final calls = <String>[];
  int epoch = 0;
  String id = 'sdk-id';
  String? fail;
  Completer<void>? stopScanGate;
  void emit(
    String type, [
    Map<String, dynamic> data = const {},
    int? generation,
  ]) => controller.add(
    RecorderEvent(type, data: data, deviceId: id, epoch: generation ?? epoch),
  );
  Future<void> call(String name) async {
    calls.add(name);
    if (fail == name) throw const RecorderFailure('test_error', '设备测试失败');
  }

  @override
  Stream<RecorderEvent> get events => controller.stream;
  @override
  Future<void> initialize() => call('init');
  @override
  Future<void> requestPermissions() => call('permission');
  @override
  Future<void> checkBluetooth() => call('status');
  @override
  Future<void> startScan() => call('scan');
  @override
  Future<void> stopScan() async {
    await call('stopScan');
    if (stopScanGate != null) await stopScanGate!.future;
  }

  @override
  Future<void> connect(RecorderDevice device, int epoch) async {
    this.epoch = epoch;
    id = device.id;
    await call('connect');
  }

  @override
  Future<void> disconnect() => call('disconnect');
  @override
  Future<void> syncTime() => call('syncTime');
  @override
  Future<void> refreshDeviceInfo() => call('info');
  @override
  Future<void> queryRecording() => call('recording');
  @override
  Future<void> queryDuration() => call('duration');
  @override
  Future<void> startRecording() => call('start');
  @override
  Future<void> pauseRecording() => call('pause');
  @override
  Future<void> resumeRecording() => call('resume');
  @override
  Future<void> stopRecording() => call('stop');
  @override
  Future<void> setForeground(bool foreground) =>
      call(foreground ? 'foreground' : 'background');
  @override
  Future<void> dispose() => controller.close();
}
