import 'dart:convert';

/// Display facts only; this type never starts/stops a recorder.
class RecordingStatusSnapshot {
  const RecordingStatusSnapshot({
    required this.meetingId,
    required this.source,
    required this.sourceLabel,
    required this.capturing,
    required this.connected,
    required this.state,
    required this.transcription,
    required this.elapsed,
    required this.startedAt,
    this.details = const {},
  });
  final String meetingId, source, sourceLabel, state, transcription;
  final bool capturing, connected;
  final Duration elapsed;
  final DateTime startedAt;
  final Map<String, String> details;
  String get stateLabel => switch (state) {
    'processing' => '录音已结束',
    'recording' => '录音中',
    'paused' => '录音已暂停',
    'interrupted' => '采音已中断',
    _ => '采音状态待核实',
  };
  String get transcriptionLabel => switch (transcription) {
    'processing' => '正在保存录音',
    'transcribing' => '实时转写中',
    'interrupted' => '实时转写不可用',
    'connecting' => '转写连接中',
    _ => '转写未开启',
  };
  String get fingerprint => jsonEncode([
    meetingId,
    source,
    sourceLabel,
    capturing,
    connected,
    state,
    transcription,
    details,
  ]);
  Map<String, dynamic> payload(int sequence) => {
    'meetingId': meetingId,
    'source': source,
    'sourceLabel': sourceLabel,
    'capturing': capturing,
    'connected': connected,
    'state': state,
    'transcription': transcriptionLabel,
    'stateLabel': stateLabel,
    'elapsedMs': elapsed.inMilliseconds,
    'startedAtMs': startedAt.millisecondsSinceEpoch,
    'sequence': sequence,
    'details': details,
  };
}

String? recordingMeetingFromUri(Uri? uri) {
  if (uri == null ||
      uri.scheme != 'agenote' ||
      uri.host != 'recording' ||
      uri.pathSegments.length != 1 ||
      uri.hasQuery ||
      uri.hasFragment) {
    return null;
  }
  final id = uri.pathSegments.single;
  return RegExp(r'^[a-zA-Z0-9_-]{1,128}$').hasMatch(id) ? id : null;
}
