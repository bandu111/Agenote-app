import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yanshu/features/meeting/local_speech.dart';
import 'package:yanshu/features/meeting/meeting_models.dart';
import 'package:yanshu/features/meeting/meeting_terms.dart';
import 'package:yanshu/features/meeting/minutes/meeting_minutes_page.dart';
import 'package:yanshu/features/meeting/minutes/meeting_minutes_playback.dart';
import 'meeting_minutes_test.dart' show mountMinutes, TestMinutesOutput;

// 直接验证整卡背景与边框，而不是只检查“正在回听”文字是否唯一。
void expectPlaybackOutline(WidgetTester tester, String? active) {
  for (final id in ['s0', 's1', 's2']) {
    final card = tester.widget<AnimatedContainer>(
      find.byKey(ValueKey('minutes-playback-card-$id')),
    );
    final decoration = card.decoration! as BoxDecoration;
    final border = decoration.border! as Border;
    expect(
      border.top.color,
      id == active ? const Color(0xFFBED2FF) : Colors.transparent,
    );
    expect(decoration.color == Colors.transparent, id != active);
  }
}

void main() {
  testWidgets('波形保持播放状态，正文点击播放并按进度跟随，用户浏览可退出跟随', (tester) async {
    await tester.runAsync(() => MeetingTermText.dictionary);
    late Directory folder;
    late File file;
    await tester.runAsync(() async {
      folder = await Directory.systemTemp.createTemp('minutes-interaction-');
      file = File('${folder.path}/record.wav');
      await file.writeAsBytes([
        ...meetingWavHeader(640000),
        ...Uint8List(640000),
      ]);
    });
    addTearDown(() async {
      await folder.delete(recursive: true);
    });
    final record = MeetingRecord(
      id: 'minutes-test',
      startedAt: DateTime(2026),
      demo: false,
      elapsed: const Duration(seconds: 20),
      audioPaths: [file.path],
      utterances: [
        for (var i = 0; i < 3; i++)
          MeetingUtterance(
            id: 's$i',
            speaker: '待确认',
            raw: '第$i段普通正文。${List.filled(12, '这是用于验证播放定位和手动浏览的较长发言。').join()}',
            at: Duration(seconds: [4, 12, 18][i]),
            audioPath: file.path,
            audioStart: Duration(seconds: [1, 8, 15][i]),
            audioEnd: Duration(seconds: [4, 12, 18][i]),
          ),
      ],
    );
    final output = TestMinutesOutput();
    await mountMinutes(tester, record: record, output: output);
    final audio = tester
        .widget<MeetingMinutesPage>(find.byType(MeetingMinutesPage))
        .playback!;
    await tester.runAsync(audio.prepareWaveform);
    await tester.pumpAndSettle();
    final wave = find.byKey(const ValueKey('minutes-recording-waveform'));
    final rect = tester.getRect(wave);
    await tester.tapAt(Offset(rect.center.dx, rect.center.dy));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });
    await tester.pumpAndSettle();
    expect(audio.position.inMilliseconds, closeTo(10000, 50));
    expect(audio.playing, isFalse);
    expect(output.played, isNull);
    await tester.runAsync(audio.toggle);
    await tester.pumpAndSettle();
    expect(audio.playing, isTrue);
    final gesture = await tester.startGesture(rect.center);
    await gesture.moveTo(Offset(rect.left + rect.width * .8, rect.center.dy));
    await tester.pump();
    expect(audio.position.inSeconds, 10);
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('minutes-recording-time')))
          .data,
      '00:16 / 00:20',
    );
    await gesture.up();
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });
    await tester.pumpAndSettle();
    expect(audio.position.inMilliseconds, closeTo(16000, 50));
    expect(audio.playing, isTrue);
    await tester.tap(find.text('逐字稿'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('minutes-playing-s2')), findsOneWidget);
    final speaker = tester.getRect(
      find.byKey(const ValueKey('minutes-speaker-s2')),
    );
    final playing = tester.getRect(
      find.byKey(const ValueKey('minutes-playing-s2')),
    );
    expect(speaker.center.dy, closeTo(playing.center.dy, 1));
    expect(playing.left, greaterThanOrEqualTo(speaker.right));
    final card = find.byKey(const ValueKey('minutes-play-source-s1'));
    await tester.ensureVisible(card);
    await tester.pumpAndSettle();
    // 点击正文区域验证扩大后的响应范围，而不是继续只点时间。
    await tester.tap(
      find.byKey(const ValueKey('minutes-annotated-transcript-s1')),
    );
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });
    await tester.pumpAndSettle();
    expect(audio.position.inSeconds, 8);
    expect(find.byKey(const ValueKey('minutes-playing-s1')), findsOneWidget);
    expectPlaybackOutline(tester, 's1');
    output.positions.add(const Duration(seconds: 16));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('minutes-playing-s2')), findsOneWidget);
    expect(find.byKey(const ValueKey('minutes-playing-s1')), findsNothing);
    expectPlaybackOutline(tester, 's2');
    await tester.drag(find.byType(CustomScrollView), const Offset(0, 150));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('minutes-follow-playback')),
      findsOneWidget,
    );
    final scroll = tester
        .widget<CustomScrollView>(find.byType(CustomScrollView))
        .controller!;
    final before = scroll.offset;
    output.positions.add(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(scroll.offset, closeTo(before, 1));
    await tester.tap(find.byKey(const ValueKey('minutes-follow-playback')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('minutes-follow-playback')), findsNothing);
    expect(find.byKey(const ValueKey('minutes-playing-s0')), findsOneWidget);
    await audio.pause();
    await tester.pumpAndSettle();
    expect(find.text('正在回放'), findsNothing);
    expectPlaybackOutline(tester, 's0');
    // 暂停后从波形改到另一段，旧点击条目不得继续保留蓝框。
    scroll.jumpTo(0);
    await tester.pumpAndSettle();
    final pausedWave = tester.getRect(wave);
    await tester.tapAt(pausedWave.center);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await tester.pumpAndSettle();
    expect(audio.playing, isFalse);
    expectPlaybackOutline(tester, 's1');
    await audio.seek(const Duration(seconds: 6), play: false);
    await tester.pumpAndSettle();
    expectPlaybackOutline(tester, null);
    await audio.seek(record.elapsed, play: false);
    await tester.pumpAndSettle();
    expectPlaybackOutline(tester, null);
    expect(tester.takeException(), isNull);
  });
  test('暂停定位不播放，进度边界可恢复播放，静音间隔定位到下一录音', () async {
    final folder = await Directory.systemTemp.createTemp('minutes-seek-');
    final file = File('${folder.path}/part.wav');
    await file.writeAsBytes([...meetingWavHeader(64000), ...Uint8List(64000)]);
    final record = MeetingRecord(
      id: 'parts',
      startedAt: DateTime(2026),
      demo: false,
      elapsed: const Duration(seconds: 10),
      audioPaths: [file.path],
      utterances: [
        MeetingUtterance(
          id: 'source',
          speaker: 'A',
          raw: '原声片段',
          at: const Duration(seconds: 7),
          audioPath: file.path,
          audioStart: Duration.zero,
          audioEnd: const Duration(seconds: 2),
        ),
      ],
    );
    final output = TestMinutesOutput();
    final audio = MeetingMinutesPlayback(record, null, output: output);
    await audio.seek(const Duration(seconds: -3), play: false);
    expect(audio.position, const Duration(seconds: 5));
    expect(output.played, isNull);
    expect(audio.playing, isFalse);
    await audio.toggle();
    expect(audio.playing, isTrue);
    expect(output.at, Duration.zero);
    await audio.seek(const Duration(seconds: 99));
    expect(audio.position, record.elapsed);
    expect(audio.playing, isFalse);
    expect(audio.error, isNull);
    await audio.toggle();
    expect(audio.playing, isTrue);
    expect(audio.position, const Duration(seconds: 5));
    audio.dispose();
    await Future<void>.delayed(Duration.zero);
    await folder.delete(recursive: true);
  });
  testWidgets('点击术语和展开按钮优先，不误触整卡播放', (tester) async {
    await tester.runAsync(() => MeetingTermText.dictionary);
    final record = MeetingRecord(
      id: 'minutes-test',
      startedAt: DateTime(2026),
      demo: false,
      elapsed: const Duration(seconds: 10),
      utterances: const [
        MeetingUtterance(
          id: 'term',
          speaker: 'A',
          raw: 'ERP',
          at: Duration.zero,
        ),
      ],
    );
    await mountMinutes(tester, record: record);
    await tester.tap(find.text('逐字稿'));
    await tester.pumpAndSettle();
    final rich = find
        .descendant(
          of: find.byType(MeetingTermText),
          matching: find.byType(RichText),
        )
        .first;
    await tester.ensureVisible(rich);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pumpAndSettle();
    final paragraph = tester.renderObject<RenderParagraph>(rich);
    final box = paragraph
        .getBoxesForSelection(
          const TextSelection(baseOffset: 0, extentOffset: 3),
        )
        .first;
    await tester.tapAt(paragraph.localToGlobal(box.toRect().center));
    await tester.pumpAndSettle();
    final audio = tester
        .widget<MeetingMinutesPage>(find.byType(MeetingMinutesPage))
        .playback!;
    expect(find.text('术语解释 · ERP'), findsOneWidget);
    expect(audio.error, isNull);
    expect(audio.playing, isFalse);
    await tester.tap(find.text('收起上下文'));
    await tester.pumpAndSettle();
    expect(find.text('术语解释 · ERP'), findsNothing);
    expect(audio.error, isNull);
    expect(tester.takeException(), isNull);
  });
  testWidgets('小屏大字体下发言人与回放提示仍在同一行', (tester) async {
    await tester.runAsync(() => MeetingTermText.dictionary);
    late Directory folder;
    late File file;
    await tester.runAsync(() async {
      folder = await Directory.systemTemp.createTemp('minutes-inline-status-');
      file = File('${folder.path}/record.wav');
      await file.writeAsBytes([
        ...meetingWavHeader(64000),
        ...Uint8List(64000),
      ]);
    });
    addTearDown(() => folder.delete(recursive: true));
    final record = MeetingRecord(
      id: 'minutes-test',
      startedAt: DateTime(2026),
      demo: false,
      elapsed: const Duration(seconds: 2),
      audioPaths: [file.path],
      utterances: [
        MeetingUtterance(
          id: 'speaker',
          speaker: '待区分发言人',
          raw: '测试回放提示的同行布局。',
          at: const Duration(seconds: 2),
          audioPath: file.path,
          audioStart: Duration.zero,
          audioEnd: const Duration(seconds: 2),
        ),
      ],
    );
    await mountMinutes(tester, record: record, width: 320, textScale: 2.2);
    final audio = tester
        .widget<MeetingMinutesPage>(find.byType(MeetingMinutesPage))
        .playback!;
    await tester.runAsync(() => audio.seek(Duration.zero));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('逐字稿'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('逐字稿'));
    await tester.pumpAndSettle();
    final speaker = tester.getRect(
      find.byKey(const ValueKey('minutes-speaker-speaker')),
    );
    final playing = tester.getRect(
      find.byKey(const ValueKey('minutes-playing-speaker')),
    );
    expect(speaker.center.dy, closeTo(playing.center.dy, 1));
    expect(playing.left, greaterThanOrEqualTo(speaker.right));
    expect(find.text('正在回放'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
