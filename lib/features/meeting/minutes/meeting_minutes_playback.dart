import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import '../meeting_models.dart';
import '../meeting_remote.dart';

class _AudioPart {
  _AudioPart(this.path, this.offset, this.duration, {this.cloudId});
  final String path;
  final Duration offset, duration;
  final String? cloudId;
}

abstract interface class MinutesAudioOutput {
  Stream<Duration> get onPositionChanged;
  Stream<void> get onPlayerComplete;
  Future<void> play(String path, Duration position);
  Future<void> pause();
  Future<void> stop();
  Future<void> setPlaybackRate(double rate);
  Future<void> dispose();
}

class DeviceMinutesAudioOutput implements MinutesAudioOutput {
  final AudioPlayer _player = AudioPlayer();
  @override
  Stream<Duration> get onPositionChanged => _player.onPositionChanged;
  @override
  Stream<void> get onPlayerComplete => _player.onPlayerComplete;
  @override
  Future<void> play(String path, Duration position) =>
      _player.play(DeviceFileSource(path), position: position);
  @override
  Future<void> pause() => _player.pause();
  @override
  Future<void> stop() => _player.stop();
  @override
  Future<void> setPlaybackRate(double rate) => _player.setPlaybackRate(rate);
  @override
  Future<void> dispose() => _player.dispose();
}

/// Plays original recordings only; cloud playback downloads bounded chunks to disk.
class MeetingMinutesPlayback extends ChangeNotifier {
  MeetingMinutesPlayback(this.record, this.remote, {MinutesAudioOutput? output})
    : _player = output ?? DeviceMinutesAudioOutput();
  final MeetingRecord record;
  final MeetingRemoteRepository? remote;
  final MinutesAudioOutput _player;
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  List<_AudioPart>? _parts;
  Directory? _temp;
  bool playing = false, loading = false, _disposed = false;
  int _request = 0;
  Duration position = Duration.zero, _base = Duration.zero;
  Duration? _chunkEnd;
  double speed = 1;
  String? error;
  List<double> waveform = const [];
  Future<void>? _waveformWork;

  Future<void> prepareWaveform() => _waveformWork ??= _prepareWaveform();

  Future<void> _prepareWaveform() async {
    try {
      final parts = await _loadParts();
      if (parts.isEmpty) return;
      final part = parts.first;
      var path = part.path;
      if (part.cloudId != null) {
        _temp ??= await (await getTemporaryDirectory()).createTemp(
          'minutes-playback-',
        );
        path = '${_temp!.path}/preview.wav';
        await (remote as DioMeetingRepository).downloadAudioClip(
          record,
          part.cloudId!,
          path,
          Duration.zero,
          Duration(milliseconds: math.min(part.duration.inMilliseconds, 3000)),
        );
      }
      _check();
      final file = await File(path).open();
      final samples = <double>[];
      try {
        final size = await file.length();
        for (var i = 0; i < 48; i++) {
          final offset = 44 + (((size - 44) * i / 48).floor() ~/ 2) * 2;
          await file.setPosition(offset);
          final bytes = await file.read(128);
          final data = ByteData.sublistView(Uint8List.fromList(bytes));
          var energy = 0.0;
          for (var j = 0; j + 1 < bytes.length; j += 2) {
            final v = data.getInt16(j, Endian.little) / 32768;
            energy += v * v;
          }
          samples.add(
            bytes.isEmpty ? 0 : math.sqrt(energy / (bytes.length / 2)),
          );
        }
      } finally {
        await file.close();
      }
      _check();
      final peak = samples.fold<double>(0, math.max);
      waveform = samples.map((s) => peak == 0 ? 0.0 : s / peak).toList();
      notifyListeners();
    } catch (_) {
      /* Preview failure must not prevent original-audio playback. */
    }
  }

  void _check() {
    if (_disposed ||
        (record.ownerId != null && record.ownerId != remote?.accountId)) {
      throw StateError('Account changed');
    }
  }

