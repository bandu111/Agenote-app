import 'package:flutter_test/flutter_test.dart';
import 'package:yanshu/features/meeting/meeting_value_gate.dart';

void main() {
  test('约束、行动、接回与明确变更是分析候选，分析不等于批准', () {
    for (final words in [
      '我们还不能承诺下周上线，ERP接口仍然超时。',
      '我方负责修复上传失败问题，周三提交测试版本。',
      '接着刚才没说完的验收标准，核心流程全部通过。',
      '我们确定周三下午两点到两点半开上线评估会。',
      '请不要取消原任务，目前只是考虑修改交期。',
      '本次合同预算确定为二十万元，范围保持原样。',
      '乙方负责处理同步延迟，周一下午提交测试版本，但接口今天无法确认，可能影响交付。',
      '丁负责完整测试，周三上午提交测试报告。',
      '周一下午提交测试版本，周三上午提交评估报告。',
    ]) {
      expect(
        meetingValue(words, fragments: 1),
        isNot(MeetingValue.none),
        reason: words,
      );
    }
  });
  test('寒暄、议程、半句和条件前半句不被当作完整信息', () {
    for (final words in [
      '好，人应该都到齐了吧？那我们开始。',
      '今天主要讨论三个事情，具体时间等一下再说。',
      '第二个是还没有解决的问题，第三个就是下周到底能不能正式上线。',
      '验收标准我们就按',
      '如果我们决定在下周三完成全部接口测试。',
      '我',
    ]) {
      expect(
        meetingValue(words, fragments: 1),
        MeetingValue.none,
        reason: words,
      );
    }
  });
  test('非关键词的长上下文有有界兜底，不要求说话人停止', () {
    final text = List.filled(18, '门店每天都会反馈系统使用情况。').join();
    expect(meetingValue(text, fragments: 4), MeetingValue.context);
  });
}
