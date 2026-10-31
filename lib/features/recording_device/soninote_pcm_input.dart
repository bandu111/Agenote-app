import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:opus_dart/opus_dart.dart';
import 'package:opus_flutter/opus_flutter.dart' as opus_flutter;
import '../meeting/audio_input_route.dart';
import '../meeting/meeting_pcm_input.dart';
import 'recorder_device_view_model.dart';
import 'recorder_models.dart';

/// The SDK's normal CB08 protocol is 40 bytes per Opus packet (16kHz mono).
/// Carry incomplete packets across callbacks; never decode a transport chunk
/// as if it were one codec packet, or silently discard its remainder.
class SoniNoteOpusFramer {
  Uint8List _tail = Uint8List(0);
  List<Uint8List> add(Uint8List bytes) {
    final joined = Uint8List.fromList([..._tail, ...bytes]);
    final frames = <Uint8List>[];
    var offset = 0;
    while (offset + 40 <= joined.length) {
      frames.add(Uint8List.fromList(joined.sublist(offset, offset + 40)));
      offset += 40;
    }
    _tail = Uint8List.fromList(joined.sublist(offset));
    return frames;
  }

  int get remainingBytes => _tail.length;
}

class SoniNotePcmInput implements MeetingPcmInput {
  SoniNotePcmInput(this.device);
  final RecorderDeviceViewModel device;
  static const _audio = EventChannel('yanshu/soninote/audio');
  static Future<void>? _opus;
  static Future<void> loadOpus() => _opus ??= () async {
    try {
      initOpus(await opus_flutter.load());
    } catch (_) {
      _opus = null;
      rethrow;
    }
  }();
  final _states = StreamController<String>.broadcast();
  StreamController<Uint8List>? _pcm;
  StreamSubscription<dynamic>? _subscription;
  StreamSubscription<RecorderEvent>? _statusSubscription;
  SimpleOpusDecoder? _decoder;
  SoniNoteOpusFramer _framer = SoniNoteOpusFramer();
  Completer<void>? _first;
  final _startup = <Uint8List>[];
  int _startupBytes = 0, decodedSamples = 0, _sequence = 0;
  bool _listening = false, _closing = false, _failed = false;
  Future<void>? _stopping;
  @override
  Stream<String> get states => _states.stream;
  @override
  AudioInputRoute get route => AudioInputRoute(
    id: 'soninote',
    name: device.selected?.name ?? '录音卡',
    type: 'recordingCard',
    verified: decodedSamples > 0,
    sampleRate: 16000,
    channels: 1,
  );

