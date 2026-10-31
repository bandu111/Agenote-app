enum MeetingPhase { ready, recording, paused, ended }

enum InsightKind { question, risk, prediction, stitch }

/// Display-only speculation anchored to a gap in the immutable original.
class SpeechRepair {
  const SpeechRepair({
    required this.start,
    required this.end,
    required this.text,
    this.evidenceIds = const [],
    this.streaming = false,
    this.interrupted = false,
    this.inferred = false,
  });
  final int start, end;
  final String text;
  final List<String> evidenceIds;
  final bool streaming, interrupted;

  /// 无后续原话时的语义续写，只供淡色展示，不作为原话证据。
  final bool inferred;
  bool validFor(String raw) => start >= 0 && end >= start && end <= raw.length;
  Map<String, dynamic> toJson() => {
    'start': start,
    'end': end,
    'text': text,
    'evidenceIds': evidenceIds,
    'streaming': streaming,
    'interrupted': interrupted,
    'inferred': inferred,
  };
  factory SpeechRepair.fromJson(Map<String, dynamic> j) => SpeechRepair(
    start: j['start'],
    end: j['end'],
    text: j['text'],
    evidenceIds: List<String>.from(j['evidenceIds'] ?? []),
    streaming: j['streaming'] == true,
    interrupted: j['interrupted'] == true,
    inferred: j['inferred'] == true,
  );
}

class MeetingUtterance {
  const MeetingUtterance({
    required this.id,
    required this.speaker,
    required this.raw,
    required this.at,
    this.speakerId,
    this.speakerSeparated = false,
    this.speakerRevision = 0,
    this.speakerHistory = const [],
    this.cleaned = '',
    this.correction,
    this.withdrawn = false,
    this.manual = false,
    this.repair,
    this.audioPath,
    this.audioStart,
    this.audioEnd,
    this.turnStatus = 'complete',
    this.turnId,
  });
  final String id, speaker, raw, cleaned;
  final String? speakerId;
  final String turnStatus;
  final String? turnId;
  final bool speakerSeparated;
  final int speakerRevision;
  final List<Map<String, dynamic>> speakerHistory;
  final String? correction;
  final Duration at;
  final bool withdrawn, manual;
  final SpeechRepair? repair;
  final String? audioPath;
  final Duration? audioStart, audioEnd;
  bool get hasAudio =>
      audioPath != null &&
      audioStart != null &&
      audioEnd != null &&
      audioEnd! > audioStart!;
  // 仅改变展示副本；空白纠正/整理不覆盖原文，原始证据及其偏移保持不变。
  String get display => correction?.trim().isNotEmpty == true
      ? correction!
      : cleaned.trim().isNotEmpty
      ? cleaned
      : raw;

  /// 缺口坐标始终依据原话；显示整理后的上下文时，通过同一缺口标记定位。
  (String, String) get repairContext {
    final gap = repair;
    if (gap == null || !gap.validFor(raw)) return (display, '');
    if (gap.start == gap.end && gap.start == raw.length) return (display, '');
    final marker = raw.substring(gap.start, gap.end);
    final position = marker.isEmpty ? -1 : display.indexOf(marker);
    if (position >= 0) {
      return (
        display.substring(0, position),
        display.substring(position + marker.length),
      );
    }
    return (raw.substring(0, gap.start), raw.substring(gap.end));
  }

