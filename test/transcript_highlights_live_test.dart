// 显式运行：flutter test test/transcript_highlights_live_test.dart --dart-define=HIGHLIGHT_LIVE=true
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yanshu/core/network/api_client.dart';
import 'package:yanshu/features/meeting/tencent_speech.dart';
import 'package:yanshu/features/meeting/meeting_models.dart';
import 'package:yanshu/features/meeting/meeting_terms.dart';
import 'package:yanshu/features/meeting/transcript_highlights.dart';

void main() {
  testWidgets(
    '真实快速模型经现有腾讯转写协议到Flutter帧回执',
    (tester) async {
      final overrides = HttpOverrides.current;
      HttpOverrides.global = null;
      final api = ApiClient(baseUrl: 'http://127.0.0.1:18769/api/v1/');
      api.accountId = () => 'benchmark';
      api.accessToken = () async => 'synthetic-local-only';
      final worker = (await tester.runAsync(
        () async => TencentSpeechWorker(api, 'highlight-benchmark'),
      ))!;
      final store = TranscriptHighlightStore();
      final sources = <int, MeetingUtterance>{};
      final errors = <Object>[];
      final subscription = (await tester.runAsync(
        () async => worker.transcripts.listen((e) {
          final id = 'source-${e.segment}';
          if (e.highlightBatch case final batch?) {
            final source = sources[e.segment];
            if (source != null) store.accept(id, source.raw, batch);
          } else if (e.isFinal) {
            sources[e.segment] = MeetingUtterance(
              id: id,
              speaker: 'A',
              raw: e.text,
              at: Duration.zero,
            );
          }
        }, onError: errors.add),
      ))!;
      Future<void> drive(Future<void> work) async {
        var completed = false;
        Object? failure;
        work.then(
          (_) => completed = true,
          onError: (Object e) {
            failure = e;
            completed = true;
          },
        );
        final deadline = Stopwatch()..start();
        while (!completed && deadline.elapsed < const Duration(seconds: 30)) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pump(const Duration(milliseconds: 20));
        }
        expect(completed, isTrue, reason: '网络生命周期应及时结束');
        if (failure != null) throw failure!;
      }

      try {
        await tester.runAsync(() => MeetingTermText.dictionary);
        await tester.runAsync(worker.start);
        debugPrint('highlight_live_connected');
        final watch = Stopwatch()..start();
        while (watch.elapsed <
            Duration(
              seconds: const int.fromEnvironment(
                'HIGHLIGHT_LIVE_SECONDS',
                defaultValue: 70,
              ),
            )) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 25)),
          );
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: SingleChildScrollView(
                  child: Column(
                    children: [
                      for (final s in sources.values)
                        MeetingHighlightedText(
                          key: ValueKey(s.id),
                          text: s.raw,
                          style: const TextStyle(fontSize: 14),
                          sources: [s],
                          store: store,
                          classify: false,
                        ),
                    ],
                  ),
                ),
              ),
            ),
          );
          await tester.pump();
        }
        debugPrint('highlight_live_flushing');
        await drive(worker.flush());
        debugPrint('highlight_live_flushed');
        expect(errors, isEmpty);
        expect(sources.length, greaterThanOrEqualTo(20));
        expect(
          find.byKey(const ValueKey('transcript-highlight-label')),
          findsWidgets,
        );
        expect(tester.takeException(), isNull);
      } finally {
        debugPrint('highlight_live_cleanup');
        await drive(subscription.cancel());
        await drive(worker.abort());
        await tester.pumpWidget(const SizedBox());
        store.dispose();
        api.dio.close(force: true);
        HttpOverrides.global = overrides;
        debugPrint('highlight_live_finished');
      }
    },
    skip: !const bool.fromEnvironment('HIGHLIGHT_LIVE'),
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