  Future<List<_AudioPart>> _loadParts() async {
    if (_parts != null) return _parts!;
    final parts = <_AudioPart>[];
    for (final path in record.audioPaths) {
      final file = File(path);
      if (!await file.exists()) continue;
      final input = await file.open();
      try {
        final header = await input.read(44);
        if (header.length < 44 ||
            String.fromCharCodes(header.take(4)) != 'RIFF') {
          continue;
        }
        final rate = ByteData.sublistView(
          Uint8List.fromList(header),
        ).getUint32(28, Endian.little);
        if (rate <= 0) continue;
        final length = Duration(
          milliseconds: ((await file.length() - 44) * 1000 / rate).floor(),
        );
        final u = record.utterances
            .where((u) => u.audioPath == path && u.hasAudio)
            .firstOrNull;
        final offset = u == null
            ? (parts.lastOrNull?.offset ?? Duration.zero) +
                  (parts.lastOrNull?.duration ?? Duration.zero)
            : u.at - u.audioEnd!;
        parts.add(_AudioPart(path, offset, length));
      } finally {
        await input.close();
      }
    }
    final repository = remote;
    if (repository is DioMeetingRepository) {
      try {
        final reply = await repository.client.get(
          'meetings/${Uri.encodeComponent(record.id)}/audio',
          authenticated: true,
          accountId: record.ownerId,
        );
        _check();
        for (final audio in reply['data'] as List? ?? []) {
          final ids = {
            for (final s in audio['sources'] as List? ?? []) s['id'],
          };
          final u = record.utterances
              .where((u) => ids.contains(u.id))
              .firstOrNull;
          if (u == null) continue;
          final map =
              (audio['sources'] as List).firstWhere((s) => s['id'] == u.id)
                  as Map;
          final offset =
              u.at - Duration(milliseconds: (map['end'] as num).toInt());
          if (parts.any(
            (p) => (p.offset - offset).inMilliseconds.abs() < 100,
          )) {
            continue;
          }
          parts.add(
            _AudioPart(
              '',
              offset,
              Duration(milliseconds: (audio['duration'] as num).toInt()),
              cloudId: audio['id'] as String,
            ),
          );
        }
      } catch (_) {
        _check();
        if (parts.isEmpty) rethrow;
      }
    }
    _check();
    parts.sort((a, b) => a.offset.compareTo(b.offset));
    if (parts.isNotEmpty) _parts = parts;
    return parts;
  }

  Future<void> toggle() async {
    if (loading) return;
    if (playing) {
      await pause();
    } else {
      await seek(position >= record.elapsed ? Duration.zero : position);
    }
  }

  Future<void> pause() async {
    ++_request;
    await _player.pause();
    if (_disposed) return;
    loading = false;
    playing = false;
    notifyListeners();
  }

  // 默认定位后播放供逐字稿使用；波形调节传入当前播放状态，暂停定位不短暂出声。
  Future<void> seek(Duration target, {bool play = true}) async {
    target = Duration(
      microseconds: target.inMicroseconds.clamp(
        0,
        record.elapsed.inMicroseconds,
      ),
    );
    if (_disposed) return;
    final request = ++_request;
    loading = true;
    error = null;
    notifyListeners();
    try {
      _check();
      await _player.stop();
      if (_disposed || request != _request) return;
      if (target >= record.elapsed) {
        position = record.elapsed;
        playing = false;
        return;
      }
      final parts = await _loadParts();
      if (_disposed || request != _request) return;
      final part =
          parts
              .where(
                (p) => target >= p.offset && target < p.offset + p.duration,
              )
              .firstOrNull ??
          parts.where((p) => target < p.offset).firstOrNull;
      if (part == null) throw StateError('Recording unavailable');
      final local = target < part.offset ? Duration.zero : target - part.offset;
      var path = part.path;
      var start = local;
      _base = part.offset;
      _chunkEnd = part.offset + part.duration;
      if (!play) {
        position = part.offset + local;
        playing = false;
        return;
      }
      if (part.cloudId != null) {
        _temp ??= await (await getTemporaryDirectory()).createTemp(
          'minutes-playback-',
        );
        path = '${_temp!.path}/chunk-$request.wav';
        final end = Duration(
          milliseconds: math.min(
            part.duration.inMilliseconds,
            local.inMilliseconds + 60000,
          ),
        );
        await (remote as DioMeetingRepository).downloadAudioClip(
          record,
          part.cloudId!,
          path,
          local,
          end,
        );
        _base = part.offset + local;
        _chunkEnd = part.offset + end;
        start = Duration.zero;
      }
      _check();
      if (request != _request) return;
      if (_subscriptions.isEmpty) {
        _subscriptions.add(
          _player.onPositionChanged.listen((p) {
            if (!_disposed && !loading && playing) {
              position = _base + p;
              notifyListeners();
            }
          }),
        );
        _subscriptions.add(
          _player.onPlayerComplete.listen((_) {
            if (_disposed || !playing) return;
            final next = _chunkEnd;
            if (next != null &&
                parts.any((p) => next < p.offset + p.duration)) {
              unawaited(seek(next));
            } else {
              playing = false;
              position = record.elapsed;
              notifyListeners();
            }
          }),
        );
      }
      await _player.setPlaybackRate(speed);
      await _player.play(path, start);
      if (_disposed || request != _request) {
        await _player.stop();
        return;
      }
      position = part.offset + local;
      playing = true;
    } catch (_) {
      if (!_disposed && request == _request) {
        error = '原始录音暂不可播放，请检查文件或网络后重试';
        playing = false;
      }
    } finally {
      if (!_disposed && request == _request) {
        loading = false;
        notifyListeners();
      }
    }
  }

  Future<void> cycleSpeed() async {
    speed = switch (speed) {
      1 => 1.25,
      1.25 => 1.5,
      1.5 => 2,
      _ => 1,
    };
    await _player.setPlaybackRate(speed);
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    ++_request;
    for (final sub in _subscriptions) {
      unawaited(sub.cancel());
    }
    unawaited(
      _player.dispose().whenComplete(() async {
        if (_temp != null && await _temp!.exists()) {
          await _temp!.delete(recursive: true);
        }
      }),
    );
    super.dispose();
  }
}
