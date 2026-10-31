import '../meeting_models.dart';

String _plain(String text) =>
    text.replaceAll(RegExp(r'\s+|[*#`\[\]]'), '').toLowerCase();

Set<String> _terms(String text) {
  const noise = {'完成', '目标', '承诺', '进行', '确认', '项目', '要求', '相关', '当前', '已经'};
  final words = <String>{};
  for (final m in RegExp(
    r'[a-z0-9]{3,}|[\u4e00-\u9fff]+',
  ).allMatches(text.toLowerCase())) {
    final word = m[0]!;
    if (RegExp(r'^[a-z0-9]+$').hasMatch(word)) {
      words.add(word);
    } else {
      for (var i = 0; i + 1 < word.length; i++) {
        final pair = word.substring(i, i + 2);
        if (!noise.contains(pair)) words.add(pair);
      }
    }
  }
  return words;
}

/// Resolve only existing, non-withdrawn original speech. Retrieval metadata is
/// a navigation hint, never proof that a goal or commitment was approved.
List<String> meetingReferenceSources(
  MeetingRecord record, {
  required String quote,
  required String query,
}) {
  final sources = {
    for (final u in record.utterances.where((u) => !u.withdrawn)) u.id: u,
  };
  final explicit = <String>{};
  var hasSourceMarkers = false;
  for (final m in RegExp(
    r'〔来源：([^〕]+)〕|^### (\S+) ·',
    multiLine: true,
  ).allMatches(quote)) {
    hasSourceMarkers = true;
    explicit.addAll(
      (m[1] ?? m[2]!)
          .split(RegExp(r'[,，、]'))
          .map((s) => s.trim())
          .where(sources.containsKey),
    );
  }
  if (hasSourceMarkers && explicit.isEmpty) return const [];
  final text = _plain(quote);
  final exact = sources.values
      .where((u) {
        final raw = _plain(u.raw);
        return raw.length >= 6 &&
            text.length >= 6 &&
            (text.contains(raw) || raw.contains(text));
      })
      .map((u) => u.id)
      .toSet();
  final candidates = explicit.isNotEmpty
      ? explicit
      : exact.isNotEmpty
      ? exact
      : sources.keys.toSet();
  if (candidates.length == 1 && (explicit.isNotEmpty || exact.isNotEmpty)) {
    return candidates.toList();
  }
  final terms = _terms(query);
  final ranked = [
    for (final id in candidates)
      (id, terms.intersection(_terms(sources[id]!.raw)).length),
  ]..sort((a, b) => b.$2.compareTo(a.$2));
  final result = ranked
      .where((r) => r.$2 >= 2)
      .take(3)
      .map((r) => r.$1)
      .toList();
  return result;
}
