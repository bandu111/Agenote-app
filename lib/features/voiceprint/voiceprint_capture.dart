import 'package:audioplayers/audioplayers.dart';
import 'package:record/record.dart';
import 'package:path_provider/path_provider.dart';
import '../../core/network/api_config.dart';
import '../meeting/audio_input_route.dart';

/// 将原生采音与页面流程分开；测试可替换采音，但真实注册仍使用实际设备。
abstract interface class VoiceprintCapture {
  Stream<RecordState> get states;
  Stream<double> get levels;
  Future<String> start();
  Future<void> stop();
  Future<void> cancel();
  Future<AudioInputRoute> route();
  Future<void> play(String path);
  Future<void> stopPlayback();
  Future<void> dispose();
}

class DeviceVoiceprintCapture implements VoiceprintCapture {
  final _recorder = AudioRecorder();
  final _player = AudioPlayer();
  final _monitor = DeviceAudioInputMonitor();

  @override
  Stream<RecordState> get states => _recorder.onStateChanged();
  @override
  Stream<double> get levels => _recorder
      .onAmplitudeChanged(const Duration(milliseconds: 200))
      .map((value) => value.current);

  @override
  Future<String> start() async {
    if (!await _recorder.hasPermission()) {
      throw const ApiFailure('请在系统设置中允许麦克风权限');
    }
    final phones = (await _recorder.listInputDevices()).where(
      (device) => device.type == InputDeviceType.builtIn,
    );
    if (phones.isEmpty) throw const ApiFailure('未找到手机内置麦克风，请检查设备');
    final root = await getTemporaryDirectory();
    final path =
        '${root.path}/voiceprint-${DateTime.now().microsecondsSinceEpoch}.wav';
    await _recorder.start(
      RecordConfig(
        encoder: AudioEncoder.wav,
        sampleRate: 16000,
        numChannels: 1,
        device: phones.first,
        autoGain: false,
        echoCancel: false,
        noiseSuppress: false,
        androidConfig: const AndroidRecordConfig(manageBluetooth: false),
      ),
      path: path,
    );
    return path;
  }

  @override
  Future<void> stop() async {
    await _recorder.stop();
  }

  @override
  Future<void> cancel() => _recorder.cancel();
  @override
  Future<AudioInputRoute> route() => _monitor.snapshot();
  @override
  Future<void> play(String path) => _player.play(DeviceFileSource(path));
  @override
  Future<void> stopPlayback() => _player.stop();
  @override
  Future<void> dispose() async {
    await _recorder.dispose();
    await _player.dispose();
  }
}
