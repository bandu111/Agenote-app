import 'dart:typed_data';
import 'transcript_highlight_models.dart';
import 'live_speaker_identity.dart';

class MeetingTranscript {
  const MeetingTranscript(
    this.segment,
    this.text, {
    required this.isFinal,
    this.audioStart,
    this.audioEnd,
    this.speakerId,
    this.speakerSeparated = false,
    this.speakerRevision = 0,
    this.isSpeakerUpdate = false,
    this.highlightBatch,
    this.identityEvent,
  });
  final String? speakerId;
  final TranscriptHighlightBatch? highlightBatch;
  final LiveSpeakerIdentityEvent? identityEvent;
  final bool speakerSeparated, isSpeakerUpdate;
  final int speakerRevision;
  final int segment;
  final String text;
  final bool isFinal;
  final Duration? audioStart, audioEnd;
}

/// 可替换的识别协议；原始证据与模型输出相互独立。
abstract interface class MeetingSpeechRecognizer {
  Stream<MeetingTranscript> get transcripts;
  int get pendingMilliseconds;
  Future<void> start();
  void accept(Uint8List bytes);
  Future<void> flush();
  Future<void> close();
}

/// 立即取消网络连接，不等待识别刷尾；原始文件由录音器保留。
abstract interface class AbortableMeetingSpeechRecognizer {
  Future<void> abort();
}
