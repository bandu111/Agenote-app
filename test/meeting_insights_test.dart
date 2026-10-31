import 'package:flutter_test/flutter_test.dart';
import 'package:yanshu/features/meeting/meeting_insights.dart';
import 'package:yanshu/features/meeting/meeting_models.dart';

MeetingInsight hint(
  String id,
  String body,
  List<String> refs, {
  String? anchor,
  bool streaming = false,
}) => MeetingInsight(
  id: id,
  kind: InsightKind.question,
  title: 'AI 补充',
  body: body,
  evidenceIds: refs,
  anchorId: anchor,
  streaming: streaming,
);
const sources = [
  MeetingUtterance(
    id: 'a',
    speaker: '发言人 A',
    raw: 'Windows尚未批准。',
    at: Duration.zero,
  ),
  MeetingUtterance(
    id: 'b',
    speaker: '发言人 B',
    raw: '接下来讨论交期。',
    at: Duration(seconds: 10),
  ),
];

void main() {
  test('真正包含替代分支的前瞻不被并入同主题的信息缺口', () {
    final result = compactMeetingInsights([
      const MeetingInsight(
        id: 'gap',
        kind: InsightKind.question,
        title: 'ERP验收口径待明确',
        body: '需要确认ERP稳定运行的验收条件。',
        evidenceIds: ['a'],
      ),
      const MeetingInsight(
        id: 'branch',
        kind: InsightKind.prediction,
        title: 'ERP验收后续方案',
        body: '推演分支：若接口不稳定，可分期发布；另一替代方案是先关闭ERP同步再上线。',
        evidenceIds: ['a'],
      ),
    ], sources);
    expect(result, hasLength(2));
  });
  test('截图ERP验收的指代、口径、持续时长和前瞻追问合为一张完整提示', () {
    const evidence = [
      MeetingUtterance(
        id: 'erp',
        speaker: '发言人 A',
        raw: '关于验收标准，我觉得我们至少要确认一下e RP能够持续运行。',
        at: Duration(seconds: 12),
      ),
    ];
    final titles = [
      'ERP超时问题与验收标准冲突',
      '“e RP”指代不明，验收对象存疑',
      '持续运行的量化标准仍缺失',
      'ERP持续运行被提为验收前提',
      'ERP持续运行的验收口径',
      '下轮可能追问稳定指标',
      '持续运行验收口径待明确',
      'ERP持续运行标准待确认',
    ];
    final result = compactMeetingInsights([
      for (var i = 0; i < titles.length; i++)
        MeetingInsight(
          id: 'erp-$i',
          kind: i < 4
              ? InsightKind.risk
              : i == 7
              ? InsightKind.question
              : InsightKind.prediction,
          title: titles[i],
          body: i == 7 ? '请确认ERP持续运行的持续时长、测试范围与通过标准。' : 'ERP持续运行验收口径尚需确认。',
          evidenceIds: ['erp'],
        ),
    ], evidence);
    expect(result, hasLength(1));
    expect(result.single.body, contains('持续时长'));
    expect(
      result.single.kind,
      InsightKind.question,
      reason: '信息缺失不因来自风险角色而永久升级成冲突',
    );
    expect(result.single.anchorId, 'erp');
  });
  test('同一履约项缺交期和履约方只显示一张信息待补全', () {
    final result = compactMeetingInsights([
      const MeetingInsight(
        id: 'questionnaire-date',
        kind: InsightKind.question,
        title: '信息待补全',
        body: '提交评估报告：这项工作的交付日期是什么？',
        evidenceIds: ['a'],
      ),
      const MeetingInsight(
        id: 'questionnaire-side',
        kind: InsightKind.question,
        title: '信息待补全',
        body: '提交评估报告：这项工作由我方还是对方履约？',
        evidenceIds: ['a'],
      ),
    ], sources);
    expect(result, hasLength(1));
    expect(result.single.body, contains('交付日期'));
    expect(result.single.body, contains('我方还是对方'));
  });
  test('主体完成但遗留问题的同义风险合并，不把正文提到验收当成另一个问题', () {
    final result = compactMeetingInsights([
      for (final title in ['功能已完成但遗留两个问题', '主体已完成但仍留两个未决问题', '仍有两个问题待处理'])
        MeetingInsight(
          id: title,
          kind: InsightKind.risk,
          title: title,
          body: '主要功能完成，但两个问题尚未明确，是否影响上线验收仍需确认。',
          evidenceIds: ['a'],
        ),
    ], sources);
    expect(result, hasLength(1));
  });
  test('同段ERP和图片上传的验收、24与48小时、批准变化及独立数据丢失风险不混合', () {
    MeetingInsight issue(String id, String title, String body) =>
        MeetingInsight(
          id: id,
          kind: InsightKind.risk,
          title: title,
          body: body,
          evidenceIds: ['a'],
        );
    final result = compactMeetingInsights([
      issue('erp24', 'ERP持续运行验收口径', '请确认24小时稳定运行的验收标准。'),
      issue('erp48', 'ERP持续运行验收口径', '请确认48小时稳定运行的验收标准。'),
      issue('upload', '图片上传验收口径', '请确认图片上传的测试范围。'),
      issue('loss', 'ERP数据丢失风险', '验收时发生数据丢失需要处理。'),
      issue('approved', 'ERP验收已确认通过', 'ERP24小时稳定运行已经通过。'),
    ], sources);
    expect(result, hasLength(5));
  });
  test('同一原话包含两个不同动作，不因同属信息待补全而合并', () {
    final result = compactMeetingInsights([
      const MeetingInsight(
        id: 'questionnaire-one',
        kind: InsightKind.question,
        title: '信息待补全',
        body: '提交报告：交期是什么？',
        evidenceIds: ['a'],
      ),
      const MeetingInsight(
        id: 'questionnaire-two',
        kind: InsightKind.question,
        title: '信息待补全',
        body: '修复上传：履约方是谁？',
        evidenceIds: ['a'],
      ),
    ], sources);
    expect(result, hasLength(2));
  });
  test('Windows交付范围的不同表述合并，风险保留且依据合并', () {
    MeetingInsight scope(
      String id,
      String title,
      String body,
      String ref, {
      InsightKind kind = InsightKind.question,
    }) => MeetingInsight(
      id: id,
      kind: kind,
      title: title,
      body: body,
      evidenceIds: [ref],
    );
    final result = compactMeetingInsights([
      scope('one', 'Windows是否纳入交付', '客户询问Windows能不能一起做，尚未形成是否纳入的结论。', 'a'),
      scope(
        'two',
        'Windows端交付范围待确认',
        '现有Android和iOS方案，尚需确认Windows端是否纳入交付。',
        'b',
        kind: InsightKind.risk,
      ),
      scope(
        'three',
        'Windows新增交付目标尚未确认',
        '现场有Windows机器不代表批准，Windows新增交付尚未确认。',
        'a',
      ),
    ], sources);
    expect(result, hasLength(1));
    expect(result.single.evidenceIds, containsAll(['a', 'b']));
    expect(result.single.anchorId, 'a');
    expect(result.single.kind, InsightKind.risk);
  });
  test('同为Windows也不合并批准变化、交期风险、金额或其他平台', () {
    final result = compactMeetingInsights([
      const MeetingInsight(
        id: 'pending',
        kind: InsightKind.question,
        title: 'Windows是否纳入交付',
        body: '范围待确认。',
        evidenceIds: ['a'],
      ),
      const MeetingInsight(
        id: 'approved',
        kind: InsightKind.question,
        title: 'Windows已批准纳入交付',
        body: '需要同步范围。',
        evidenceIds: ['a'],
      ),
      const MeetingInsight(
        id: 'date',
        kind: InsightKind.risk,
        title: 'Windows是否纳入交付',
        body: '新增范围可能影响周三交期。',
        evidenceIds: ['a'],
      ),
      const MeetingInsight(
        id: 'web',
        kind: InsightKind.question,
        title: 'Web是否纳入交付',
        body: '范围待确认。',
        evidenceIds: ['a'],
      ),
      hint('inline', '建议确认Windows是否纳入交付。', ['a']),
    ], sources);
    expect(result, hasLength(5));
    expect(result.where(isInlineMeetingSuggestion), hasLength(4));
  });
  test('跨批次相同建议合并并保留来源与最初锚点', () {
    final merged = compactMeetingInsights([
      hint('first', '建议确认Windows交付范围。', ['a'], anchor: 'a'),
      hint('second', '建议确认Windows交付范围。', ['b']),
    ], sources);
    expect(merged, hasLength(1));
    expect(merged.single.evidenceIds, ['a', 'b']);
    expect(merged.single.anchorId, 'a');
  });
  test('新的日期或不同风险不能因同类型合并丢失', () {
    final merged = compactMeetingInsights([
      hint('a', '建议确认周三交付。', ['a']),
      hint('b', '建议确认周五交付。', ['a']),
      hint('c', '建议确认预算20万元。', ['a']),
    ], sources);
    expect(merged, hasLength(3));
  });
  test('同一正文流就地更新，新增证据不跟随下一位发言人', () {
    final merged = compactMeetingInsights([
      hint('stream', '建议', ['a'], anchor: 'a', streaming: true),
      hint('stream', '建议确认交期。', ['a', 'b'], streaming: true),
    ], sources);
    expect(merged, hasLength(1));
    expect(merged.single.anchorId, 'a');
    expect(merged.single.body, '建议确认交期。');
    expect(merged.single.streaming, isTrue);
  });
  test('拒绝不存在的引用，锚点必须属于真实证据', () {
    final merged = compactMeetingInsights([
      hint('bad', '建议确认。', ['missing']),
      hint('valid', '建议确认交期。', ['a'], anchor: 'b'),
    ], sources);
    expect(merged, hasLength(1));
    expect(merged.single.anchorId, 'a');
  });
  test('中文金额与相反的批准状态不能合并', () {
    final merged = compactMeetingInsights([
      hint('budget-one', '请确认预算二十万元是否充足。', ['a']),
      hint('budget-two', '请确认预算三十万元是否充足。', ['a']),
      hint('scope-no', 'Windows未批准，请确认交付范围。', ['a']),
      hint('scope-yes', 'Windows已批准，请确认交付范围。', ['a']),
    ], sources);
    expect(merged, hasLength(4));
  });
}
