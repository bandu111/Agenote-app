import '../../knowledge/models/knowledge_models.dart';
import '../models/progress_models.dart';

final _bodyTerms = Expando<Set<String>>('goal-document-terms');

/// Local lexical matching; scope and validity are checked before reading text.
List<KnowledgeDocument> matchGoalDocuments(
  ProgressGoal goal,
  KnowledgeSnapshot library,
) {
  if (goal.projectId == null ||
      !library.projects.any((p) => p.id == goal.projectId)) {
    return [];
  }
  final query = _terms(
    [
      goal.title,
      goal.condition,
      goal.acceptance,
      ...goal.milestones.map((m) => m.title),
    ].join(' '),
  );
  final scored = <(KnowledgeDocument, int)>[];
  for (final doc in library.documents) {
    if (doc.projectId != goal.projectId ||
        doc.versions.any((v) => v.state == KnowledgeValidity.conflicted)) {
      continue;
    }
    final version = doc.effective;
    if (version == null || !version.usableAt(DateTime.now())) continue;
    final metadata = _terms(
      [version.title, doc.filename ?? '', ...doc.tags].join(' '),
    );
    final body = _bodyTerms[version] ??= _terms(version.content);
    final score =
        query.intersection(metadata).length * 3 +
        query.intersection(body).length;
    if (score < 2) continue;
    scored.add((doc.copyWith(selectedVersionId: version.id), score));
  }
  scored.sort((a, b) {
    final rank = b.$2.compareTo(a.$2);
    return rank != 0 ? rank : a.$1.id.compareTo(b.$1.id);
  });
  return scored.map((row) => row.$1).toList(growable: false);
}

Set<String> _terms(String value) {
  final result = <String>{};
  const noise = {
    '完成',
    '双方',
    '已经',
    '进行',
    '当前',
    '项目',
    '要求',
    '确认',
    'and',
    'the',
    'with',
    'from',
    'this',
  };
  for (final match in RegExp(
    r'[a-z0-9]+|[\u4e00-\u9fff]+',
  ).allMatches(value.toLowerCase())) {
    final part = match.group(0)!;
    if (RegExp(r'^[a-z0-9]+$').hasMatch(part)) {
      if (part.length >= 3 && !noise.contains(part)) result.add(part);
    } else {
      for (var i = 0; i + 1 < part.length; i++) {
        final pair = part.substring(i, i + 2);
        if (!noise.contains(pair)) result.add(pair);
      }
    }
  }
  return result;
}