  MeetingUtterance revise({
    String? correction,
    String? speaker,
    String? speakerId,
    bool? speakerSeparated,
    int? speakerRevision,
    List<Map<String, dynamic>>? speakerHistory,
    bool? withdrawn,
    SpeechRepair? repair,
    bool clearRepair = false,
    String? cleaned,
    String? turnStatus,
  }) => MeetingUtterance(
    id: id,
    speaker: speaker ?? this.speaker,
    speakerId: speakerId ?? this.speakerId,
    speakerSeparated: speakerSeparated ?? this.speakerSeparated,
    speakerRevision: speakerRevision ?? this.speakerRevision,
    speakerHistory: speakerHistory ?? this.speakerHistory,
    raw: raw,
    turnStatus: turnStatus ?? this.turnStatus,
    turnId: turnId,
    at: at,
    cleaned: cleaned ?? this.cleaned,
    correction: correction ?? this.correction,
    withdrawn: withdrawn ?? this.withdrawn,
    manual: manual,
    repair: clearRepair ? null : repair ?? this.repair,
    audioPath: audioPath,
    audioStart: audioStart,
    audioEnd: audioEnd,
  );
  Map<String, dynamic> toJson() => {
    'id': id,
    'speaker': speaker,
    'speakerId': speakerId,
    'speakerSeparated': speakerSeparated,
    'speakerRevision': speakerRevision,
    'speakerHistory': speakerHistory,
    'raw': raw,
    'turnStatus': turnStatus,
    'turnId': turnId,
    'cleaned': cleaned,
    'correction': correction,
    'at': at.inMilliseconds,
    'withdrawn': withdrawn,
    'manual': manual,
    'repair': repair?.toJson(),
    'audioPath': audioPath,
    'audioStart': audioStart?.inMicroseconds,
    'audioEnd': audioEnd?.inMicroseconds,
  };
  factory MeetingUtterance.fromJson(Map<String, dynamic> j) => MeetingUtterance(
    audioPath: j['audioPath'],
    audioStart: j['audioStart'] == null
        ? null
        : Duration(microseconds: j['audioStart']),
    audioEnd: j['audioEnd'] == null
        ? null
        : Duration(microseconds: j['audioEnd']),
    id: j['id'],
    speaker: j['speaker'],
    speakerId: j['speakerId'] ?? j['speaker_id'],
    speakerSeparated:
        j['speakerSeparated'] == true || j['speaker_separated'] == true,
    speakerRevision:
        (j['speakerRevision'] ?? j['speaker_revision'] ?? 0) as int,
    speakerHistory: [
      for (final e
          in (j['speakerHistory'] ?? j['speaker_history'] ?? []) as List)
        {
          'revision': e['revision'],
          'speaker': e['speaker'],
          'speakerId': e['speakerId'] ?? e['speaker_id'],
          'speakerSeparated': e['speakerSeparated'] ?? e['speaker_separated'],
        },
    ],
    raw: j['raw'],
    turnStatus: j['turnStatus'] ?? j['turn_status'] ?? 'complete',
    turnId: j['turnId'] ?? j['turn_id'],
    cleaned: j['cleaned'] ?? '',
    correction: j['correction'],
    at: Duration(milliseconds: j['at']),
    withdrawn: j['withdrawn'] == true,
    manual: j['manual'] == true,
    repair: j['repair'] == null
        ? null
        : SpeechRepair.fromJson(Map<String, dynamic>.from(j['repair'])),
  );
}

class MeetingInsight {
  const MeetingInsight({
    required this.id,
    required this.kind,
    required this.title,
    required this.body,
    required this.evidenceIds,
    this.inference = true,
    this.anchorId,
    this.knowledgeCitations = const [],
    this.streaming = false,
    this.interrupted = false,
    this.topicKey = '',
    this.issueKey = '',
    this.attention = 'normal',
    this.impact = '',
  });
  final String id, title, body;
  final String topicKey, issueKey, attention, impact;

  /// 展示位置与证据列表分开保存，后续补充证据不移动已有提示。
  final String? anchorId;
  final InsightKind kind;
  final List<String> evidenceIds;
  final bool inference;
  final bool streaming, interrupted;
  final List<Map<String, dynamic>> knowledgeCitations;
  Map<String, dynamic> toJson() => {
    'id': id,
    'kind': kind.name,
    'title': title,
    'body': body,
    'topicKey': topicKey,
    'issueKey': issueKey,
    'attention': attention,
    'impact': impact,
    'evidenceIds': evidenceIds,
    'anchorId': anchorId,
    'inference': inference,
    'streaming': streaming,
    'interrupted': interrupted,
    'knowledgeCitations': knowledgeCitations,
  };
  factory MeetingInsight.fromJson(Map<String, dynamic> j) => MeetingInsight(
    id: j['id'],
    kind: InsightKind.values.byName(j['kind']),
    title: j['title'],
    body: j['body'],
    topicKey: j['topicKey'] ?? j['topic_key'] ?? '',
    issueKey: j['issueKey'] ?? j['issue_key'] ?? '',
    attention: j['attention'] ?? 'normal',
    impact: j['impact'] ?? '',
    evidenceIds: List<String>.from(j['evidenceIds']),
    anchorId: j['anchorId'],
    inference: j['inference'] != false,
    streaming: j['streaming'] == true,
    interrupted: j['interrupted'] == true,
    knowledgeCitations: [
      for (final c in j['knowledgeCitations'] ?? j['knowledge_citations'] ?? [])
        Map<String, dynamic>.from(c),
    ],
  );
}

