import 'package:flutter_test/flutter_test.dart';
import 'package:yanshu/features/meeting/meeting_models.dart';
import 'package:yanshu/features/meeting/meeting_insights.dart';
import 'package:yanshu/features/meeting/speech_turn.dart';

void main() {
  MeetingUtterance source(String id, int start, int end, {int? arrived}) =>
      MeetingUtterance(
        id: id,
        speaker: 'A',
        speakerId: 'a',
        speakerSeparated: true,
        raw: '同一人连续表达。',
        at: Duration(milliseconds: arrived ?? end),
        turnId: 'same',
        audioPath: 'original.wav',
        audioStart: Duration(milliseconds: start),
        audioEnd: Duration(milliseconds: end),
      );

  test('录音间隔恰好2秒合并，超过2秒另起段，长句和网络晚到不误拆', () {
    final clips = [
      source('a', 0, 30000),
      source('b', 32000, 40000, arrived: 180000),
      source('c', 42001, 50000),
    ];
    expect(
      speechTurnGroups(clips).map((g) => g.map((u) => u.id).toList()).toList(),
      [
        ['a', 'b'],
        ['c'],
      ],
    );
    expect(speechParagraphs(clips), hasLength(2));
    expect(clips[1].turnId, 'same', reason: '显示分段不打断分析上下文');
  });

  test('旧记录缺少原声音频边界时，不能跨明显的时间间隔合段', () {
    final old = [
      const MeetingUtterance(
        id: 'a',
        speaker: 'A',
        raw: '第一段。',
        at: Duration.zero,
        turnId: 'same',
      ),
      const MeetingUtterance(
        id: 'b',
        speaker: 'A',
        raw: '过会儿再说。',
        at: Duration(seconds: 3),
        turnId: 'same',
      ),
    ];
    expect(speechTurnGroups(old), hasLength(2));
  });

  test('不同问题键但标题正文近似时合并，保留更完整的影响评估并放入补充', () {
    final sources = [source('a', 0, 4000)];
    final result = compactMeetingInsights([
      const MeetingInsight(
        id: 'first',
        kind: InsightKind.question,
        title: '确认ERP接口超时影响',
        body: 'ERP接口偶尔超时，需确认是否影响同步结果及上线。',
        evidenceIds: ['a'],
        topicKey: 'ERP接口',
        issueKey: '确认超时影响',
      ),
      const MeetingInsight(
        id: 'later',
        kind: InsightKind.question,
        title: 'ERP接口超时影响待评估',
        body: 'ERP接口偶尔超时，尚未回答对业务的实际影响，需补充影响范围及是否阻塞上线。',
        evidenceIds: ['a'],
        topicKey: 'ERP接口',
        issueKey: '业务影响待评估',
      ),
    ], sources);
    expect(result, hasLength(1));
    expect(result.single.id, 'first');
    expect(result.single.body, contains('实际影响'));
    expect(isInlineMeetingSuggestion(result.single), isTrue);
  });

  test('每段最多两个重要警告，优先紧急和有实际价值的，其余可在补充查看', () {
    final group = [source('a', 0, 4000)];
    final items = [
      for (var i = 0; i < 5; i++)
        MeetingInsight(
          id: 'risk$i',
          kind: InsightKind.risk,
          title: '独立风险$i',
          body: '分别需要检查。',
          evidenceIds: ['a'],
          anchorId: 'a',
          topicKey: '对象$i',
          issueKey: '问题$i',
          attention: i == 4 ? 'urgent' : 'normal',
          impact: i >= 3 ? '明确业务后果' : '',
        ),
      const MeetingInsight(
        id: 'question',
        kind: InsightKind.question,
        title: '确认影响范围',
        body: '请补充影响范围。',
        evidenceIds: ['a'],
        anchorId: 'a',
      ),
      const MeetingInsight(
        id: 'memory',
        kind: InsightKind.stitch,
        title: '话题接回·待核对',
        body: '保留关联依据。',
        evidenceIds: ['a'],
        anchorId: 'a',
      ),
    ];
    final layout = MeetingHintLayout(items, [group]);
    expect(layout.standalone, {'risk3', 'risk4', 'memory'});
    expect(
      items.where(layout.isInline).map((i) => i.id),
      containsAll(['risk0', 'risk1', 'risk2', 'question']),
    );
    expect(items, hasLength(7), reason: '显示配额不删除底层候选或证据');
  });
}
