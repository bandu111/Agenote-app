import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:yanshu/features/meeting/local_speech.dart';
import 'package:yanshu/features/meeting/resumable_speech.dart';
import 'package:yanshu/features/meeting/speech_recognizer.dart';
import 'package:yanshu/features/meeting/live_speaker_identity.dart';

class NetworkRecognizer implements MeetingSpeechRecognizer {
  NetworkRecognizer({this.failStart = false, this.failAfter});
  final bool failStart;
  final int? failAfter;
  final events = StreamController<MeetingTranscript>.broadcast(sync: true);
  int bytes = 0;
  bool failed = false;
  @override
  Stream<MeetingTranscript> get transcripts => events.stream;
  @override
  int get pendingMilliseconds => 0;
  @override
  Future<void> start() async {
    if (failStart) throw StateError('offline');
  }

  @override
  void accept(Uint8List frame) {
    bytes += frame.length;
    if (failAfter != null && bytes >= failAfter!) {
      failed = true;
      events.addError(StateError('disconnected'));
      return;
    }
    events.add(
      MeetingTranscript(
        bytes ~/ 3200,
        '尚未批准，不要取消原计划',
        isFinal: true,
        audioStart: Duration(milliseconds: (bytes - frame.length) ~/ 32),
        audioEnd: Duration(milliseconds: bytes ~/ 32),
        speakerId: 'asr:same-context:0',
        speakerSeparated: true,
      ),
    );
  }

  @override
  Future<void> flush() async {
    if (failed) throw StateError('offline');
  }

  @override
  Future<void> close() async {
    await events.close();
  }
}

