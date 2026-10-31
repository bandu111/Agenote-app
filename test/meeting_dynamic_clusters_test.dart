import 'package:flutter_test/flutter_test.dart';
import 'package:yanshu/features/meeting/meeting_models.dart';
import 'package:yanshu/features/meeting/meeting_insights.dart';
import 'package:yanshu/features/meeting/speech_turn.dart';

void main() {
  final sources = List.generate(
    3,
    (i) => MeetingUtterance(
      id: 's$i',
      speaker: 'A',
      speakerId: 'a',
      raw: '同一轮连续表达$i。',
      at: Duration(seconds: i),
      turnId: 'turn',
    ),
  );
  MeetingInsight hint(
    String id,
    String title,
    String body, {
    String topic = '',
    String issue = '',
    String attention = 'normal',
    InsightKind kind = InsightKind.question,
    String source = 's0',
  }) => MeetingInsight(
    id: id,
    kind: kind,
    title: title,
    body: body,
    evidenceIds: [source],
    topicKey: topic,
    issueKey: issue,
    attention: attention,
  );
  test('三段转写投影为一段与一个播放范围，不改变原始切片', () {
    final clips = List.generate(
      3,
      (i) => MeetingUtterance(
        id: 'c$i',
        speaker: 'A',
        speakerId: 'a',
        raw: '第$i句。',
        at: Duration(seconds: i * 3),
        turnId: 'same',
        audioPath: 'original.wav',
        audioStart: Duration(seconds: i * 3),
        audioEnd: Duration(seconds: i * 3 + 2),
      ),
    );
    final paragraphs = speechParagraphs(clips);
    expect(paragraphs, hasLength(1));
    expect(paragraphs.single.display.display, '第0句。第1句。第2句。');
    expect(paragraphs.single.display.audioStart, Duration.zero);
    expect(paragraphs.single.display.audioEnd, const Duration(seconds: 8));
    expect(clips.map((s) => s.id), ['c0', 'c1', 'c2']);
    expect(
      speechParagraphs([clips[0], clips[1].revise(withdrawn: true), clips[2]]),
      hasLength(3),
    );
  });
  test('旧提示通用近似匹配跨问题和推演类型合并，不靠场景名单', () {
    final result = compactMeetingInsights([
      hint('a', '三个议题是什么？', '已说明讨论三个话题，但具体议题尚未给出，尚需确认。'),
      hint(
        'b',
        '三个议题具体是什么',
        '只说明有三个话题，具体议题尚未展开，尚需确认。',
        kind: InsightKind.prediction,
        source: 's1',
      ),
    ], sources);
    expect(result, hasLength(1));
    expect(result.single.evidenceIds.toSet(), {'s0', 's1'});
  });
  test('不同领域都按对象与问题键聚类，卡片和来源锚点稳定', () {
    for (final topic in ['仓储批次', '报销单据', '课程排期']) {
      final result = compactMeetingInsights([
        hint('first', '材料还缺什么', '尚需核对必要依据。', topic: topic, issue: '必要依据不齐'),
        hint(
          'next',
          '建议先核对凭据',
          '先补齐凭据，再提交审核。',
          topic: topic,
          issue: '必要依据不齐',
          source: 's2',
          kind: InsightKind.prediction,
        ),
      ], sources);
      expect(result, hasLength(1), reason: topic);
      expect(result.single.id, 'first');
      expect(result.single.anchorId, 's0');
      expect(result.single.evidenceIds.toSet(), {'s0', 's2'});
    }
  });
  test('不同对象、不同问题、不同数字条件和真正分支不能乱合并', () {
    final result = compactMeetingInsights([
      hint('a', '凭据待核对', '先核对凭据。', topic: '报销甲', issue: '凭据'),
      hint('b', '凭据待核对', '先核对凭据。', topic: '报销乙', issue: '凭据'),
      hint('c', '金额待核对', '核对金额。', topic: '报销甲', issue: '金额'),
      hint('d', '审核期限', '需要3天。', topic: '报销甲', issue: '时长'),
      hint('e', '审核期限', '需要7天。', topic: '报销甲', issue: '时长'),
    ], sources);
    expect(result, hasLength(5));
  });
  test('自然展开或低价值候选暂缓，重要问题仍可展示', () {
    expect(
      compactMeetingInsights([
        hint('routine', '还有细节没讲', '让对方继续表达。', attention: 'defer'),
        hint(
          'important',
          '存在实际后果',
          '请核对已经冲突的约束。',
          attention: 'urgent',
          kind: InsightKind.risk,
        ),
      ], sources).map((i) => i.id),
      ['important'],
    );
  });
}
