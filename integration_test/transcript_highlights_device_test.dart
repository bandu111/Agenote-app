import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yanshu/core/network/api_client.dart';
import 'package:yanshu/features/home/views/home_style.dart';
import 'package:yanshu/features/meeting/tencent_speech.dart';
import 'package:yanshu/features/meeting/meeting_models.dart';
import 'package:yanshu/features/meeting/transcript_highlights.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  testWidgets('手机真实Qwen标注、段落定位、展开原因与绘制回执', (tester) async {
    final api = ApiClient(baseUrl: 'http://127.0.0.1:18769/api/v1/');
    api.accountId = () => 'device-benchmark';
    api.accessToken = () async => 'synthetic-local-only';
    final worker = TencentSpeechWorker(api, 'device-highlight-benchmark');
    final store = TranscriptHighlightStore();
    final sources = <int, MeetingUtterance>{};
    final errors = <Object>[];
    var annotationCount = 0;
    final report = <String, dynamic>{
      'physicalAndroid': true,
      'syntheticStableSentences': true,
      'realQwen': true,
      'microphoneUsed': false,
      'audioEvidencePlaybackTested': false,
    };
    final subscription = worker.transcripts.listen((e) {
      final id = 'source-${e.segment}';
      if (e.highlightBatch case final batch?) {
        final source = sources[e.segment];
        if (source != null) {
          annotationCount++;
          store.accept(id, source.raw, batch);
        }
      } else if (e.isFinal) {
        sources[e.segment] = MeetingUtterance(
          id: id,
          speaker: '发言人 A',
          raw: e.text,
          at: Duration.zero,
        );
      }
    }, onError: errors.add);
    try {
      await worker.start();
      final watch = Stopwatch()..start();
      while (watch.elapsed < const Duration(seconds: 70)) {
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(colorSchemeSeed: HomeStyle.blue),
            home: Scaffold(
              backgroundColor: const Color(0xFFF3F5FF),
              appBar: AppBar(title: const Text('重点标注真机验证')),
              body: SingleChildScrollView(
                padding: const EdgeInsets.all(18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('确定句回放 ${sources.length}/20 · 已标注 $annotationCount'),
                    const SizedBox(height: 8),
                    const Text('本轮不采集麦克风；由真实 Qwen 返回经验证的标注。'),
                    const SizedBox(height: 16),
                    for (final source in sources.values.toList().reversed.take(
                      2,
                    ))
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: MeetingHighlightedText(
                            key: ValueKey(source.id),
                            text: source.raw,
                            style: const TextStyle(fontSize: 16),
                            sources: [source],
                            store: store,
                            classify: false,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 25));
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
      expect(errors, isEmpty);
      expect(sources.length, 20);
      expect(annotationCount, greaterThan(0));
      final labels = find.byKey(const ValueKey('transcript-highlight-label'));
      expect(labels, findsWidgets);
      await tester.tap(labels.first);
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        find.byKey(const ValueKey('transcript-highlight-reason')),
        findsOneWidget,
      );
      expect(find.text('原始录音依据'), findsOneWidget);
      final play = tester.widget<TextButton>(
        find.widgetWithText(TextButton, '原始录音依据'),
      );
      expect(play.onPressed, isNull, reason: '人工测试句没有真实音频依据，不能伪装可播放');
      report.addAll({
        'stableSentences': sources.length,
        'annotationBatches': annotationCount,
        'reasonExpanded': true,
        'missingAudioCorrectlyDisabled': true,
        'errors': errors.length,
      });
      binding.reportData = report;
      await binding.convertFlutterSurfaceToImage();
      await tester.pump();
      await binding.takeScreenshot('highlight-reason');
      await worker.flush();
    } finally {
      await subscription.cancel();
      await worker.abort();
      await tester.pumpWidget(const SizedBox());
      store.dispose();
      api.dio.close(force: true);
      binding.reportData = report;
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}
