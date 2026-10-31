import 'package:flutter/material.dart';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:yanshu/features/meeting/transcript_highlights.dart';
import 'package:yanshu/features/meeting/meeting_models.dart';
import 'package:yanshu/features/meeting/meeting_terms.dart';
import 'package:yanshu/features/meeting/meeting_store.dart';
import 'package:yanshu/features/meeting/meeting_remote.dart';

const raw = '😀乙负责周五提交报告。';
const source = MeetingUtterance(
  id: 'source',
  speaker: '发言人A',
  raw: raw,
  at: Duration(seconds: 8),
  audioPath: '/test.wav',
  audioStart: Duration(seconds: 3),
  audioEnd: Duration(seconds: 8),
);
const hit = TranscriptHighlight(5, 11, '周五提交报告', 'commitment', '明确交付时间');

void main() {
  test('重点随本机会议保存，重启读取后保留，且不会进入上传原话或触发纪要结构变化', () async {
    final directory = await Directory.systemTemp.createTemp(
      'highlight-history-',
    );
    try {
      final record = MeetingRecord(
        id: 'saved-meeting',
        startedAt: DateTime.utc(2026, 10, 28),
        demo: false,
        ended: true,
        utterances: const [source],
        transcriptHighlights: {
          'source': TranscriptHighlightBatch(raw, 'version', 'trace', [
            hit,
          ]).toJson(),
        },
      );
      final store = LocalMeetingStore(directory: directory);
      await store.save(record);
      final restored = (await LocalMeetingStore(
        directory: directory,
      ).read()).single;
      final batch = TranscriptHighlightBatch.restore(
        restored.transcriptHighlights['source'],
        source.raw,
      );
      expect(batch?.items.single.quote, hit.quote);
      expect(
        TranscriptHighlightBatch.restore(
          restored.transcriptHighlights['source'],
          '已变更原文',
        ),
        isNull,
      );
      expect(
        meetingSyncPayload(
          restored,
          paused: false,
        ).containsKey('transcriptHighlights'),
        isFalse,
      );
      expect(restored.copy(ended: true).transcriptHighlights, isNotEmpty);
    } finally {
      await directory.delete(recursive: true);
    }
  });
  test('UTF-16 范围严格匹配原文，超额、错位和重叠结果丢弃', () {
    final valid = {
      'start': 5,
      'end': 11,
      'quote': '周五提交报告',
      'kind': 'commitment',
      'reason': '交付时间',
    };
    expect(TranscriptHighlight.parse(raw, [valid]), hasLength(1));
    expect(
      TranscriptHighlight.parse(raw, [
        {...valid, 'start': 4},
      ]),
      isEmpty,
    );
    expect(TranscriptHighlight.parse(raw, [valid, valid]), hasLength(1));
    expect(TranscriptHighlight.parse(raw, [valid, valid, valid]), isEmpty);
  });

  test('重复批次和原文版本变化不更新，不通知无关段落', () {
    final store = TranscriptHighlightStore();
    var changed = 0, unrelated = 0;
    store.forSource('source').addListener(() => changed++);
    store.forSource('other').addListener(() => unrelated++);
    final batch = TranscriptHighlightBatch(raw, 'v1', 'trace', [hit]);
    store.accept('source', raw, batch);
    store.accept('source', raw, batch);
    store.accept(
      'source',
      '新原文',
      TranscriptHighlightBatch(raw, 'v2', 'trace2', [hit]),
    );
    expect(changed, 1);
    expect(unrelated, 0);
    store.dispose();
  });

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    testWidgets('异步更新对应原文，重点原因和原声依据可点击 $platform', (tester) async {
      final store = TranscriptHighlightStore();
      var displayed = 0;
      MeetingUtterance? played;
      await tester.runAsync(() => MeetingTermText.dictionary);
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: platform),
          home: Scaffold(
            body: MeetingHighlightedText(
              text: raw,
              style: const TextStyle(fontSize: 14),
              sources: const [source],
              store: store,
              classify: false,
              onReplay: (s) => played = s,
            ),
          ),
        ),
      );
      expect(find.text('重点'), findsNothing);
      store.accept(
        source.id,
        raw,
        TranscriptHighlightBatch(raw, 'v1', 'trace', [
          hit,
        ], onDisplayed: () => displayed++),
      );
      await tester.pump();
      expect(find.text('重点'), findsOneWidget);
      expect(displayed, 1);
      await tester.tap(find.text('重点'));
      await tester.pump();
      expect(find.text('明确交付时间'), findsOneWidget);
      await tester.tap(find.text('原始录音依据'));
      expect(played?.id, source.id);
      expect(played?.audioStart, const Duration(seconds: 3));
      await tester.pump();
      expect(displayed, 1);
      await tester.pumpWidget(const SizedBox());
      store.dispose();
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('合并段落中引用绑定原切片，人工纠错后标注不沿用', (tester) async {
    final store = TranscriptHighlightStore();
    const first = MeetingUtterance(
      id: 'first',
      speaker: 'A',
      raw: '我们开始。',
      at: Duration.zero,
    );
    await tester.runAsync(() => MeetingTermText.dictionary);
    store.accept(
      source.id,
      raw,
      TranscriptHighlightBatch(raw, 'v1', 'trace', [hit]),
    );
    Widget page(List<MeetingUtterance> sources, String text) => MaterialApp(
      home: Scaffold(
        body: MeetingHighlightedText(
          text: text,
          style: const TextStyle(fontSize: 14),
          sources: sources,
          store: store,
          classify: false,
        ),
      ),
    );
    await tester.pumpWidget(page([first, source], '${first.raw}$raw'));
    await tester.pump();
    expect(find.text('重点'), findsOneWidget);
    await tester.pumpWidget(
      page([source.revise(correction: '还没决定交期')], '还没决定交期'),
    );
    await tester.pump();
    expect(find.text('重点'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    store.dispose();
  });
}