class MeetingRecord {
  const MeetingRecord({
    required this.id,
    required this.startedAt,
    required this.demo,
    this.title = '录音会议',
    this.elapsed = Duration.zero,
    this.ended = false,
    this.utterances = const [],
    this.insights = const [],
    this.audioPaths = const [],
    this.cloudAudioEnabled = false,
    this.cloudAudioUploaded = false,
    this.documentId,
    this.ownerId,
    this.syncRevision = 0,
    this.cloudMinutes,
    this.minutesDetails,
    this.recoveryPendingSync = false,
    this.offlineSyncHeld = false,
    this.recordingCardFileName,
    this.recordingCardIdentity,
    this.commitments = const [],
    this.sourceChanges = const [],
    this.transcriptHighlights = const {},
    this.speakerIdentities = const {},
    this.speakerIdentityRevision = 0,
  });
  final String id, title;
  final String? documentId;
  final String? ownerId, cloudMinutes;
  final Map<String, dynamic>? minutesDetails;
  final int syncRevision;
  final DateTime startedAt;
  final bool demo, ended;
  final bool recoveryPendingSync;
  final bool offlineSyncHeld;
  final String? recordingCardFileName, recordingCardIdentity;
  final Duration elapsed;
  final List<MeetingUtterance> utterances;
  final List<MeetingInsight> insights;
  final List<String> audioPaths;
  final bool cloudAudioEnabled;
  final bool cloudAudioUploaded;
  bool get canGenerateMinutes => elapsed >= const Duration(minutes: 1);

  /// 服务端承诺分析快照，保留证据与事件，不混入客户端上传的原话。
  final List<Map<String, dynamic>> commitments;
  final List<Map<String, dynamic>> sourceChanges;

  /// 本机保存的只读标注，独立于上传原话和会议纪要业务结构。
  final Map<String, dynamic> transcriptHighlights;

  /// 服务端确认的只读身份快照；不进入正文同步请求。
  final Map<String, dynamic> speakerIdentities;
  final int speakerIdentityRevision;
  String speakerDisplayName(MeetingUtterance source) {
    final identity = speakerIdentities[source.speakerId];
    if (source.manual ||
        !source.speakerSeparated ||
        identity is! Map ||
        identity['identity'] != 'self') {
      return source.speaker;
    }
    final short = source.speaker.startsWith('发言人 ')
        ? source.speaker.substring(4)
        : source.speaker;
    return '我（$short）';
  }

