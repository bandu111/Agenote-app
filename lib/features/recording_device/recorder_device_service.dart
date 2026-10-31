import 'recorder_models.dart';

abstract class RecorderDeviceService {
  Stream<RecorderEvent> get events;
  Future<void> initialize();
  Future<void> requestPermissions();
  Future<void> checkBluetooth();
  Future<void> startScan();
  Future<void> stopScan();
  Future<void> connect(RecorderDevice device, int epoch);
  Future<void> disconnect();
  Future<void> syncTime();
  Future<void> refreshDeviceInfo();
  Future<void> queryRecording();
  Future<void> queryDuration();
  Future<void> startRecording();
  Future<void> pauseRecording();
  Future<void> resumeRecording();
  Future<void> stopRecording();
  Future<void> setForeground(bool foreground);
  Future<void> dispose();
}
