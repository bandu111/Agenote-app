import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import '../meeting/local_speech.dart' show meetingWavHeader;

const maxImportedAudioBytes = 256 * 1024 * 1024;

class WavInfo {
  const WavInfo(this.rate, this.channels, this.offset, this.bytes);
  final int rate, channels, offset, bytes;
  int get frames => bytes ~/ (channels * 2);
  Duration get duration => Duration(microseconds: frames * 1000000 ~/ rate);
}

Future<WavInfo> inspectWav(File source) async {
  final f = await source.open();
  try {
    final length = await f.length();
    if (length > maxImportedAudioBytes) {
      throw const FormatException('音频请控制在 256 MB 以内');
    }
    final header = await f.read(12);
    bool tag(List<int> data, int start, String name) =>
        data.length >= start + name.length &&
        String.fromCharCodes(data.sublist(start, start + name.length)) == name;
    if (!tag(header, 0, 'RIFF') || !tag(header, 8, 'WAVE')) {
      throw const FormatException('文件不是有效的 WAV 音频');
    }
    final declared =
        ByteData.sublistView(header).getUint32(4, Endian.little) + 8;
    if (declared > length) throw const FormatException('WAV 文件不完整');
    int? rate, channels, offset, bytes;
    var cursor = 12;
    while (cursor + 8 <= declared) {
      await f.setPosition(cursor);
      final chunk = await f.read(8);
      final size = ByteData.sublistView(chunk).getUint32(4, Endian.little);
      if (cursor + 8 + size > declared) {
        throw const FormatException('WAV 数据块损坏');
      }
      if (tag(chunk, 0, 'fmt ')) {
        if (size < 16 || size > 4096) {
          throw const FormatException('不支持的 WAV 编码');
        }
        final format = ByteData.sublistView(await f.read(size));
        if (format.getUint16(0, Endian.little) != 1 ||
            format.getUint16(14, Endian.little) != 16) {
          throw const FormatException('目前支持 PCM 16 位 WAV，请先转换编码');
        }
        channels = format.getUint16(2, Endian.little);
        rate = format.getUint32(4, Endian.little);
        if ((channels != 1 && channels != 2) ||
            rate < 8000 ||
            rate > 48000 ||
            format.getUint16(12, Endian.little) != channels * 2) {
          throw const FormatException('支持 8–48 kHz、单声道或双声道 WAV');
        }
      } else if (tag(chunk, 0, 'data')) {
        if (offset != null) throw const FormatException('暂不支持多个音频数据块');
        offset = cursor + 8;
        bytes = size;
      }
      cursor += 8 + size + size % 2;
    }
    if (rate == null ||
        channels == null ||
        offset == null ||
        bytes == null ||
        bytes == 0 ||
        bytes % (channels * 2) != 0) {
      throw const FormatException('WAV 缺少完整音频数据');
    }
    return WavInfo(rate, channels, offset, bytes);
  } finally {
    await f.close();
  }
}

/// Offline PCM conversion runs outside the UI isolate; recording time is preserved.
Future<void> normalizeWav(
  File source,
  File destination,
) => Isolate.run(() async {
  final info = await inspectWav(source);
  final input = await source.open();
  final temp = File('${destination.path}.tmp');
  final output = await temp.open(mode: FileMode.write);
  final totalFrames = info.frames * 16000 ~/ info.rate;
  try {
    await output.writeFrom(meetingWavHeader(totalFrames * 2));
    if (info.rate == 16000 && info.channels == 1) {
      await input.setPosition(info.offset);
      var remaining = info.bytes;
      while (remaining > 0) {
        final data = await input.read(remaining.clamp(0, 65536));
        if (data.isEmpty) throw const FormatException('音频读取不完整');
        await output.writeFrom(data);
        remaining -= data.length;
      }
      await output.flush();
    } else {
      // Two source blocks retained at most, never loads a whole meeting in RAM.
      const blockFrames = 8192;
      var cacheStart = -1;
      var samples = Int16List(0);
      Future<int> sample(int frame) async {
        frame = frame.clamp(0, info.frames - 1);
        if (frame < cacheStart || frame >= cacheStart + samples.length) {
          cacheStart = frame;
          final count = (info.frames - frame).clamp(0, blockFrames);
          await input.setPosition(info.offset + frame * info.channels * 2);
          final raw = await input.read(count * info.channels * 2);
          if (raw.length != count * info.channels * 2) {
            throw const FormatException('音频读取不完整');
          }
          final view = ByteData.sublistView(raw);
          samples = Int16List(count);
          for (var i = 0; i < count; i++) {
            var value = view.getInt16(i * info.channels * 2, Endian.little);
            if (info.channels == 2) {
              value = (value + view.getInt16(i * 4 + 2, Endian.little)) ~/ 2;
            }
            samples[i] = value;
          }
        }
        return samples[frame - cacheStart];
      }

      for (var base = 0; base < totalFrames; base += blockFrames) {
        final count = (totalFrames - base).clamp(0, blockFrames);
        final pcm = Uint8List(count * 2);
        final data = ByteData.sublistView(pcm);
        for (var i = 0; i < count; i++) {
          final numerator = (base + i) * info.rate;
          final frame = numerator ~/ 16000,
              fraction = (numerator % 16000) / 16000;
          final a = await sample(frame), b = await sample(frame + 1);
          data.setInt16(
            i * 2,
            (a + (b - a) * fraction).round().clamp(-32768, 32767),
            Endian.little,
          );
        }
        await output.writeFrom(pcm);
      }
      await output.flush();
    }
  } finally {
    await input.close();
    await output.close();
  }
  await temp.rename(destination.path);
});
