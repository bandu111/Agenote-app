import 'speech_turn.dart';

enum MeetingValue { none, context, important, change }

/// 仅调度已稳定的完整信息片段；事实、承诺、授权仍由现有 Agent 和 Service 校验。
MeetingValue meetingValue(String text, {required int fragments}) {
  final value = text.trim();
  if (value.runes.length < 12 || isUnfinishedSpeech(value)) {
    return MeetingValue.none;
  }
  // 条件的前半句不能仅因 ASR 定稿就进入完整分析。
  if (RegExp(r'^(如果|假如|假设)').hasMatch(value) &&
      !RegExp(r'那么|就|则|否则').hasMatch(value)) {
    return MeetingValue.none;
  }
  if (RegExp(r'取消|撤回|改期|改为|改成|调整为|调整到|延后|不再执行').hasMatch(value)) {
    return MeetingValue.change;
  }
  if (RegExp(
        r'尚未批准|未批准|不能承诺|尚未解决|未解决|未关闭|不自动执行|必须|超时|上传失败|不能上线|不代表批准|不等于批准|高优先级|验收标准.{0,30}(?:通过|明确|确认|运行)|(?:确认|明确).{0,30}验收标准|(?:交期|预算|报价|金额|范围).{0,16}(?:为|是|改|定|确认|不变|不含|万元|天|周)',
      ).hasMatch(value) ||
      RegExp(
        r'负责(?!人).{2,}|承担.{2,}|承诺.{2,}|无法(?:确认|完成|交付)|确认不了|不能如期|推迟|延迟|延期|阻塞|不可用',
      ).hasMatch(value) ||
      RegExp(
        r'(?:(?:周|星期)[一二三四五六日天]|明天|后天|今天|下周|月底|\d{1,2}[月日号点]).{0,24}(?:提交|提供|交付|付款|开会|评审|完成|测试)',
      ).hasMatch(value) ||
      RegExp(
        r'(?:我方|对方|我们|我).{0,8}(?:负责|承诺|会提交|会提供)|请(?:创建|安排)|接着刚才|回到刚才|接回|刚才没说完',
      ).hasMatch(value) ||
      (RegExp(r'确认|确定|定于|就定').hasMatch(value) &&
          RegExp(r'开会|会议|日历|评审会|评估会|进度会').hasMatch(value))) {
    return MeetingValue.important;
  }
  // 普通议程、寒暄不会逐句调模型；较长的新上下文仍保留一次兜底理解机会。
  if (value.runes.length >= 180 &&
      fragments >= 3 &&
      !RegExp(r'主要讨论|三个事情|人应该都到齐|会议尽量控制').hasMatch(value)) {
    return MeetingValue.context;
  }
  return MeetingValue.none;
}
