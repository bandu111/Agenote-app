import 'meeting_models.dart';
import 'meeting_issue_grouping.dart';

/// 实时补充维持原有上下文入口；独立风险、推演和拼图卡片不被收进去。
bool isInlineMeetingSuggestion(MeetingInsight item) =>
    (item.title == 'AI 补充' ||
        (item.kind == InsightKind.question && item.attention != 'urgent')) &&
    item.kind != InsightKind.risk &&
    item.kind != InsightKind.stitch;

String? _pendingScopeTopic(MeetingInsight item) {
  final text = '${item.title} ${item.body}'.toLowerCase();
  if (!RegExp(r'范围|纳入|交付|批准').hasMatch(text) ||
      !RegExp(r'未批准|尚未|待确认|是否|能否|能不能|需要确认|尚需确认|询问|未形成|未决定').hasMatch(text)) {
    return null;
  }
  // 新的费用、时间、验收或技术风险不是同一待确认问题，不能顺手折叠。
  if (RegExp(
    r'验收|预算|金额|价格|交期|工期|截止|日期|数据丢失|隐私|兼容|接口|已批准|已确认纳入|正式批准|明确不纳入',
  ).hasMatch(text)) {
    return null;
  }
  final platforms = [
    'windows',
    'android',
    'ios',
    'web',
    'macos',
    'linux',
    '鸿蒙',
    '小程序',
  ];
  final title = item.title.toLowerCase();
  final subjects = platforms.where(title.contains).toList();
  final target = subjects.length == 1 ? subjects.single : null;
  if (target == null) return null;
  final numbers = RegExp(
    r'\d+(?:[./:%]\d+)*|[零〇一二两三四五六七八九十百千万]+(?:万元|元|天|日|月|小时)|[本下这]?(?:周|星期)[一二三四五六日天]',
  ).allMatches(text).map((m) => m.group(0)!).toSet().toList()..sort();
  return '$target:pending:${numbers.join('|')}';
}

/// 只合并展示建议，不据此批准、撤回或修改任何业务事实。
String _plain(String value) =>
    value.toLowerCase().replaceAll(RegExp(r'[\s，。！？、：；,.!?:;“”「」·…—-]'), '');

String _family(MeetingInsight item) {
  final text = '${item.title} ${item.body}'.toLowerCase();
  if (item.kind == InsightKind.stitch) return 'memory';
  if (RegExp(r'批准|授权|范围|纳入|新增平台|需求边界').hasMatch(text)) return 'scope';
  if (RegExp(r'交期|工期|延期|截止|日期|时间|周[一二三四五六日天]').hasMatch(text)) {
    return 'deadline';
  }
  if (RegExp(r'验收|通过率|测试标准').hasMatch(text)) return 'acceptance';
  if (RegExp(r'预算|金额|价格|降价|费用').hasMatch(text)) return 'budget';
  if (RegExp(r'履约方|责任|负责|谁来').hasMatch(text)) return 'responsibility';
  return item.kind.name;
}

Set<String> _grams(String text) {
  final value = _plain(text);
  return {for (var i = 0; i + 1 < value.length; i++) value.substring(i, i + 2)};
}

String _facts(MeetingInsight item) {
  final text = '${item.title} ${item.body}'.toLowerCase();
  final facts = RegExp(
    r'\d+(?:[./:%]\d+)*(?:万元|元|天|日|月|小时|%)?|[零〇一二两三四五六七八九十百千万]+(?:万元|元|天|日|月|小时)|[本下这]?(?:周|星期)[一二三四五六日天]|windows|android|ios|web|macos|linux|鸿蒙|小程序|已批准|已确认|尚未批准|未批准|未确认|不同意|同意|不纳入|纳入|不需要|无需|撤回|取消',
  ).allMatches(text).map((m) => m.group(0)!).toSet().toList()..sort();
  return facts.join('|');
}

bool _similar(MeetingInsight a, MeetingInsight b) {
  if ((a.title == 'AI 补充') != (b.title == 'AI 补充')) {
    return false;
  }
  if (a.kind != InsightKind.stitch && b.kind != InsightKind.stitch) {
    final topic = _pendingScopeTopic(a);
    if (topic != null && topic == _pendingScopeTopic(b)) return true;
  }
  if (_family(a) != _family(b) || _facts(a) != _facts(b)) return false;
  final x = _grams(a.body), y = _grams(b.body);
  if (x.isEmpty || y.isEmpty) return false;
  final overlap = x.intersection(y).length / x.union(y).length;
  final sameSource = a.evidenceIds.any(b.evidenceIds.contains);
  return _plain(a.body) == _plain(b.body) ||
      overlap >= (sameSource ? .38 : .65);
}

