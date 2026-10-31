import 'meeting_models.dart';

/// 清除上轮误加的独立等待卡；记忆碎片仍由原句中的 repair 显示。
MeetingRecord projectMemoryWorkflow(MeetingRecord record) {
  final insights = record.insights
      .where((i) => i.issueKey != 'memory-workflow-v1')
      .toList();
  if (insights.length == record.insights.length) return record;
  return record.copy(insights: insights);
}
