import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:yanshu/features/meeting/meeting_terms.dart';
import 'package:yanshu/features/meeting/transcript_highlight_models.dart';

void main() {
  testWidgets('术语与整句重点重叠时仍保留术语点击，不吞掉任何原文', (tester) async {
    const raw = '乙负责ERP接口，周五提交。';
    MeetingTermMatch? term;
    var highlighted = false;
    await tester.runAsync(() => MeetingTermText.dictionary);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MeetingTermText(
            text: raw,
            style: const TextStyle(fontSize: 14),
            classify: false,
            highlights: const [
              TranscriptHighlight(0, raw.length, raw, 'commitment', '交付承诺'),
            ],
            onTermTap: (value) => term = value,
            onHighlightTap: (_) => highlighted = true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pumpAndSettle();
    final rich = tester.widget<RichText>(
      find.descendant(
        of: find.byType(MeetingTermText),
        matching: find.byType(RichText),
      ),
    );
    expect(rich.text.toPlainText(), raw);
    Iterable<TextSpan> allSpans(InlineSpan span) sync* {
      if (span is TextSpan) {
        yield span;
        for (final child in span.children ?? <InlineSpan>[]) {
          yield* allSpans(child);
        }
      }
    }

    final spans = allSpans(rich.text).toList();
    final erp = spans.firstWhere((s) => s.text == 'ERP');
    (erp.recognizer as TapGestureRecognizer).onTap!();
    expect(term?.term, 'ERP');
    expect(highlighted, false);
    final other = spans.firstWhere((s) => s.text == '乙负责');
    (other.recognizer as TapGestureRecognizer).onTap!();
    expect(highlighted, true);
    expect(tester.takeException(), isNull);
  });
  testWidgets('术语标记隐藏双括号，保留原句和点击释义', (tester) async {
    const text = '乙先完成ERP接口。';
    MeetingTermMatch? selected;
    await tester.runAsync(() => MeetingTermText.dictionary);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MeetingTermText(
            text: text,
            style: const TextStyle(fontSize: 14),
            classify: false,
            onTermTap: (term) => selected = term,
          ),
        ),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
    await tester.pumpAndSettle();
    final rich = tester.widget<RichText>(
      find.descendant(
        of: find.byType(MeetingTermText),
        matching: find.byType(RichText),
      ),
    );
    expect(rich.text.toPlainText(), text);
    Iterable<TextSpan> descendants(InlineSpan span) sync* {
      if (span is TextSpan) {
        yield span;
        for (final child in span.children ?? <InlineSpan>[]) {
          yield* descendants(child);
        }
      }
    }

    final terms = descendants(
      rich.text,
    ).where((span) => span.recognizer != null).toList();
    expect(terms, isNotEmpty);
    expect(terms.first.style!.decoration, TextDecoration.underline);
    expect(terms.first.style!.backgroundColor, isNotNull);
    (terms.first.recognizer as TapGestureRecognizer).onTap!();
    await tester.pumpAndSettle();
    expect(selected?.term, isNotEmpty);
    expect(selected?.definition, isNotEmpty);
    expect(find.byType(BottomSheet), findsNothing);
    expect(tester.takeException(), isNull);
  });
  test('原文偏移保留，英文边界、最长匹配和歧义保护', () {
    final items = [
      for (final word in ['ERP', 'API', '灰度', '灰度发布'])
        {
          'term': word,
          'definition': word,
          'enabled': true,
          'match_policy': 'direct',
        },
      {
        'term': '对齐',
        'definition': '歧义词',
        'enabled': true,
        'match_policy': 'context',
      },
    ];
    const text = '😀ERP与CAPITAL对齐，周四灰度发布';
    final hits = matchMeetingTerms(text, items);
    expect(hits.map((h) => h.term), ['ERP', '灰度发布']);
    expect(hits.first.start, 2);
    for (final hit in hits) {
      expect(text.substring(hit.start, hit.end), hit.term);
    }
  });
}
