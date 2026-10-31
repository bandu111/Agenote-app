import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yanshu/features/meeting/local_speech.dart';
import 'package:yanshu/features/meeting/speech_engine.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    '同一官方音频在手机对比旧模型和中文候选模型',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: Center(child: Text('正在对比识别模型，本轮无需朗读'))),
        ),
      );
      final report = <String, dynamic>{
        'uses_public_reference_audio': true,
        'real_microphone': false,
        'models': <String, dynamic>{},
        'reference': '对我做了介绍啊那么我想说的是呢大家如果对我的研究感兴趣呢',
      };
      binding.reportData = report;
      final data = await rootBundle.load(
        'assets/speech_candidate/reference-0.wav',
      );
      final wav = data.buffer.asUint8List(
        data.offsetInBytes,
        data.lengthInBytes,
      );
      final header = ByteData.sublistView(wav);
      // 官方音频为标准16kHz单声道PCM16，跳过完整RIFF块而不是固定猜44字节。
      expect(header.getUint16(22, Endian.little), 1);
      expect(header.getUint32(24, Endian.little), 16000);
      var offset = 12;
      Uint8List? pcm;
      while (offset + 8 <= wav.length) {
        final length = header.getUint32(offset + 4, Endian.little);
        if (String.fromCharCodes(wav.sublist(offset, offset + 4)) == 'data') {
          pcm = Uint8List.sublistView(wav, offset + 8, offset + 8 + length);
          break;
        }
        offset += 8 + length + length % 2;
      }
      expect(pcm, isNotNull);
      try {
        for (final model in [
          MeetingSpeechModel.bilingual,
          MeetingSpeechModel.chineseCandidate,
        ]) {
          final worker = LocalSpeechWorker(model: model);
          final finals = <String>[];
          var partials = 0;
          final subscription = worker.transcripts.listen((e) {
            if (e.isFinal && e.text.isNotEmpty) finals.add(e.text);
            if (!e.isFinal) partials++;
          });
          try {
            final loading = Stopwatch()..start();
            await worker.start();
            final loadMs = loading.elapsedMilliseconds;
            final watch = Stopwatch()..start();
            for (var i = 0; i < pcm!.length; i += 3200) {
              worker.accept(
                Uint8List.sublistView(pcm, i, (i + 3200).clamp(0, pcm.length)),
              );
            }
            await worker.flush();
            report['models'][model.id] = {
              'loadMs': loadMs,
              'decodeMs': watch.elapsedMilliseconds,
              'audioMs': pcm.length * 1000 ~/ 32000,
              'text': finals.join(),
              'partials': partials,
            };
            binding.reportData = report;
            expect(finals, isNotEmpty);
          } finally {
            await worker.close();
            await subscription.cancel();
          }
        }
        report['passed'] = true;
      } catch (error) {
        report['passed'] = false;
        report['failure_type'] = error.runtimeType.toString();
        rethrow;
      } finally {
        binding.reportData = report;
      }
    },
    semanticsEnabled: false,
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
