import 'dart:math';
import 'dart:typed_data';

/// 设备适配层统一输出16kHz/单声道/PCM16LE；帧边界不等于词或句边界。
/// 不通过删静音、硬增益或丢包改变原始证据和时间轴。
class MeetingPcmBuffer {
  static const sampleRate = 16000;
  static const frameBytes = 3200; // 100ms，降低跨线程调度开销。
  final _pending = BytesBuilder(copy: false);
  int samples = 0, clipped = 0, zeroSamples = 0;
  double _squares = 0;
  double get rms => samples == 0 ? 0 : sqrt(_squares / samples);
  Duration get duration =>
      Duration(microseconds: samples * 1000000 ~/ sampleRate);
  List<Uint8List> add(Uint8List bytes) {
    _pending.add(Uint8List.fromList(bytes));
    if (_pending.length < frameBytes) {
      return const [];
    }
    final joined = _pending.takeBytes();
    final result = <Uint8List>[];
    var offset = 0;
    while (joined.length - offset >= frameBytes) {
      result.add(
        _measure(Uint8List.sublistView(joined, offset, offset + frameBytes)),
      );
      offset += frameBytes;
    }
    if (offset < joined.length) {
      _pending.add(Uint8List.sublistView(joined, offset));
    }
    return result;
  }

  Uint8List finish() {
    final tail = _pending.takeBytes();
    if (tail.length.isOdd) throw const FormatException('PCM16末尾缺少一个字节');
    return _measure(tail);
  }

  Uint8List _measure(Uint8List bytes) {
    final view = ByteData.sublistView(bytes);
    for (var i = 0; i < bytes.length; i += 2) {
      final raw = view.getInt16(i, Endian.little);
      final value = raw / 32768;
      _squares += value * value;
      if (raw.abs() >= 32760) clipped++;
      if (raw == 0) zeroSamples++;
      samples++;
    }
    return bytes;
  }

  Map<String, Object> get diagnostics => {
    'sampleRate': sampleRate,
    'channels': 1,
    'samples': samples,
    'audioMilliseconds': duration.inMilliseconds,
    'rms': rms,
    'clippedFraction': samples == 0 ? 0.0 : clipped / samples,
    'zeroFraction': samples == 0 ? 0.0 : zeroSamples / samples,
  };
}
