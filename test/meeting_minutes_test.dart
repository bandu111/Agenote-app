import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yanshu/features/meeting/local_speech.dart';
import 'package:yanshu/features/meeting/meeting_models.dart';
import 'package:yanshu/features/meeting/meeting_terms.dart';
import 'package:yanshu/features/meeting/transcript_highlights.dart';
import 'package:yanshu/features/meeting/minutes/meeting_minutes_data.dart';
import 'package:yanshu/features/meeting/minutes/meeting_minutes_page.dart';
import 'package:yanshu/features/meeting/minutes/meeting_minutes_playback.dart';
import 'support/minutes_fixture.dart';

class TestMinutesOutput implements MinutesAudioOutput {
  final positions = StreamController<Duration>.broadcast(sync: true);
  final completed = StreamController<void>.broadcast(sync: true);
  String? played;
  Duration? at;
  double rate = 1;
  @override
  Stream<Duration> get onPositionChanged => positions.stream;
  @override
  Stream<void> get onPlayerComplete => completed.stream;
  @override
  Future<void> play(String path, Duration position) async {
    played = path;
    at = position;
  }

  @override
  Future<void> pause() async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> setPlaybackRate(double value) async {
    rate = value;
  }

  @override
  Future<void> dispose() async {
    await positions.close();
    await completed.close();
  }
}