  MeetingRecord copy({
    String? title,
    List<MeetingUtterance>? utterances,
    List<MeetingInsight>? insights,
    List<String>? audioPaths,
    Duration? elapsed,
    bool? ended,
    String? documentId,
    int? syncRevision,
    String? cloudMinutes,
    bool clearCloudMinutes = false,
    Map<String, dynamic>? minutesDetails,
    bool? recoveryPendingSync,
    bool? offlineSyncHeld,
    String? recordingCardFileName,
    String? recordingCardIdentity,
    List<Map<String, dynamic>>? commitments,
    List<Map<String, dynamic>>? sourceChanges,
    bool? cloudAudioUploaded,
    Map<String, dynamic>? transcriptHighlights,
    Map<String, dynamic>? speakerIdentities,
    int? speakerIdentityRevision,
  }) => MeetingRecord(
    id: id,
    title: title ?? this.title,
    startedAt: startedAt,
    demo: demo,
    elapsed: elapsed ?? this.elapsed,
    ended: ended ?? this.ended,
    utterances: utterances ?? this.utterances,
    insights: insights ?? this.insights,
    audioPaths: audioPaths ?? this.audioPaths,
    documentId: documentId ?? this.documentId,
    ownerId: ownerId,
    syncRevision: syncRevision ?? this.syncRevision,
    cloudMinutes: clearCloudMinutes ? null : cloudMinutes ?? this.cloudMinutes,
    minutesDetails: minutesDetails ?? this.minutesDetails,
    recoveryPendingSync: recoveryPendingSync ?? this.recoveryPendingSync,
    offlineSyncHeld: offlineSyncHeld ?? this.offlineSyncHeld,
    recordingCardFileName: recordingCardFileName ?? this.recordingCardFileName,
    recordingCardIdentity: recordingCardIdentity ?? this.recordingCardIdentity,
    commitments: commitments ?? this.commitments,
    sourceChanges: sourceChanges ?? this.sourceChanges,
    cloudAudioEnabled: cloudAudioEnabled,
    cloudAudioUploaded: cloudAudioUploaded ?? this.cloudAudioUploaded,
    transcriptHighlights: transcriptHighlights ?? this.transcriptHighlights,
    speakerIdentities: speakerIdentities ?? this.speakerIdentities,
    speakerIdentityRevision:
        speakerIdentityRevision ?? this.speakerIdentityRevision,
  );
  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'startedAt': startedAt.toIso8601String(),
    'demo': demo,
    'elapsed': elapsed.inMilliseconds,
    'ended': ended,
    'documentId': documentId,
    'audioPaths': audioPaths,
    'cloudAudioEnabled': cloudAudioEnabled,
    'cloudAudioUploaded': cloudAudioUploaded,
    'utterances': utterances.map((u) => u.toJson()).toList(),
    'insights': insights.map((i) => i.toJson()).toList(),
    'ownerId': ownerId,
    'syncRevision': syncRevision,
    'cloudMinutes': cloudMinutes,
    'minutesDetails': minutesDetails,
    'recoveryPendingSync': recoveryPendingSync,
    'offlineSyncHeld': offlineSyncHeld,
    'recordingCardFileName': recordingCardFileName,
    'recordingCardIdentity': recordingCardIdentity,
    'commitments': commitments,
    'sourceChanges': sourceChanges,
    'transcriptHighlights': transcriptHighlights,
    'speakerIdentities': speakerIdentities,
    'speakerIdentityRevision': speakerIdentityRevision,
  };
  factory MeetingRecord.fromJson(Map<String, dynamic> j) => MeetingRecord(
    id: j['id'],
    title: j['title'] ?? '录音会议',
    startedAt: DateTime.parse(j['startedAt']),
    demo: j['demo'] == true,
    elapsed: Duration(milliseconds: j['elapsed'] ?? 0),
    ended: j['ended'] == true,
    documentId: j['documentId'],
    ownerId: j['ownerId'],
    syncRevision: j['syncRevision'] ?? 0,
    speakerIdentityRevision: j['speakerIdentityRevision'] ?? 0,
    speakerIdentities: j['speakerIdentities'] is Map
        ? Map<String, dynamic>.from(j['speakerIdentities'])
        : const {},
    cloudMinutes: j['cloudMinutes'],
    minutesDetails: j['minutesDetails'] is Map
        ? Map<String, dynamic>.from(j['minutesDetails'])
        : null,
    recoveryPendingSync: j['recoveryPendingSync'] == true,
    offlineSyncHeld: j['offlineSyncHeld'] == true,
    recordingCardFileName: j['recordingCardFileName'],
    recordingCardIdentity: j['recordingCardIdentity'],
    transcriptHighlights: j['transcriptHighlights'] is Map
        ? Map<String, dynamic>.from(j['transcriptHighlights'])
        : const {},
    sourceChanges: (j['sourceChanges'] as List? ?? [])
        .map((v) => Map<String, dynamic>.from(v))
        .toList(),
    commitments: (j['commitments'] as List? ?? [])
        .map((v) => Map<String, dynamic>.from(v))
        .toList(),
    audioPaths: List<String>.from(j['audioPaths'] ?? []),
    cloudAudioEnabled: j['cloudAudioEnabled'] == true,
    cloudAudioUploaded: j['cloudAudioUploaded'] == true,
    utterances: (j['utterances'] as List? ?? [])
        .map((u) => MeetingUtterance.fromJson(Map<String, dynamic>.from(u)))
        .toList(),
    insights: parseMeetingInsights(j['insights']),
  );
}

String meetingTime(Duration value) =>
    '${value.inMinutes.toString().padLeft(2, '0')}:${(value.inSeconds % 60).toString().padLeft(2, '0')}';

/// Conservative display cleanup, never mutates the immutable original.
String tidySpeech(String raw) => raw
    .replaceAll(RegExp(r'(^|[，,。\s])(嗯|呃|额)([，,。\s]|$)'), ' ')
    .replaceAllMapped(RegExp(r'(我们|这个|那个|然后|就是)(?:[，,\s]*\1)+'), (m) => m[1]!)
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

List<MeetingInsight> parseMeetingInsights(Object? input) {
  final result = <MeetingInsight>[];
  for (final row in input is List ? input : const []) {
    if (row is! Map) continue;
    try {
      result.add(MeetingInsight.fromJson(Map<String, dynamic>.from(row)));
    } catch (_) {
      /* Unknown or malformed suggestions cannot erase the transcript. */
    }
  }
  return result;
}
