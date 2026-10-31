import 'package:flutter_test/flutter_test.dart';
import 'package:yanshu/features/meeting/meeting_models.dart';
import 'package:yanshu/features/meeting/minutes/meeting_reference_focus.dart';

MeetingRecord sample() => MeetingRecord(
  id: 'm',
  startedAt: DateTime(2026),
  demo: false,
  utterances: const [
    MeetingUtterance(
      id: 'erp',
      speaker: 'A',
      raw: '我们先完成ERP接口兼容性验证。',
      at: Duration(seconds: 3),
    ),
    MeetingUtterance(
      id: 'report',
      speaker: 'B',
      raw: '我负责提交验收测试报告。',
      at: Duration(seconds: 8),
    ),
    MeetingUtterance(
      id: 'removed',
      speaker: 'C',
      raw: '这个报价取消了。',
      at: Duration(seconds: 10),
      withdrawn: true,
    ),
  ],
);

void main() {
  test('goal and commitment preserve different exact source references', () {
    final r = sample();
    expect(meetingReferenceSources(r, quote: '先验证接口〔来源：erp〕', query: '目标兼容性'), [
      'erp',
    ]);
    expect(meetingReferenceSources(r, quote: '我负责提交验收测试报告。', query: '提交报告'), [
      'report',
    ]);
    expect(
      meetingReferenceSources(
        r,
        quote: '## 原始转写\n### report · B · 8000ms\n我负责提交验收测试报告。',
        query: '',
      ),
      ['report'],
    );
  });
  test(
    'unavailable and weak matches do not point at an unrelated utterance',
    () {
      final r = sample();
      expect(
        meetingReferenceSources(r, quote: '报价取消〔来源：removed〕', query: '报价取消'),
        isEmpty,
      );
      expect(
        meetingReferenceSources(r, quote: '未知〔来源：missing〕', query: '办公室采购'),
        isEmpty,
      );
      expect(
        meetingReferenceSources(
          r,
          quote: '未知〔来源：missing〕',
          query: 'ERP接口兼容性验证',
        ),
        isEmpty,
      );
      expect(meetingReferenceSources(r, quote: '', query: 'ERP接口兼容性验证'), [
        'erp',
      ]);
    },
  );
}
