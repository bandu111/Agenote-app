import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yanshu/core/network/api_client.dart';
import 'package:yanshu/core/network/api_config.dart';
import 'package:yanshu/features/auth/repositories/dio_auth_repository.dart';
import 'package:yanshu/features/auth/services/session_store.dart';
import 'package:yanshu/features/meeting/tencent_speech.dart';
import 'package:yanshu/features/meeting/meeting_services.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('腾讯云真实流式识别：公开音频与耳机实录', (tester) async {
    final api = ApiClient(baseUrl: ApiConfig.baseUrl);
    final auth = DioAuthRepository(
      api,
      SecureSessionStore('${ApiConfig.baseUrl}#asr-qa'),
    );
    final report = <String, dynamic>{
      'synthetic_only': true,
      'provider': 'tencent',
      'events': <Map<String, dynamic>>[],
      'errors': <String>[],
      'checks': <String, bool>{},
    };
    void save() => binding.reportData = report;
    final stage = ValueNotifier('正在验证腾讯云实时识别…');
    final recorder = DeviceMeetingRecorder(
      requireBluetooth: true,
      recognizerFactory: (id) => TencentSpeechWorker(api, id),
    );
    String? path;
    Future<void> waitFor(int seconds) async {
      final until = DateTime.now().add(Duration(seconds: seconds));
      while (DateTime.now().isBefore(until)) {
        await tester.pump(const Duration(milliseconds: 50));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }

    final microphone = recorder.transcripts.listen(
      (e) {
        (report['events'] as List).add({
          'segment': e.segment,
          'text': e.text,
          'final': e.isFinal,
          'startMs': e.audioStart?.inMilliseconds,
          'endMs': e.audioEnd?.inMilliseconds,
        });
        save();
      },
      onError: (Object e) {
        (report['errors'] as List).add(e.runtimeType.toString());
        save();
      },
    );
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
      final identity = await auth.register(
        '云端APP联调',
        'cloud-app-asr-${DateTime.now().microsecondsSinceEpoch}@example.com',
        'Asr-Device-Synthetic-2026!',
      );
      report['test_account'] = {'id': identity.id, 'email': identity.email};
      save();
      final public = TencentSpeechWorker(api, 'asr-public-phone-test');
      final events = <Map<String, dynamic>>[];
      final publicText = public.transcripts.listen(
        (e) => events.add({'text': e.text, 'final': e.isFinal}),
      );
      try {
        await public.start();
        final wav = await rootBundle.load(
          'assets/qa/asr_reference.wav',
        );
        final bytes = wav.buffer.asUint8List(
          wav.offsetInBytes + 44,
          wav.lengthInBytes - 44,
        );
        for (var i = 0; i < bytes.length; i += 3200) {
          public.accept(
            Uint8List.sublistView(bytes, i, (i + 3200).clamp(0, bytes.length)),
          );
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        await public.flush();
        report['public_audio_events'] = events;
        expect(events.any((e) => e['final'] == true), isTrue);
        report['checks']['phone_https_authenticated_wss_real_asr'] = true;
        save();
      } finally {
        await public.close();
        await publicText.cancel();
      }
      stage.value = '耳机测试即将开始，请戴好 X5 Pro。';
      await waitFor(4);
      path = await recorder.start('asr-bluetooth-phone-test');
      report['input'] = recorder.diagnostics;
      expect(recorder.inputRoute?.bluetooth, isTrue);
      report['checks']['verified_bluetooth_microphone'] = true;
      save();
      stage.value = '第一段，20秒\n请说：一期只做安卓和苹果，桌面端先评估，还没有批准。我们下周三下午两点再讨论。';
      await waitFor(20);
      await recorder.pause();
      stage.value = '已暂停，3秒后继续';
      final samples = recorder.diagnostics['samples'];
      await waitFor(3);
      expect(recorder.diagnostics['samples'], samples);
      report['checks']['pause_stops_capture'] = true;
      save();
      await recorder.resume();
      stage.value = '第二段，20秒\n请说：接着刚才的交期，我们考虑改到周五，但还没确定。不要取消原计划。验收标准还需要双方确认。';
      await waitFor(20);
      await recorder.stop();
      report['diagnostics'] = recorder.diagnostics;
      final events2 = report['events'] as List;
      expect(events2.any((e) => e['final'] == false), isTrue);
      expect(events2.any((e) => e['final'] == true), isTrue);
      expect(report['errors'], isEmpty);
      final wav = await File(path).readAsBytes();
      expect(
        ByteData.sublistView(wav).getUint32(40, Endian.little),
        wav.length - 44,
      );
      report['checks']['real_partial_and_final'] = true;
      report['checks']['wav_contains_all_captured_samples'] = true;
      report['checks']['resume_and_end_drain_completed'] = true;
      stage.value = '测试完成，正在整理结果。';
      save();
    } finally {
      await recorder.dispose();
      await microphone.cancel();
      if (path != null) {
        for (final file in [File(path), File('$path.capture.json')]) {
          if (await file.exists()) await file.delete();
        }
        report['qa_recording_deleted'] = true;
      }
      await auth.logout();
      api.dio.close(force: true);
      save();
    }
  });
}
