import 'dart:async';
import 'dart:io';
import 'package:audioplayers/audioplayers.dart';
import 'package:path_provider/path_provider.dart';
import '../../meeting/meeting_audio.dart';
import '../models/progress_models.dart';
import '../viewmodels/voice_evidence_controller.dart';
import '../../../core/network/api_client.dart';

/// 优先本机原声片段，缺失时通过认证接口下载云端对应片段。
class DeviceEvidenceAudioPlayer implements EvidenceAudioPlayer {
  DeviceEvidenceAudioPlayer({this.client});
  final ApiClient? client;
  int _generation = 0;
  bool _disposed = false;
  AudioPlayer? _player;
  final _positions = StreamController<Duration>.broadcast();
  final _completions = StreamController<void>.broadcast();
  StreamSubscription<Duration>? _positionSubscription;
  StreamSubscription<void>? _completionSubscription;
  File? _clip;
  @override
  Stream<Duration> get positions => _positions.stream;
  @override
  Stream<void> get completions => _completions.stream;
  @override
  Future<void> open(VoiceEvidence evidence) async {
    if (evidence.unavailableReason != null ||
        !{'file', 'yanshu-audio'}.contains(evidence.uri?.scheme)) {
      throw StateError('原始语音不可用');
    }
    await stop();
    final generation = ++_generation;
    final previous = _clip;
    _clip = null;
    if (previous != null && await previous.exists()) await previous.delete();
    final directory = await getTemporaryDirectory();
    final clip = File(
      '${directory.path}/yanshu-progress-${DateTime.now().microsecondsSinceEpoch}.wav',
    );
    try {
      if (evidence.uri!.scheme == 'yanshu-audio') {
        final owner = client?.accountId?.call();
        if (owner == null) throw StateError('请先登录语音所属账户');
        await client!.downloadAudio(
          evidence.uri!.path,
          clip.path,
          owner: owner,
          start: evidence.start,
          end: evidence.end,
        );
      } else {
        await writeMeetingAudioClip(
          File.fromUri(evidence.uri!),
          clip,
          evidence.start,
          evidence.end,
        );
      }
      if (_disposed || generation != _generation) {
        if (await clip.exists()) await clip.delete();
        throw StateError('语音播放已取消');
      }
      if (_player == null) {
        _player = AudioPlayer();
        _positionSubscription = _player!.onPositionChanged.listen(
          _positions.add,
          onError: _positions.addError,
        );
        _completionSubscription = _player!.onPlayerComplete.listen(
          (_) => _completions.add(null),
          onError: _completions.addError,
        );
      }
      await _player!.setReleaseMode(ReleaseMode.stop);
      await _player!.setSourceDeviceFile(clip.path);
      if (_disposed || generation != _generation) throw StateError("cancelled");
      _clip = clip;
    } catch (_) {
      if (await clip.exists()) await clip.delete();
      rethrow;
    }
  }

  @override
  Future<void> play() async {
    await _player?.resume();
  }

  @override
  Future<void> pause() async {
    await _player?.pause();
  }

  @override
  Future<void> seek(Duration position) async {
    await _player?.seek(position);
  }

  @override
  Future<void> stop() async {
    ++_generation;
    await _player?.stop();
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    ++_generation;
    await _positionSubscription?.cancel();
    await _completionSubscription?.cancel();
    await _player?.dispose();
    if (_clip != null && await _clip!.exists()) await _clip!.delete();
    await _positions.close();
    await _completions.close();
  }
}
