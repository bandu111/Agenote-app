import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:yanshu/features/meeting/local_speech.dart';
import 'package:yanshu/features/offline_recordings/wav_import.dart';

void main() {
  late Directory root;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('wav-import-');
  });
  tearDown(() async {
    await root.delete(recursive: true);
  });
  test('16k mono retains duration and actual PCM values', () async {
    final source = File('${root.path}/source.wav'),
        output = File('${root.path}/out.wav');
    final pcm = Uint8List(3200);
    final view = ByteData.sublistView(pcm);
    for (var i = 0; i < 1600; i++) {
      view.setInt16(i * 2, i - 800, Endian.little);
    }
    await source.writeAsBytes([...meetingWavHeader(pcm.length), ...pcm]);
    final before = await source.readAsBytes();
    await normalizeWav(source, output);
    expect(
      (await inspectWav(output)).duration,
      const Duration(milliseconds: 100),
    );
    expect((await output.readAsBytes()).sublist(44), pcm);
    expect(await source.readAsBytes(), before);
  });
  test('44.1k stereo converts to mono 16k without shortening time', () async {
    final source = File('${root.path}/stereo.wav'),
        output = File('${root.path}/out.wav');
    final header = meetingWavHeader(4410 * 4);
    final h = ByteData.sublistView(header);
    h.setUint16(22, 2, Endian.little);
    h.setUint32(24, 44100, Endian.little);
    h.setUint32(28, 44100 * 4, Endian.little);
    h.setUint16(32, 4, Endian.little);
    final pcm = Uint8List(4410 * 4);
    final v = ByteData.sublistView(pcm);
    for (var i = 0; i < 4410; i++) {
      v.setInt16(i * 4, 2000, Endian.little);
      v.setInt16(i * 4 + 2, -1000, Endian.little);
    }
    await source.writeAsBytes([...header, ...pcm]);
    await normalizeWav(source, output);
    final info = await inspectWav(output);
    expect(info.rate, 16000);
    expect(info.channels, 1);
    expect(info.frames, 1600);
    expect(
      ByteData.sublistView(
        await output.readAsBytes(),
      ).getInt16(44, Endian.little),
      500,
    );
  });
  test(
    'non WAV and truncated PCM fail without creating fake transcript',
    () async {
      final source = File('${root.path}/bad.wav');
      await source.writeAsString('not audio');
      await expectLater(inspectWav(source), throwsFormatException);
      await source.writeAsBytes(meetingWavHeader(100));
      await expectLater(inspectWav(source), throwsFormatException);
    },
  );
}
