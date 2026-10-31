import 'package:yanshu/features/meeting/meeting_models.dart';

MeetingRecord minutesFixture() {
  const texts = [
    '好，我们开始吧。今天主要过一下新版本的开发进度、接口兼容性，还有测试和发布时间的安排。',
    '后台这边的核心模块已经完成了，剩下的是和客户端联调，主要在旧版本接口上还有些出入。',
    '前端这边改动不大，主要是状态同步那块的字段命名需要跟后端再对一下。',
    '目前部分接口还需要完成跨平台兼容性验证，建议优先处理这些问题，其他的可以往后排。',
    '我们需要先把接口验证完成，再安排后续测试，不然回归测试跑两遍成本太高。',
    '下月上旬可能是一个发布时间，但还要看接口测试的结果，这里先不对外说定。',
    '测试这边可以先准备回归用例，核心业务流程先跑通，剩下的按优先级补。',
    '跨平台验证的结果我这边汇总一下，出来后同步到群里。',
    '那就是先保持接口兼容性，发布时间等验证结果出来再定。',
    '好的，那这次先到这里。',
  ];
  const seconds = [9, 202, 521, 755, 1116, 1458, 1880, 2282, 2595, 2822];
  const speakers = ['A', 'B', 'C', 'A', 'B', 'A', 'B', 'C', 'A', 'B'];
  Map<String, dynamic> item(
    String id,
    String text,
    List<String> ids, {
    String? title,
    List<String>? points,
    String? status,
  }) => {
    'id': id,
    'text': text,
    'evidence_ids': ids,
    'title': ?title,
    'points': ?points,
    'status': ?status,
  };
  return MeetingRecord(
    id: 'minutes-test',
    startedAt: DateTime(2026, 10, 27),
    demo: false,
    title: '产品研发讨论会',
    ended: true,
    elapsed: const Duration(minutes: 48),
    utterances: [
      for (var i = 0; i < texts.length; i++)
        MeetingUtterance(
          id: 'u$i',
          speaker: '发言人 ${speakers[i]}',
          raw: texts[i],
          at: Duration(seconds: seconds[i]),
        ),
    ],
    minutesDetails: {
      'summary':
          '本次会议主要讨论了新版本的开发进度、接口兼容性及测试安排。团队倾向于优先完成核心接口验证，随后开展回归测试。最终发布时间尚未正式确定，需要等跨平台验证结果出来后再评估。',
      'topics': [
        item(
          't1',
          '部分接口尚未完成跨平台验证，旧版本接口在字段命名与返回结构上仍有出入。团队建议优先解决兼容性问题，其余工作向后顺延。',
          ['u3'],
          title: '接口兼容性',
          points: ['跨平台验证', '优先级问题'],
        ),
        item(
          't2',
          '回归测试用例可以先并行准备，核心业务流程优先跑通，其余场景按优先级补齐，避免接口改动后重复执行。',
          ['u6'],
          title: '测试安排',
          points: ['准备回归测试', '核心业务流程'],
        ),
        item(
          't3',
          '会议讨论了下月上旬发布的可能性，但尚未形成正式决定。时间窗口是否需要对外公布，仍取决于接口验证结果。',
          ['u5'],
          title: '版本发布时间',
          points: ['下月上旬预选方案', '最终日期待确认'],
        ),
      ],
      'decisions': [
        item('d1', '优先推进接口兼容性验证，其他需求往后排。', ['u3'], status: 'confirmed'),
        item('d2', '回归测试与接口验证并行准备，不等待全部接口完成。', ['u6'], status: 'confirmed'),
        item('d3', '将下月上旬作为候选发布窗口，验证完成后评估。', ['u5'], status: 'discussed'),
        item('d4', '最终发布时间尚未确定。', ['u8'], status: 'pending'),
      ],
      'actions': [
        item('a1', '完成接口兼容性验证', ['u4']),
        {
          ...item('a2', '准备回归测试用例并跑通核心业务流程', ['u6']),
          'completed': true,
        },
        item('a3', '汇总跨平台验证结果并同步到团队', ['u7']),
      ],
      'open_questions': [
        item('q1', '版本发布时间是否取决于接口验证结果？', ['u5']),
        item('q2', '旧版本接口是否需要保留长期兼容？', ['u1']),
      ],
    },
  );
}
