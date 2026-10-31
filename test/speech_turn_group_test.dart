import 'package:flutter_test/flutter_test.dart';
import 'package:yanshu/features/meeting/meeting_models.dart';
import 'package:yanshu/features/meeting/speech_turn.dart';

void main() {
  MeetingUtterance fragment(
    String id,
    String turn, {
    String speaker = 'a',
    String? path = '录音.wav',
  }) => MeetingUtterance(
    id: id,
    speaker: speaker,
    speakerId: speaker,
    speakerSeparated: true,
    raw: '原话$id',
    at: Duration.zero,
    turnId: turn,
    audioPath: path,
  );

  test('同轮显示聚合但保留原始片段、原声、修正与证据身份', () {
    final first = fragment('one', 'turn').revise(withdrawn: true);
    final second = fragment('two', 'turn').revise(correction: '人工纠错');
    final groups = speechTurnGroups([first, second]);
    expect(groups, hasLength(1));
    expect(identical(groups.single.first, first), isTrue);
    expect(identical(groups.single.last, second), isTrue);
    expect(groups.single.first.withdrawn, isTrue);
    expect(groups.single.last.display, '人工纠错');
  });

  test('身份更正、下一轮发言及不同录音文件不会错误拼接', () {
    expect(
      speechTurnGroups([
        fragment('one', 'turn'),
        fragment('two', 'turn', speaker: 'b'),
        fragment('three', 'next', speaker: 'b'),
        fragment('four', 'next', speaker: 'b', path: '新录音.wav'),
      ]),
      hasLength(4),
    );
  });

  test('旧记录缺少轮次不能只凭同名说话人跨时间拼接', () {
    const item = MeetingUtterance(
      id: 'old',
      speaker: 'A',
      raw: '旧原话',
      at: Duration.zero,
    );
    expect(speechTurnGroups([item, item]), hasLength(2));
  });
}