Future<void> mountMinutes(
  WidgetTester tester, {
  MeetingRecord? record,
  double width = 393,
  double textScale = 1,
  String? focusAction,
  TestMinutesOutput? output,
  String? relationLabel,
  String? relationQuery,
  String? relationQuote,
}) async {
  tester.view.physicalSize = Size(width, 852);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.runAsync(() async {
    if (Platform.isWindows &&
        await File('C:/Windows/Fonts/msyh.ttc').exists()) {
      final loader = FontLoader('Minutes QA')
        ..addFont(
          File(
            'C:/Windows/Fonts/msyh.ttc',
          ).readAsBytes().then(ByteData.sublistView),
        );
      await loader.load();
    }
    final icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
  });
  final sample = record ?? minutesFixture();
  final playback = MeetingMinutesPlayback(
    sample,
    null,
    output: output ?? TestMinutesOutput(),
  );
  addTearDown(playback.dispose);
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(
        useMaterial3: true,
        fontFamily: 'Minutes QA',
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF065CFF)),
        scaffoldBackgroundColor: Colors.white,
      ),
      home: MediaQuery(
        data: MediaQueryData(
          size: Size(width, 852),
          textScaler: TextScaler.linear(textScale),
        ),
        child: RepaintBoundary(
          key: const ValueKey('minutes-capture'),
          child: MeetingMinutesPage(
            id: 'minutes-test',
            previewRecord: sample,
            playback: playback,
            focusAction: focusAction,
            relationLabel: relationLabel,
            relationQuery: relationQuery,
            relationQuote: relationQuote,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> capture(WidgetTester tester, String name) async {
  if (!const bool.fromEnvironment('MINUTES_CAPTURE')) return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const ValueKey('minutes-capture')),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final dir = Directory('build/minutes-qa');
    await dir.create(recursive: true);
    await File(
      '${dir.path}/$name.png',
    ).writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  testWidgets('AI纪要标题标识及议题独立折叠，长标题始终单行', (tester) async {
    final record = minutesFixture();
    final details = Map<String, dynamic>.from(record.minutesDetails!);
    final topics = [
      for (final topic in details['topics'] as List)
        Map<String, dynamic>.from(topic as Map),
    ];
    topics.first['title'] = List.filled(8, '这是一个较长的议题标题').join();
    details['topics'] = topics;
    await mountMinutes(
      tester,
      record: record.copy(minutesDetails: details),
      width: 320,
      textScale: 1.5,
    );
    for (final title in ['一页读懂会议', '主要讨论', '会议结论', '后续行动', '待澄清']) {
      expect(
        find.byKey(ValueKey('minutes-heading-bar-$title')),
        findsOneWidget,
      );
    }
    final toggle = find.byKey(const ValueKey('minutes-topic-toggle-0'));
    final header = find.byKey(const ValueKey('minutes-topic-header-0'));
    final title = tester.widget<Text>(
      find.byKey(const ValueKey('minutes-topic-title-0')),
    );
    expect(title.maxLines, 1);
    expect(title.overflow, TextOverflow.ellipsis);
    expect(title.style!.fontSize, 15);
    expect(title.style!.fontWeight, FontWeight.w500);
    expect(find.byKey(const ValueKey('minutes-topic-body-0')), findsNothing);
    expect(find.byKey(const ValueKey('minutes-topic-body-1')), findsNothing);
    await tester.ensureVisible(toggle);
    await tester.pumpAndSettle();
    final headerHeight = tester.getSize(header).height;
    expect(headerHeight, lessThanOrEqualTo(36));
    expect(
      tester.getSize(find.byKey(const ValueKey('minutes-topic-0'))).height,
      lessThanOrEqualTo(38),
    );
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('minutes-topic-body-0')), findsOneWidget);
    expect(find.byKey(const ValueKey('minutes-topic-body-1')), findsNothing);
    expect(tester.getSize(header).height, headerHeight);
    await tester.ensureVisible(toggle);
    await tester.pumpAndSettle();
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('minutes-topic-body-0')), findsNothing);
    expect(tester.getSize(header).height, headerHeight);
    expect(tester.takeException(), isNull);
  });

  testWidgets('逐字稿优先人工纠正，空白整理回退原文', (tester) async {
    await tester.runAsync(() => MeetingTermText.dictionary);
    final record = minutesFixture().copy(
      utterances: const [
        MeetingUtterance(
          id: 'corrected',
          speaker: 'A',
          raw: '原始',
          cleaned: '整理版。',
          correction: '人工纠正版。',
          at: Duration.zero,
        ),
        MeetingUtterance(
          id: 'fallback',
          speaker: 'A',
          raw: '原始回退文本',
          cleaned: '  ',
          correction: ' ',
          at: Duration(seconds: 2),
        ),
      ],
    );
    await mountMinutes(tester, record: record);
    await tester.tap(find.text('逐字稿'));
    await tester.pumpAndSettle();
    for (final pair in [('corrected', '人工纠正版。'), ('fallback', '原始回退文本')]) {
      final text = tester.widget<MeetingHighlightedText>(
        find.byKey(ValueKey('minutes-annotated-transcript-${pair.$1}')),
      );
      expect(text.text, pair.$2);
      expect(text.useRawText, isFalse);
    }
    expect(record.utterances.first.raw, '原始');
    expect(tester.takeException(), isNull);
  });

  testWidgets('纪要逐字稿整段标记，发言人旁蓝底白字重点不可展开，术语仍可点击', (tester) async {
    const raw = '乙负责ERP接口修复，周五提交。';
    final batch = TranscriptHighlightBatch(raw, 'v1', 'trace', [
      const TranscriptHighlight(0, raw.length, raw, 'commitment', '明确交付事项和交期'),
    ]);
    final record = minutesFixture().copy(
      utterances: const [
        MeetingUtterance(
          id: 'u0',
          speaker: 'A',
          raw: raw,
          cleaned: '整理后：乙负责ERP接口修复，周五提交。',
          at: Duration.zero,
        ),
      ],
      transcriptHighlights: {'u0': batch.toJson()},
    );
    await tester.runAsync(() => MeetingTermText.dictionary);
    await mountMinutes(tester, record: MeetingRecord.fromJson(record.toJson()));
    await tester.tap(find.text('逐字稿'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('minutes-annotated-transcript-u0')),
      findsOneWidget,
    );
    expect(find.text('重点'), findsOneWidget);
    final badge = tester.widget<Container>(
      find.byKey(const ValueKey('minutes-important-u0')),
    );
    expect((badge.decoration as BoxDecoration).color, const Color(0xFF065CFF));
    expect(tester.widget<Text>(find.text('重点')).style!.color, Colors.white);
    await tester.tap(find.text('重点'));
    await tester.pumpAndSettle();
    expect(find.text('明确交付事项和交期'), findsNothing);
    expect(
      find.byKey(const ValueKey('transcript-highlight-label')),
      findsNothing,
    );
    expect(find.text('收起上下文'), findsNothing);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pumpAndSettle();
    final rich = tester.widget<RichText>(
      find
          .descendant(
            of: find.byType(MeetingTermText),
            matching: find.byType(RichText),
          )
          .first,
    );
    expect(rich.text.toPlainText(), '整理后：乙负责ERP接口修复，周五提交。');
    expect(rich.text.style!.decoration, TextDecoration.underline);
    Iterable<TextSpan> allSpans(InlineSpan span) sync* {
      if (span is TextSpan) {
        yield span;
        for (final child in span.children ?? <InlineSpan>[]) {
          yield* allSpans(child);
        }
      }
    }

    final erp = allSpans(rich.text).firstWhere((s) => s.text == 'ERP');
    (erp.recognizer as TapGestureRecognizer).onTap!();
    await tester.pumpAndSettle();
    expect(find.text('术语解释 · ERP'), findsOneWidget);
    expect(find.text('明确交付事项和交期'), findsNothing);
    expect(find.text('收起上下文'), findsOneWidget);
    expect(find.byType(Dialog), findsNothing);
    expect(find.byType(BottomSheet), findsNothing);
    await tester.tap(find.text('收起上下文'));
    await tester.pumpAndSettle();
    expect(find.text('术语解释 · ERP'), findsNothing);
    expect(tester.takeException(), isNull);
  });
  testWidgets('纪要行动来源补回漏标，术语本身不使普通段落变重点', (tester) async {
    final record = minutesFixture().copy(
      utterances: const [
        MeetingUtterance(
          id: 'action',
          speaker: '发言人 A',
          raw: '这块我来跟进，处理完告诉大家。',
          at: Duration(seconds: 2),
        ),
        MeetingUtterance(
          id: 'term',
          speaker: '发言人 B',
          raw: '我们继续聊ERP。',
          at: Duration(seconds: 9),
        ),
      ],
      minutesDetails: {
        'actions': [
          {
            'id': 'a',
            'text': '跟进并反馈处理结果',
            'evidence_ids': ['action'],
          },
        ],
        'topics': [
          {
            'id': 't',
            'text': 'ERP相关讨论',
            'evidence_ids': ['term'],
          },
        ],
      },
      transcriptHighlights: const {},
    );
    await mountMinutes(tester, record: record);
    await tester.tap(find.text('逐字稿'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('minutes-important-action')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('minutes-important-term')), findsNothing);
    final paragraph = tester.widget<MeetingHighlightedText>(
      find.byKey(const ValueKey('minutes-annotated-transcript-action')),
    );
    expect(paragraph.paragraphEmphasis, isTrue);
    expect(paragraph.paragraphImportant, isTrue);
    expect(paragraph.text, '这块我来跟进，处理完告诉大家。');
    expect(
      find.byKey(const ValueKey('transcript-highlight-label')),
      findsNothing,
    );
    expect(find.text('收起上下文'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'goal relation opens its original transcript with a label and no autoplay',
    (tester) async {
      final output = TestMinutesOutput();
      await mountMinutes(
        tester,
        relationLabel: '目标关联 · 接口验证',
        relationQuery: '接口兼容性',
        relationQuote: '优先推进接口兼容性验证〔来源：u3〕',
        output: output,
      );
      expect(find.text('目标关联 · 接口验证'), findsOneWidget);
      expect(
        find.text('目前部分接口还需要完成跨平台兼容性验证，建议优先处理这些问题，其他的可以往后排。'),
        findsOneWidget,
      );
      expect(output.played, isNull);
      // 来源标签是导航提示，不应伪装成当前正在回放的蓝色整卡边框。
      expect(
        find.byKey(const ValueKey('minutes-reference-label-u3')),
        findsOneWidget,
      );
      for (final u in minutesFixture().utterances) {
        final card = tester.widget<AnimatedContainer>(
          find.byKey(ValueKey('minutes-playback-card-${u.id}')),
        );
        final decoration = card.decoration! as BoxDecoration;
        expect((decoration.border! as Border).top.color, Colors.transparent);
        expect(decoration.color, Colors.transparent);
      }
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'home action link scrolls to and highlights its minutes row without audio',
    (tester) async {
      final output = TestMinutesOutput();
      await mountMinutes(tester, focusAction: 'a3', output: output);
      final text = find.text('汇总跨平台验证结果并同步到团队');
      expect(text, findsOneWidget);
      expect(tester.getRect(text).top, greaterThan(100));
      expect(tester.getRect(text).bottom, lessThan(852));
      final containers = tester.widgetList<Container>(
        find.ancestor(of: text, matching: find.byType(Container)),
      );
      expect(
        containers.any(
          (c) =>
              c.decoration is BoxDecoration &&
              (c.decoration as BoxDecoration).border != null,
        ),
        true,
      );
      expect(output.played, isNull);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('transcript keeps only the top meeting recording player', (
    tester,
  ) async {
    await mountMinutes(tester);
    await tester.tap(find.text('逐字稿'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('播放会议录音'), findsOneWidget);
    expect(find.text('会议录音'), findsOneWidget);
    expect(find.byType(Slider), findsNothing);
    expect(find.text('1.0x'), findsNothing);
    expect(tester.takeException(), isNull);
  });
  testWidgets('meeting menu is a bottom sheet with reload and delete only', (
    tester,
  ) async {
    await mountMinutes(tester);
    await tester.tap(find.byTooltip('会议操作'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('minutes-menu-sheet')), findsOneWidget);
    expect(find.text('重新加载'), findsOneWidget);
    expect(find.text('删除这场会议'), findsOneWidget);
    expect(find.text('分享纪要链接'), findsNothing);
    await tester.tap(find.text('删除这场会议'));
    await tester.pumpAndSettle();
    expect(find.text('删除这场会议？'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('会议纪要'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'structured minutes and raw Markdown survive local history serialization',
    () {
      final r = minutesFixture().copy(cloudMinutes: '# 会议纪要\n## 当前共识\n原文');
      final restored = MeetingRecord.fromJson(r.toJson());
      expect(restored.cloudMinutes, r.cloudMinutes);
      expect(MeetingMinutesData.fromRecord(restored).topics.length, 3);
      expect(
        MeetingMinutesData.fromRecord(restored).decisions[2].status,
        'discussed',
      );
      expect(minutesPlain('**完成 [[ERP]] 接口**'), '完成 ERP 接口');
    },
  );
  test(
    'legacy minutes keep valid source ids and exclude missing or withdrawn evidence',
    () {
      final r = MeetingRecord(
        id: 'old',
        startedAt: DateTime(2026),
        demo: false,
        cloudMinutes:
            '## 当前共识\n- 先验证接口〔来源：u1〕\n- 无效来源〔来源：missing〕\n- 撤回了〔来源：u2〕',
        utterances: [
          const MeetingUtterance(
            id: 'u1',
            speaker: 'A',
            raw: '先验证接口',
            at: Duration(seconds: 12),
          ),
          const MeetingUtterance(
            id: 'u2',
            speaker: 'B',
            raw: '撤回了',
            at: Duration(seconds: 15),
            withdrawn: true,
          ),
        ],
      );
      final data = MeetingMinutesData.fromRecord(r);
      expect(data.decisions.single.text, '先验证接口');
      expect(
        data.source(r, data.decisions.single)!.at,
        const Duration(seconds: 12),
      );
    },
  );
  test(
    'recording playback seeks to original audio and updates the actual cursor',
    () async {
      final dir = await Directory.systemTemp.createTemp('minutes-audio-test-');
      final file = File('${dir.path}/original.wav');
      await file.writeAsBytes([
        ...meetingWavHeader(64000),
        ...Uint8List(64000),
      ]);
      final output = TestMinutesOutput();
      final r = MeetingRecord(
        id: 'audio',
        startedAt: DateTime(2026),
        demo: false,
        audioPaths: [file.path],
        elapsed: const Duration(seconds: 2),
        utterances: [
          MeetingUtterance(
            id: 'u',
            speaker: 'A',
            raw: '原始发言',
            at: const Duration(seconds: 2),
            audioPath: file.path,
            audioStart: const Duration(seconds: 1),
            audioEnd: const Duration(seconds: 2),
          ),
        ],
      );
      final audio = MeetingMinutesPlayback(r, null, output: output);
      await audio.seek(minutesUtteranceStart(r.utterances.single));
      expect(output.played, file.path);
      expect(output.at, const Duration(seconds: 1));
      expect(audio.playing, true);
      output.positions.add(const Duration(milliseconds: 1500));
      expect(audio.position, const Duration(milliseconds: 1500));
      await audio.cycleSpeed();
      expect(output.rate, 1.25);
      await audio.pause();
      expect(audio.playing, false);
      audio.dispose();
      await Future<void>.delayed(Duration.zero);
      await dir.delete(recursive: true);
    },
  );
  testWidgets(
    'minutes page follows reference sections without Markdown or share/footer clutter',
    (tester) async {
      await mountMinutes(tester);
      expect(find.text('会议纪要'), findsOneWidget);
      expect(find.text('一页读懂会议'), findsOneWidget);
      expect(find.text('思维导图'), findsOneWidget);
      expect(find.textContaining('演示数据'), findsNothing);
      expect(find.byIcon(Icons.share), findsNothing);
      await capture(tester, 'summary');
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'source link switches to transcript, locates utterance and displays origin label',
    (tester) async {
      await mountMinutes(tester);
      final toggle = find.byKey(const ValueKey('minutes-topic-toggle-0'));
      await tester.ensureVisible(toggle);
      await tester.pumpAndSettle();
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      final button = find.textContaining('12:35  ·  查看原始依据').first;
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(find.text('接口兼容性'), findsOneWidget);
      expect(
        find.text('目前部分接口还需要完成跨平台兼容性验证，建议优先处理这些问题，其他的可以往后排。'),
        findsOneWidget,
      );
      await capture(tester, 'transcript-source');
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'map pans and pinches without scrolling its parent; outside still scrolls',
    (tester) async {
      await mountMinutes(tester);
      await tester.tap(find.text('思维导图'));
      await tester.pumpAndSettle();
      expect(find.text('会议结构'), findsOneWidget);
      await capture(tester, 'mindmap');
      expect(find.byTooltip('放大'), findsNothing);
      expect(find.byTooltip('缩小'), findsNothing);
      expect(find.byTooltip('重置视图'), findsNothing);
      final canvas = find.byKey(const ValueKey('minutes-mind-map-canvas'));
      await tester.ensureVisible(canvas);
      await tester.pumpAndSettle();
      final viewer = find.byType(InteractiveViewer);
      final transform = tester
          .widget<InteractiveViewer>(viewer)
          .transformationController!;
      final page = tester
          .widget<CustomScrollView>(find.byType(CustomScrollView))
          .controller!;
      final pageOffset = page.offset;
      final initial = transform.value.clone();
      final center = tester.getCenter(canvas);
      final pan = await tester.startGesture(center);
      await tester.pump();
      expect(
        tester.widget<CustomScrollView>(find.byType(CustomScrollView)).physics,
        isA<NeverScrollableScrollPhysics>(),
      );
      await pan.moveBy(const Offset(-45, -35));
      await tester.pump();
      await pan.moveBy(const Offset(-40, -25));
      await pan.up();
      await tester.pumpAndSettle();
      expect(transform.value.storage, isNot(orderedEquals(initial.storage)));
      expect(page.offset, closeTo(pageOffset, .1));
      final beforeScale = transform.value.getMaxScaleOnAxis();
      final first = await tester.startGesture(
        center - const Offset(35, 0),
        pointer: 1,
      );
      final second = await tester.startGesture(
        center + const Offset(35, 0),
        pointer: 2,
      );
      await tester.pump();
      await first.moveTo(center - const Offset(65, 0));
      await second.moveTo(center + const Offset(65, 0));
      await tester.pump();
      await first.moveTo(center - const Offset(90, 0));
      await second.moveTo(center + const Offset(90, 0));
      await tester.pump();
      await first.up();
      await second.up();
      await tester.pumpAndSettle();
      expect(transform.value.getMaxScaleOnAxis(), greaterThan(beforeScale));
      expect(page.offset, closeTo(pageOffset, .1));
      expect(
        tester.widget<CustomScrollView>(find.byType(CustomScrollView)).physics,
        isNot(isA<NeverScrollableScrollPhysics>()),
      );
      await tester.dragFrom(const Offset(8, 400), const Offset(0, 90));
      await tester.pumpAndSettle();
      expect(page.offset, lessThan(pageOffset));
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('small screen and large text do not overflow', (tester) async {
    await mountMinutes(tester, width: 320, textScale: 1.5);
    await tester.tap(find.text('逐字稿'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
