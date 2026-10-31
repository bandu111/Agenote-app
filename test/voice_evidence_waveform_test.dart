import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:yanshu/features/progress/viewmodels/voice_evidence_controller.dart';
import 'package:yanshu/features/progress/widgets/voice_evidence_player.dart';
import 'progress_view_model_test.dart' show FakeEvidencePlayer, evidence;

void main() {
  testWidgets('waveform seeks, previews drag and preserves playback state', (
    tester,
  ) async {
    final player = FakeEvidencePlayer();
    final audio = VoiceEvidenceController(player: player);
    addTearDown(audio.dispose);
    final clip = evidence('waveform');
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: audio,
        child: MaterialApp(
          home: Scaffold(
            body: VoiceEvidencePlayer(evidence: clip, detail: true),
          ),
        ),
      ),
    );
    expect(find.byType(Slider), findsNothing);
    final wave = find.byKey(const ValueKey('voice-detail-waveform'));
    final bounds = tester.getRect(wave);
    await tester.tapAt(
      Offset(bounds.left + bounds.width / 2, bounds.center.dy),
    );
    await tester.pumpAndSettle();
    expect(audio.position.inSeconds, 19);
    expect(audio.state, VoicePlaybackState.paused);
    expect(player.plays, 0);

    await audio.toggle(clip);
    await tester.pumpAndSettle();
    // 拖动预览不改变设备位置；松手后才定位，且不打断正在播放的状态。
    final gesture = await tester.startGesture(
      Offset(bounds.left + bounds.width / 2, bounds.center.dy),
    );
    await gesture.moveTo(
      Offset(bounds.left + bounds.width * .75, bounds.center.dy),
    );
    await tester.pump();
    expect(audio.position.inSeconds, 19);
    final preview = tester
        .widget<Text>(find.byKey(const ValueKey('voice-detail-time')))
        .data!;
    expect(preview, '00:28 / 00:38');
    await gesture.up();
    await tester.pumpAndSettle();
    expect(audio.position.inMilliseconds, closeTo(28500, 100));
    expect(audio.state, VoicePlaybackState.playing);
    expect(player.plays, 1);

    await audio.toggle(clip);
    await tester.pumpAndSettle();
    await tester.tapAt(
      Offset(bounds.left + bounds.width * .25, bounds.center.dy),
    );
    await tester.pumpAndSettle();
    expect(audio.position.inMilliseconds, closeTo(9500, 100));
    expect(audio.state, VoicePlaybackState.paused);
    // 无障碍调节与点击/拖动共用控制器边界保护。
    await audio.seek(const Duration(seconds: -5), source: clip);
    expect(audio.position, Duration.zero);
    await audio.seek(const Duration(seconds: 100), source: clip);
    expect(audio.position, clip.duration);
    expect(tester.takeException(), isNull);
  });
}
