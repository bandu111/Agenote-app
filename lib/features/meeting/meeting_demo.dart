import 'meeting_models.dart';

const meetingDemoTurns = [
  ('客户 Alex', 'Windows 端能不能也一起做？', ''),
  ('项目负责人', '嗯，这个我们先评估一下。', ''),
  ('客户 Alex', '最好还是保持原来的 30 天。', ''),
  ('项目负责人', '一期先按 Android、iOS 交付。', ''),
  ('客户 Alex', '调整一下，一期只做 Android，iOS 延后。桌面端放到第二期再说。', ''),
  ('项目负责人', '我们明天开会再确认时间和验收标准。', ''),
  ('项目负责人', '验收就按……，具体指标还要双方确认。', '双方确认的功能清单和测试通过率'),
  ('客户 Alex', '先说预算，验收的事情等会儿再聊。', ''),
  ('客户 Alex', '接着刚才的验收，我希望通过率至少达到 95%。', ''),
  ('研发负责人', '测试环境要等……，我们才能开始联调。', '客户提供账号、白名单和接口地址'),
  ('客户 Alex', '账号可以先给，白名单需要我们运维同事处理。', ''),
  ('研发负责人', '对，就是刚才那几项，接口地址也要一起给。', ''),
  ('项目负责人', '如果桌面端也要放进来，那……，先别按原排期承诺。', '需要重新评估工作量、预算和交付时间'),
  ('客户 Alex', '可以，新增的部分先评估，评估完成后我们再决定。', ''),
  ('研发负责人', '刚才被打断了，我说的是……，不是已经同意上线。', '先完成技术可行性验证'),
  ('项目负责人', '我们先确认负责人，再把评估结果同步给双方。', ''),
];

MeetingUtterance meetingDemoUtterance(
  int index,
  Duration at, {
  int? availableThrough,
}) {
  final (speaker, raw, suggestion) = meetingDemoTurns[index];
  final gap = raw.indexOf('……');
  return MeetingUtterance(
    id: 'demo-${index + 1}',
    speaker: speaker,
    raw: raw,
    cleaned: tidySpeech(raw),
    at: at,
    withdrawn: index == 3,
    repair: suggestion.isEmpty
        ? null
        : SpeechRepair(
            start: gap,
            end: gap + 2,
            text: suggestion,
            evidenceIds:
                (switch (index) {
                      6 => ['demo-7', 'demo-9'],
                      9 => ['demo-10', 'demo-11', 'demo-12'],
                      12 => ['demo-13', 'demo-14'],
                      _ => ['demo-15', 'demo-16'],
                    })
                    .where(
                      (id) =>
                          int.parse(id.substring(5)) <=
                          (availableThrough ?? index + 1),
                    )
                    .toList(),
          ),
  );
}
