import '../meeting_models.dart';

String minutesPlain(String text) => text
    .replaceAll(RegExp(r'〔来源：[^〕]*〕'), '')
    .replaceAllMapped(RegExp(r'\[\[([^\]]+)\]\]'), (m) => m[1]!)
    .replaceAll(RegExp(r'[*#`]'), '')
    .trim();

Duration minutesUtteranceStart(MeetingUtterance u) => u.hasAudio
    ? Duration(
        microseconds: (u.at - (u.audioEnd! - u.audioStart!)).inMicroseconds
            .clamp(0, 1 << 60),
      )
    : u.at;

class MinutesEntry {
  const MinutesEntry({
    required this.id,
    required this.text,
    required this.evidenceIds,
    this.title = '',
    this.points = const [],
    this.status = 'pending',
    this.completed = false,
    this.owner,
    this.deadline,
    this.deadlineAt,
    this.deadlineHasTime = true,
    this.taskId,
    this.taskVersion,
  });
  final String id, text, title, status;
  final List<String> evidenceIds, points;
  final bool completed;
  final String? owner, deadline, deadlineAt, taskId;
  final bool deadlineHasTime;
  String? get deadlineLabel {
    final at = DateTime.tryParse(deadlineAt ?? '');
    if (at == null) return deadline;
    final date = at.toLocal();
    final time =
        '${date.hour.toString().padLeft(2, "0")}:${date.minute.toString().padLeft(2, "0")}';
    return '${date.month}月${date.day}日${deadlineHasTime ? " $time" : ""}';
  }

  final int? taskVersion;

  factory MinutesEntry.fromJson(Map<String, dynamic> j) => MinutesEntry(
    id: j['id'] as String? ?? '',
    text: minutesPlain(j['text'] as String? ?? ''),
    title: minutesPlain(j['title'] as String? ?? ''),
    evidenceIds: List<String>.from(j['evidence_ids'] as List? ?? []),
    points: [for (final p in j['points'] as List? ?? []) minutesPlain('$p')],
    status: j['status'] as String? ?? 'pending',
    completed: j['completed'] == true,
    owner: j['owner'] as String?,
    deadline: j['deadline'] as String?,
    deadlineAt: j['deadlineAt'] as String?,
    deadlineHasTime: j['deadlineHasTime'] != false,
    taskId: j['taskId'] as String?,
    taskVersion: j['taskVersion'] as int?,
  );
}

class MeetingMinutesData {
  const MeetingMinutesData({
    this.summary = '',
    this.topics = const [],
    this.decisions = const [],
    this.actions = const [],
    this.questions = const [],
  });
  final String summary;
  final List<MinutesEntry> topics, decisions, actions, questions;

  factory MeetingMinutesData.fromRecord(
    MeetingRecord record, {
    Map<String, dynamic>? details,
  }) {
    final data = details ?? record.minutesDetails;
    final sources = {
      for (final u in record.utterances.where((u) => !u.withdrawn)) u.id: u,
    };
    List<MinutesEntry> entries(String kind) =>
        [
              for (final j in data?[kind] as List? ?? [])
                if (j is Map)
                  MinutesEntry.fromJson(Map<String, dynamic>.from(j)),
            ]
            .where(
              (i) =>
                  i.text.isNotEmpty &&
                  i.evidenceIds.isNotEmpty &&
                  i.evidenceIds.every(sources.containsKey),
            )
            .toList();
    if (data != null) {
      return MeetingMinutesData(
        summary: minutesPlain(data['summary'] as String? ?? ''),
        topics: entries('topics'),
        decisions: entries('decisions'),
        actions: entries('actions'),
        questions: entries('open_questions'),
      );
    }
    // Older archives already have stable source IDs; never infer agreement from raw speech.
    final grouped = <String, List<MinutesEntry>>{
      'decisions': [],
      'actions': [],
      'questions': [],
    };
    String? section;
    for (final line in (record.cloudMinutes ?? '').split('\n')) {
      if (line.startsWith('## ')) {
        section = {
          '当前共识': 'decisions',
          '后续行动（未自动执行）': 'actions',
          '待确认': 'questions',
        }[line.substring(3).trim()];
      }
      final match = RegExp(r'^- (.+)〔来源：(.+)〕$').firstMatch(line);
      if (section == null || match == null) continue;
      final ids = match[2]!.split(',').map((s) => s.trim()).toList();
      if (!ids.every(sources.containsKey)) continue;
      grouped[section]!.add(
        MinutesEntry(
          id: '$section-${grouped[section]!.length}',
          text: minutesPlain(match[1]!),
          evidenceIds: ids,
          status: section == 'decisions' ? 'confirmed' : 'pending',
        ),
      );
    }
    return MeetingMinutesData(
      summary: grouped['decisions']!.take(3).map((i) => i.text).join('；'),
      decisions: grouped['decisions']!,
      actions: grouped['actions']!,
      questions: grouped['questions']!,
    );
  }

  /// 纪要中的决议和后续行动已关联原话；用完整纪要补回实时轻量标注的漏项。
  /// 只读展示依据，不将普通议题、术语命中或用户选中状态当成重点。
  Set<String> get importantSourceIds => {
    for (final entry in [...decisions, ...actions])
      if (entry.text.isNotEmpty) ...entry.evidenceIds,
  };

  MeetingUtterance? source(MeetingRecord record, MinutesEntry entry) => record
      .utterances
      .where((u) => entry.evidenceIds.contains(u.id))
      .firstOrNull;
}