List<MeetingInsight> compactMeetingInsights(
  Iterable<MeetingInsight> input,
  List<MeetingUtterance> utterances,
) {
  final ids = utterances.map((u) => u.id).toSet();
  final merged = <MeetingInsight>[];
  final issues = MeetingIssuePolicy(utterances);
  for (final raw in input) {
    if (raw.attention == 'defer') continue;
    if (raw.evidenceIds.isEmpty || !raw.evidenceIds.every(ids.contains)) {
      continue;
    }
    final anchor =
        raw.anchorId != null && raw.evidenceIds.contains(raw.anchorId)
        ? raw.anchorId
        : utterances
              .where((u) => raw.evidenceIds.contains(u.id))
              .lastOrNull
              ?.id;
    if (anchor == null || !ids.contains(anchor)) continue;
    final item = MeetingInsight.fromJson({...raw.toJson(), 'anchorId': anchor});
    final sameId = merged.indexWhere((old) => old.id == item.id);
    final index = sameId >= 0
        ? sameId
        : merged.indexWhere(
            (old) =>
                !issues.mustStaySeparate(old, item) &&
                ((old.topicKey.isNotEmpty &&
                        old.issueKey.isNotEmpty &&
                        item.topicKey.isNotEmpty &&
                        item.issueKey.isNotEmpty)
                    ? issues.sameGeneric(old, item)
                    : (_similar(old, item) ||
                          issues.sameGeneric(old, item) ||
                          ((old.title == 'AI 补充') == (item.title == 'AI 补充') &&
                              issues.same(old, item)))),
          );
    if (index < 0) {
      merged.add(item);
      continue;
    }
    final old = merged[index];
    final thematic =
        sameId < 0 && (issues.same(old, item) || issues.sameGeneric(old, item));
    final preferred = thematic ? issues.prefer(old, item) : item;
    // 同一流更新保留原锚点；跨发言合并也保留每个引用，不能把无关新发言设为来源。
    final references = {...old.evidenceIds, ...item.evidenceIds}.toList();
    merged[index] = MeetingInsight.fromJson({
      ...preferred.toJson(),
      'id': old.id,
      'anchorId': old.anchorId,
      'evidenceIds': references,
      'kind': thematic
          ? preferred.kind.name
          : old.kind == InsightKind.risk
          ? old.kind.name
          : item.kind.name,
      'knowledgeCitations': {
        for (final c in [...old.knowledgeCitations, ...item.knowledgeCitations])
          '${c['nodeId']}:${c['hash']}': c,
      }.values.toList(),
    });
  }
  return merged;
}

/// 每段优先展示两个不同问题；其余合并后的依据仍保存在记录中供上下文查看。
List<MeetingInsight> suggestionsForSource(
  Iterable<MeetingInsight> input,
  String source,
) {
  final items = input.where((i) => i.anchorId == source).toList();
  items.sort(
    (a, b) => (a.kind == InsightKind.risk ? 0 : 1).compareTo(
      b.kind == InsightKind.risk ? 0 : 1,
    ),
  );
  return items;
}

/// 每个显示段落仅保留两个重要提醒，其余保留在该段 AI 补充中，不删除证据。
/// 拼图是原话关联，不占警告配额，继续保留来源时间戳。
class MeetingHintLayout {
  MeetingHintLayout(
    List<MeetingInsight> insights,
    List<List<MeetingUtterance>> groups,
  ) {
    for (final group in groups) {
      final ids = group.map((u) => u.id).toSet();
      final candidates = insights
          .where(
            (i) => ids.contains(i.anchorId) && !isInlineMeetingSuggestion(i),
          )
          .toList();
      standalone.addAll(
        candidates.where((i) => i.kind == InsightKind.stitch).map((i) => i.id),
      );
      final warnings =
          candidates.where((i) => i.kind != InsightKind.stitch).toList()
            ..sort((a, b) => _value(b).compareTo(_value(a)));
      standalone.addAll(warnings.take(2).map((i) => i.id));
    }
  }
  final Set<String> standalone = {};
  bool isInline(MeetingInsight item) => !standalone.contains(item.id);
  List<MeetingInsight> inlineSuggestions(List<MeetingInsight> items) =>
      items.where(isInline).toList()..sort(
        (a, b) => (_value(b) + (b.kind == InsightKind.question ? 45 : 0))
            .compareTo(_value(a) + (a.kind == InsightKind.question ? 45 : 0)),
      );
  static int _value(MeetingInsight i) =>
      (i.attention == 'urgent' ? 100 : 0) +
      (i.kind == InsightKind.risk ? 40 : 0) +
      (i.impact.isNotEmpty ? 15 : 0) +
      i.evidenceIds.length.clamp(0, 5);
}
