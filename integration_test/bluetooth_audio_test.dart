import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yanshu/features/meeting/meeting_services.dart';
import 'package:yanshu/features/meeting/local_speech.dart';
import 'package:yanshu/features/meeting/speech_engine.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    '蓝牙耳机真实采音、流式识别、暂停续录与WAV核验',
    (tester) async {
      final stage = ValueNotifier('正在准备耳机麦克风…');
      final recorder = DeviceMeetingRecorder(requireBluetooth: true);
      final events = <Map<String, Object?>>[];
      final errors = <String>[];
      final report = <String, dynamic>{
        'real_microphone': true,
        'raw_audio_uploaded': false,
        'model': 'chinese-2025-06-30-v1',
        'events': events,
        'errors': errors,
        'checks': <String, bool>{},
        'asr_accuracy_not_scored_without_confirmed_reference': true,
      };
      void save() => binding.reportData = report;
      final subscription = recorder.transcripts.listen(
        (event) {
          events.add({
            'segment': event.segment,
            'text': event.text,
            'final': event.isFinal,
            'startMs': event.audioStart?.inMilliseconds,
            'endMs': event.audioEnd?.inMilliseconds,
          });
          save();
        },
        onError: (Object error) {
          errors.add(error.runtimeType.toString());
          save();
        },
      );
      Future<void> listenFor(int seconds) async {
        final until = DateTime.now().add(Duration(seconds: seconds));
        while (DateTime.now().isBefore(until)) {
          await tester.pump(const Duration(milliseconds: 50));
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      }

      String? path;
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Center(
                child: ValueListenableBuilder(
                  valueListenable: stage,
                  builder: (_, text, _) => Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(text, style: const TextStyle(fontSize: 24)),
                  ),
                ),
              ),
            ),
          ),
        );
        path = await recorder.start('bluetooth-mvp-qa');
        report['initial_input'] = recorder.diagnostics;
        expect(recorder.inputRoute?.verified, isTrue);
        expect(recorder.inputRoute?.bluetooth, isTrue);
        report['checks']['actual_bluetooth_microphone'] = true;
        save();
        stage.value = '第一段，20秒\n请说：一期只做安卓和苹果，桌面端先评估，还没有批准。我们下周三下午两点再讨论。';
        await listenFor(20);
        await recorder.pause();
        stage.value = '已暂停，3秒后继续';
        final paused = recorder.diagnostics['samples'];
        await listenFor(3);
        expect(recorder.diagnostics['samples'], paused);
        report['checks']['pause_has_no_new_samples'] = true;
        await recorder.resume();
        stage.value = '第二段，20秒\n请说：接着刚才的交期，我们考虑改到周五，但还没确定。不要取消原计划。验收标准还需要双方确认。';
        await listenFor(20);
        await recorder.stop();
        report['diagnostics'] = recorder.diagnostics;
        final bytes = await File(path).readAsBytes();
        final header = ByteData.sublistView(bytes);
        expect(ascii.decode(bytes.sublist(0, 4)), 'RIFF');
        expect(header.getUint32(24, Endian.little), 16000);
        expect(header.getUint16(22, Endian.little), 1);
        expect(header.getUint32(40, Endian.little), bytes.length - 44);
        expect(
          header.getUint32(40, Endian.little),
          (recorder.diagnostics['samples'] as int) * 2,
        );
        report['checks']['wav_header_samples_and_pcm_match'] = true;
        expect(
          events.any(
            (e) => e['final'] == false && e['text'].toString().isNotEmpty,
          ),
          isTrue,
        );
        expect(
          events.any(
            (e) => e['final'] == true && e['text'].toString().isNotEmpty,
          ),
          isTrue,
        );
        report['checks']['real_partial_and_final_transcripts'] = true;
        final finals = events
            .where((e) => e['final'] == true && e['text'].toString().isNotEmpty)
            .toList();
        expect(finals.map((e) => e['segment']).toSet().length, finals.length);
        expect(
          finals.every((e) => (e['endMs'] as int) >= (e['startMs'] as int)),
          isTrue,
        );
        report['checks']['stable_segments_and_audio_timestamps'] = true;
        stage.value = '录音完成，正在用同一份音频对比新旧模型，无需继续朗读';
        final sameAudio = <String, dynamic>{};
        report['same_audio_replay'] = sameAudio;
        for (final model in [
          MeetingSpeechModel.bilingual,
          MeetingSpeechModel.chinese,
        ]) {
          final worker = LocalSpeechWorker(model: model);
          final texts = <String>[];
          final replayErrors = <String>[];
          final replay = worker.transcripts.listen(
            (e) {
              if (e.isFinal && e.text.isNotEmpty) texts.add(e.text);
            },
            onError: (Object error) {
              replayErrors.add(error.runtimeType.toString());
            },
          );
          try {
            await worker.start();
            final watch = Stopwatch()..start();
            final pcm = Uint8List.sublistView(bytes, 44);
            for (var i = 0; i < pcm.length; i += 3200) {
              worker.accept(
                Uint8List.sublistView(pcm, i, (i + 3200).clamp(0, pcm.length)),
              );
              while (worker.pendingMilliseconds > 1500) {
                await Future<void>.delayed(const Duration(milliseconds: 10));
              }
            }
            await worker.flush();
            sameAudio[model.id] = {
              'text': texts.join(),
              'decodeMs': watch.elapsedMilliseconds,
            };
            expect(replayErrors, isEmpty);
            save();
          } finally {
            await worker.close();
            await replay.cancel();
          }
        }
        expect(errors, isEmpty);
        report['passed'] = true;
        stage.value = '实录完成';
        save();
      } catch (error) {
        report['passed'] = false;
        report['failure_type'] = error.runtimeType.toString();
        report['diagnostics'] = recorder.diagnostics;
        save();
        rethrow;
      } finally {
        await recorder.dispose();
        await subscription.cancel();
        // 只清理本次独立QA产生的录音，不读取或删除日常会议录音。
        if (path != null) {
          final audio = File(path);
          final metadata = File('$path.capture.json');
          if (await audio.exists()) await audio.delete();
          if (await metadata.exists()) await metadata.delete();
        }
        await tester.pumpWidget(const SizedBox());
        stage.dispose();
      }
    },
    semanticsEnabled: false,
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
