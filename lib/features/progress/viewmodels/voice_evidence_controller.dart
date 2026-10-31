import 'dart:async';
import 'package:flutter/foundation.dart';
import '../models/progress_models.dart';

enum VoicePlaybackState { idle, loading, playing, paused, unavailable, failed }

/// A single player port, ready for an authorized Android/iOS audio adapter.
/// Positions are relative to the evidence clip, not the full source recording.
abstract interface class EvidenceAudioPlayer {
  Stream<Duration> get positions;
  Stream<void> get completions;
  Future<void> open(VoiceEvidence evidence);
  Future<void> play();
  Future<void> pause();
  Future<void> stop();
  Future<void> seek(Duration position);
  Future<void> dispose();
}

class VoiceEvidenceController extends ChangeNotifier {
  VoiceEvidenceController({EvidenceAudioPlayer? player, this.accountId})
    : _player = player {
    _positions = player?.positions.listen((value) {
      if (_disposed ||
          evidence == null ||
          state == VoicePlaybackState.loading) {
        return;
      }
      position = Duration(
        milliseconds: value.inMilliseconds.clamp(
          0,
          evidence!.duration.inMilliseconds,
        ),
      );
      notifyListeners();
    }, onError: _onStreamError);
    _completions = player?.completions.listen((_) {
      if (_disposed) return;
      position = Duration.zero;
      state = VoicePlaybackState.idle;
      _emit();
    }, onError: _onStreamError);
  }
  final EvidenceAudioPlayer? _player;
  final String? Function()? accountId;
  String? _observedOwner;
  void refreshAccount() {
    if (accountId == null || _observedOwner == accountId!()) return;
    _observedOwner = accountId!();
    ++_revision;
    Future.microtask(() {
      if (!_disposed) suspend();
    });
  }

  StreamSubscription<Duration>? _positions;
  StreamSubscription<void>? _completions;
  VoiceEvidence? evidence;
  VoicePlaybackState state = VoicePlaybackState.idle;
  Duration position = Duration.zero;
  String? message;
  bool _disposed = false, _busy = false;
  int _revision = 0;

  Future<void> toggle(VoiceEvidence value) async {
    if (_busy || _disposed) return;
    _busy = true;
    final revision = ++_revision;
    try {
      if (value.id != evidence?.id ||
          value.unavailableReason != null ||
          state == VoicePlaybackState.unavailable) {
        await _player?.stop();
        if (_disposed || revision != _revision) return;
        evidence = value;
        position = Duration.zero;
        message = value.unavailableReason;
        if (message != null || _player == null) {
          message ??= '音频播放服务尚未接入';
          state = VoicePlaybackState.unavailable;
          _emit();
          return;
        }
        state = VoicePlaybackState.loading;
        _emit();
        await _player.open(value);
        if (_disposed || revision != _revision) return;
        state = VoicePlaybackState.idle;
      }
      if (state == VoicePlaybackState.unavailable) return;
      if (state == VoicePlaybackState.playing) {
        await _player?.pause();
        if (!_disposed && revision == _revision) {
          state = VoicePlaybackState.paused;
        }
      } else {
        // Rewind after the previous playback completed.
        await _player?.seek(position);
        await _player?.play();
        if (!_disposed && revision == _revision) {
          state = VoicePlaybackState.playing;
        }
      }
    } catch (_) {
      if (!_disposed && revision == _revision) {
        state = VoicePlaybackState.failed;
        message = '音频播放失败，请重试';
        evidence = null;
      }
    } finally {
      _busy = false;
      _emit();
    }
  }

  Future<void> seek(Duration value, {VoiceEvidence? source}) async {
    // 首次点击波形时只加载并定位，不自动播放；已加载片段沿用原播放/暂停状态。
    if (source != null && source.id != evidence?.id) {
      if (_busy ||
          _disposed ||
          _player == null ||
          source.unavailableReason != null) {
        return;
      }
      _busy = true;
      final revision = ++_revision;
      try {
        await _player.stop();
        if (_disposed || revision != _revision) return;
        evidence = source;
        position = Duration.zero;
        message = null;
        state = VoicePlaybackState.loading;
        _emit();
        await _player.open(source);
        if (_disposed || revision != _revision) return;
        state = VoicePlaybackState.paused;
      } catch (_) {
        if (!_disposed && revision == _revision) {
          _onStreamError(StateError('open'));
        }
        return;
      } finally {
        _busy = false;
        _emit();
      }
      if (_disposed || revision != _revision) return;
    }
    if (_busy ||
        _disposed ||
        evidence == null ||
        _player == null ||
        state == VoicePlaybackState.unavailable ||
        state == VoicePlaybackState.failed) {
      return;
    }
    final bounded = Duration(
      milliseconds: value.inMilliseconds.clamp(
        0,
        evidence!.duration.inMilliseconds,
      ),
    );
    try {
      await _player.seek(bounded);
      if (!_disposed) {
        position = bounded;
        _emit();
      }
    } catch (_) {
      _onStreamError(StateError('seek'));
    }
  }

  /// Hide/background/route changes interrupt playback and invalidate a pending open.
  Future<void> suspend() async {
    ++_revision;
    try {
      await _player?.stop();
    } catch (_) {
      /* The UI still stops its state. */
    }
    if (!_disposed) {
      position = Duration.zero;
      evidence = null;
      message = null;
      state = VoicePlaybackState.idle;
      _emit();
    }
  }

  void _onStreamError(Object _) {
    if (_disposed) return;
    state = VoicePlaybackState.failed;
    message = '音频播放失败，请重试';
    _emit();
  }

  void _emit() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    ++_revision;
    unawaited(_positions?.cancel());
    unawaited(_completions?.cancel());
    unawaited(_player?.dispose());
    super.dispose();
  }
}