  @override
  Future<Stream<Uint8List>> start() async {
    if (!device.connected || device.selected == null) {
      throw StateError('请先连接录音卡');
    }
    if (_pcm != null) throw StateError('录音卡音频已接入会议');
    await loadOpus();
    _decoder = SimpleOpusDecoder(sampleRate: 16000, channels: 1);
    _framer = SoniNoteOpusFramer();
    decodedSamples = _sequence = _startupBytes = 0;
    _listening = _closing = _failed = false;
    _first = Completer<void>();
    // Attach the error handler before the first platform callback can arrive.
    final ready = _first!.future.timeout(
      const Duration(seconds: 12),
      onTimeout: () => throw StateError('未收到录音卡实时音频，请检查设备'),
    );
    ready.ignore();
    _pcm = StreamController<Uint8List>(
      sync: true,
      onListen: () {
        scheduleMicrotask(() {
          if (_closing) return;
          _listening = true;
          for (final bytes in _startup) {
            _pcm?.add(bytes);
          }
          _startup.clear();
          _startupBytes = 0;
        });
      },
    );
    final epoch = device.connectionEpoch, id = device.selected!.id;
    _statusSubscription = device.service.events.listen((event) {
      if (_closing) return;
      if (!device.connected || device.connectionEpoch != epoch) {
        _fail(StateError('录音卡连接已断开，未切换到手机麦克风'));
      } else if (event.type == 'recording' && event.data['query'] != true) {
        switch (event.data['state']) {
          case 'paused':
            _states.add('pause');
          case 'recording':
            _states.add('record');
          // The coordinator archives a physical stop. Do not falsely mark a
          // pending App stop as an unexpected system interruption.
        }
      }
    });
    _subscription = _audio.receiveBroadcastStream().listen((raw) {
      if (_closing ||
          _failed ||
          raw is! Map ||
          raw['epoch'] != epoch ||
          raw['device_id'] != id) {
        return;
      }
      try {
        if (raw['sequence'] != _sequence++) throw StateError('录音卡音频包中断，请重新连接');
        final bytes = raw['bytes'];
        if (bytes is! Uint8List || bytes.isEmpty || bytes.length > 4096) {
          throw StateError('录音卡音频格式不受支持');
        }
        for (final frame in _framer.add(bytes)) {
          final samples = _decoder!.decode(input: frame);
          if (samples.isEmpty) throw StateError('录音卡音频解码失败');
          final pcm = Uint8List(samples.length * 2);
          final view = ByteData.sublistView(pcm);
          for (var i = 0; i < samples.length; i++) {
            view.setInt16(i * 2, samples[i], Endian.little);
          }
          decodedSamples += samples.length;
          if (_listening) {
            _pcm!.add(pcm);
          } else {
            _startupBytes += pcm.length;
            if (_startupBytes > 16000 * 2 * 20) {
              throw StateError('会议启动过久，录音卡音频缓冲已满');
            }
            _startup.add(pcm);
          }
          if (!_first!.isCompleted) _first!.complete();
        }
      } catch (error) {
        _fail(StateError('录音卡音频解码或传输异常：$error'));
      }
    }, onError: (Object error) => _fail(StateError('录音卡实时音频接收失败：$error')));
    try {
      if (device.recording == RecorderState.idle) {
        await device.startRecording();
      } else if (device.recording == RecorderState.paused) {
        await device.resumeRecording();
      }
      await ready;
      if (_failed) throw StateError('录音卡音频已中断');
      return _pcm!.stream;
    } catch (_) {
      await stop();
      rethrow;
    }
  }

  void _fail(Object error) {
    if (_failed || _closing) return;
    _failed = true;
    if (_first?.isCompleted == false) {
      _first!.completeError(error);
    } else if (_listening) {
      _pcm?.addError(error);
    }
    _states.add('input_lost');
  }

  Future<void> _confirmed(RecorderState state) async {
    if (device.recording == state) return;
    final result = Completer<void>();
    void changed() {
      if (result.isCompleted) return;
      if (!device.connected) {
        result.completeError(StateError('录音卡已断开'));
      } else if (device.recording == state) {
        result.complete();
      } else if (!device.recordingBusy && device.error != null) {
        result.completeError(StateError(device.error!));
      }
    }

    device.addListener(changed);
    try {
      changed();
      await result.future.timeout(const Duration(seconds: 13));
    } finally {
      device.removeListener(changed);
    }
  }

  @override
  Future<void> pause() async {
    if (device.recording != RecorderState.paused) await device.pauseRecording();
    await _confirmed(RecorderState.paused);
  }

  @override
  Future<void> resume() async {
    if (!device.connected) throw StateError('请重新连接录音卡');
    if (device.recording != RecorderState.recording) {
      await device.resumeRecording();
    }
    await _confirmed(RecorderState.recording);
  }

  @override
  Future<void> stop() =>
      _stopping ??= _stop().whenComplete(() => _stopping = null);
  Future<void> _stop() async {
    if (_closing) return;
    try {
      if (device.connected && device.recording != RecorderState.idle) {
        await device.stopRecording();
        await _confirmed(RecorderState.idle);
      }
    } finally {
      // Keep accepting the tail until the card confirms stop/save, just as
      // the phone recorder drains its native stream before closing the WAV.
      _closing = true;
      await _statusSubscription?.cancel();
      _statusSubscription = null;
      await _subscription?.cancel();
      _subscription = null;
      _decoder?.destroy();
      _decoder = null;
      _startup.clear();
      _startupBytes = 0;
      // close() waits for a listener on a single-subscription controller. A
      // failed startup has none, so closing must not deadlock cleanup.
      final pcm = _pcm;
      _pcm = null;
      if (pcm != null) {
        unawaited(pcm.close());
      }
    }
  }

  Future<void> dispose() async {
    try {
      await stop();
    } finally {
      await _states.close();
    }
  }
}