Future<void> until(bool Function() condition) async {
  for (var n = 0; n < 250 && !condition(); n++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(condition(), isTrue);
}

class SilentRecognizer extends NetworkRecognizer {
  @override
  void accept(Uint8List frame) {
    bytes += frame.length;
  }
}

class IdentityRecognizer extends NetworkRecognizer {
  @override
  Future<void> start() async {
    events.add(
      const MeetingTranscript(
        -1,
        '',
        isFinal: false,
        identityEvent: LiveSpeakerIdentityEvent(
          sessionId: 'test',
          scope: 'test',
          isSession: true,
          status: 'enabled',
        ),
      ),
    );
  }
}

void main() {
  test(
    'resumable production wrapper forwards identity without assigning transcript IDs',
    () async {
      final dir = await Directory.systemTemp.createTemp(
        'yanshu-identity-wrapper-',
      );
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/original.wav');
      await file.writeAsBytes([
        ...meetingWavHeader(3200),
        ...List.filled(3200, 0),
      ]);
      final worker = ResumableSpeechWorker(
        path: file.path,
        committedBytes: () async => 3200,
        frameDelay: Duration.zero,
        factory: () => IdentityRecognizer(),
      );
      final events = <MeetingTranscript>[];
      final sub = worker.transcripts.listen(events.add);
      try {
        await worker.start();
        await until(() => events.any((e) => e.isFinal));
        expect(events.where((e) => e.identityEvent != null).single.segment, -1);
        expect(events.where((e) => e.isFinal).single.segment, 0);
        expect(worker.pendingMilliseconds, 0);
      } finally {
        await worker.close();
        await sub.cancel();
      }
    },
  );
  test('长静音通过供应商刷尾确认游标后轮换，不伪造转写或重放全部静音', () async {
    final dir = await Directory.systemTemp.createTemp(
      'yanshu-silent-checkpoint-',
    );
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/original.wav');
    await file.writeAsBytes([
      ...meetingWavHeader(12800),
      ...List.filled(12800, 0),
    ]);
    final workers = <SilentRecognizer>[];
    final worker = ResumableSpeechWorker(
      path: file.path,
      committedBytes: () async => 12800,
      frameDelay: Duration.zero,
      unconfirmedWindowBytes: 6400,
      factory: () {
        final next = SilentRecognizer();
        workers.add(next);
        return next;
      },
    );
    final texts = <MeetingTranscript>[];
    final sub = worker.transcripts.listen(texts.add);
    await worker.start();
    await until(() => workers.length >= 2);
    await worker.flush();
    expect(texts, isEmpty);
    expect(workers.fold<int>(0, (sum, w) => sum + w.bytes), 12800);
    expect(worker.pendingMilliseconds, 0);
    await worker.close();
    await sub.cancel();
  });
  test('长会议自动轮换连接，无需暂停或点击发送，持续产出稳定句', () async {
    final dir = await Directory.systemTemp.createTemp('yanshu-long-session-');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/original.wav');
    await file.writeAsBytes([
      ...meetingWavHeader(25600),
      ...List.filled(25600, 0),
    ]);
    var connections = 0;
    final worker = ResumableSpeechWorker(
      path: file.path,
      committedBytes: () async => 25600,
      frameDelay: Duration.zero,
      rotateAfterBytes: 6400,
      factory: () {
        connections++;
        return NetworkRecognizer();
      },
    );
    final text = <MeetingTranscript>[];
    final sub = worker.transcripts.listen(text.add);
    await worker.start();
    // 在任何显式 flush/pause 之前就收到全部稳定句，验证真实连续发送路径。
    await until(() => text.length == 8);
    expect(connections, greaterThanOrEqualTo(4));
    expect(text.map((e) => e.audioEnd!.inMilliseconds), [
      100,
      200,
      300,
      400,
      500,
      600,
      700,
      800,
    ]);
    await worker.flush();
    await worker.close();
    await sub.cancel();
  });

  test('录音不中断即可重连、重发未确认尾段，并继续处理新采样而不重复已确认原话', () async {
    final dir = await Directory.systemTemp.createTemp('yanshu-live-reconnect-');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/original.wav');
    await file.writeAsBytes([
      ...meetingWavHeader(6400),
      ...List.filled(6400, 0),
    ]);
    var available = 6400;
    final workers = <NetworkRecognizer>[];
    final worker = ResumableSpeechWorker(
      path: file.path,
      committedBytes: () async => available,
      frameDelay: Duration.zero,
      retryDelay: const Duration(milliseconds: 1),
      factory: () {
        final next = NetworkRecognizer(
          failAfter: workers.isEmpty ? 6400 : null,
        );
        workers.add(next);
        return next;
      },
    );
    final text = <MeetingTranscript>[], states = <String>[];
    final sub = worker.transcripts.listen(text.add),
        status = worker.states.listen(states.add);
    await worker.start();
    await until(() => text.length == 2);
    await file.writeAsBytes(
      List.filled(3200, 0),
      mode: FileMode.append,
      flush: true,
    );
    available = 9600;
    await until(() => text.length == 3);
    await worker.flush();
    expect(workers.length, 2);
    expect(workers.map((w) => w.bytes), [6400, 6400]);
    expect(text.map((e) => e.audioEnd!.inMilliseconds), [100, 200, 300]);
    expect(text.map((e) => e.segment).toSet().length, 3);
    expect(
      text.every(
        (e) => e.text.contains('不要取消') && e.speakerId == 'asr:same-context:0',
      ),
      isTrue,
    );
    expect(states, contains('transcription_pending'));
    expect(worker.pendingMilliseconds, 0);
    expect(await file.length(), 9644);
    await worker.close();
    await sub.cancel();
    await status.cancel();
  });

  test('初始离线仍保存采样，恢复后刷尾；暂停续录沿用原音频时间', () async {
    final dir = await Directory.systemTemp.createTemp('yanshu-start-offline-');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/original.wav');
    await file.writeAsBytes([
      ...meetingWavHeader(3200),
      ...List.filled(3200, 0),
    ]);
    var calls = 0, available = 3200;
    final worker = ResumableSpeechWorker(
      path: file.path,
      committedBytes: () async => available,
      frameDelay: Duration.zero,
      retryDelay: const Duration(milliseconds: 1),
      factory: () => NetworkRecognizer(failStart: calls++ == 0),
    );
    final text = <MeetingTranscript>[];
    final sub = worker.transcripts.listen(text.add);
    await worker.start();
    await until(() => text.length == 1);
    await worker.flush();
    await file.writeAsBytes(
      List.filled(3200, 0),
      mode: FileMode.append,
      flush: true,
    );
    available = 6400;
    await worker.start();
    await until(() => text.length == 2);
    await worker.flush();
    expect(text.map((e) => e.audioEnd!.inMilliseconds), [100, 200]);
    await worker.close();
    await sub.cancel();
  });

  test('持续离线刷尾超时后停止重试，原始录音保留供跨进程恢复', () async {
    final dir = await Directory.systemTemp.createTemp('yanshu-offline-stop-');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/original.wav');
    final raw = [...meetingWavHeader(3200), ...List.filled(3200, 7)];
    await file.writeAsBytes(raw);
    var calls = 0;
    final worker = ResumableSpeechWorker(
      path: file.path,
      committedBytes: () async => 3200,
      retryDelay: const Duration(milliseconds: 1),
      flushTimeout: const Duration(milliseconds: 15),
      factory: () {
        calls++;
        return NetworkRecognizer(failStart: true);
      },
    );
    await worker.start();
    await expectLater(worker.flush(), throwsA(isA<TimeoutException>()));
    await worker.close();
    final ended = calls;
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(calls, ended);
    expect(await file.readAsBytes(), raw);
  });
}
