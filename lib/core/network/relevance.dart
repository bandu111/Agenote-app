/// 词面相关度：查询词覆盖率与 Dice 的组合，不是事实正确率或模型置信度。
const relevanceMethod = 'lexical_relevance_v1';
Set<String> relevanceTerms(String text) {
  final clipped = text.toLowerCase();
  final values = <String>{};
  for (final match in RegExp(
    r'[a-z0-9_+#]+|[\u4e00-\u9fff]+',
  ).allMatches(clipped.substring(0, clipped.length.clamp(0, 12000)))) {
    final part = match[0]!;
    if (RegExp(r'^[\u4e00-\u9fff]+$').hasMatch(part)) {
      if (part.length == 1) values.add(part);
      for (var i = 0; i < part.length - 1; i++) {
        values.add(part.substring(i, i + 2));
      }
    } else {
      values.add(part);
    }
  }
  return values;
}

int? textRelevancePercent(String query, String target) {
  final a = relevanceTerms(query), b = relevanceTerms(target);
  if (a.isEmpty || b.isEmpty) return null;
  final shared = a.intersection(b).length;
  if (shared == 0) return 0;
  return (100 *
          (.7 * shared / a.length + .3 * 2 * shared / (a.length + b.length)))
      .round()
      .clamp(0, 100);
}
