import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:yanshu/features/meeting/meeting_audio_recovery.dart';
import 'package:yanshu/features/meeting/meeting_models.dart';
import 'package:yanshu/features/meeting/local_speech.dart';
import 'package:yanshu/features/meeting/speech_recognizer.dart';

class ReplayRecognizer implements MeetingSpeechRecognizer {
  ReplayRecognizer({this.failAfter});
  final int? failAfter;
  final controller = StreamController<MeetingTranscript>.broadcast(sync: true);
  int bytes = 0;
  bool failed = false;
  @override
  Stream<MeetingTranscript> get transcripts => controller.stream;
  @override
  int get pendingMilliseconds => 0;
  @override
  Future<void> start() async {}
  @override
  void accept(Uint8List value) {
    bytes += value.length;
    if (failAfter != null && bytes >= failAfter!) {
      failed = true;
      controller.addError(StateError('offline'));
      return;
    }
    controller.add(
      MeetingTranscript(
        bytes ~/ 3200,
        '不能取消原计划',
        isFinal: true,
        audioStart: Duration(milliseconds: (bytes - value.length) ~/ 32),
        audioEnd: Duration(milliseconds: bytes ~/ 32),
      ),
    );
  }

  @override
  Future<void> flush() async {
    if (failed) throw StateError('offline');
  }

  @override
  Future<void> close() async => controller.close();
}

void main() {
  test('中断后从已持久化确认游标恢复，重启不重复转写，WAV旧头也能恢复', () async {
    final dir = await Directory.systemTemp.createTemp('yanshu-recovery-test-');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/capture.wav');
    await file.writeAsBytes([...meetingWavHeader(0), ...List.filled(9600, 0)]);
    final record = MeetingRecord(
      id: 'meeting',
      startedAt: DateTime.now(),
      demo: false,
      ownerId: 'owner',
      audioPaths: [file.path],
    );
    final first = ReplayRecognizer(failAfter: 6400);
    final service = MeetingAudioRecovery(
      (_) => first,
      frameDelay: Duration.zero,
    );
    var count = 0;
    try {
      await for (final _ in service.recover(record, isCurrent: () => true)) {
        count++;
      }
      fail('网络中断应保留失败状态');
    } on StateError {
      /* 后续实例继续处理已确认位置之后的数据。 */
    }
    expect(count, 1);
    expect(await service.hasPending(record), isTrue);
    final next = ReplayRecognizer();
    final restarted = MeetingAudioRecovery(
      (_) => next,
      frameDelay: Duration.zero,
    );
    final results = await restarted
        .recover(record, isCurrent: () => true)
        .toList();
    expect(next.bytes, 6400);
    expect(results.first.offset, const Duration(milliseconds: 100));
    expect(results.every((e) => e.transcript.text == '不能取消原计划'), isTrue);
    expect(await restarted.hasPending(record), isFalse);
    expect(
      await restarted.recover(record, isCurrent: () => true).toList(),
      isEmpty,
    );
    expect(await file.length(), 9644);
  });

  test('账户已切换时不读取或发送原账户音频', () async {
    var calls = 0;
    final service = MeetingAudioRecovery((_) {
      calls++;
      return ReplayRecognizer();
    });
    final record = MeetingRecord(
      id: 'meeting',
      startedAt: DateTime.now(),
      demo: false,
      ownerId: 'other',
      audioPaths: ['does-not-exist.wav'],
    );
    expect(
      await service.recover(record, isCurrent: () => false).toList(),
      isEmpty,
    );
    expect(calls, 0);
  });
}
