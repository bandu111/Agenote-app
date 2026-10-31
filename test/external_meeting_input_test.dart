import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:yanshu/features/meeting/audio_input_route.dart';
import 'package:yanshu/features/meeting/meeting_pcm_input.dart';
import 'package:yanshu/features/meeting/meeting_services.dart';
import 'package:yanshu/features/meeting/speech_recognizer.dart';
import 'package:yanshu/features/recording_device/soninote_pcm_input.dart';

class _Speech implements MeetingSpeechRecognizer {
  final received = BytesBuilder();
  final events = StreamController<MeetingTranscript>.broadcast();
  @override
  Stream<MeetingTranscript> get transcripts => events.stream;
  @override
  int get pendingMilliseconds => 0;
  @override
  Future<void> start() async {}
  @override
  void accept(Uint8List bytes) => received.add(bytes);
  @override
  Future<void> flush() async {}
  @override
  Future<void> close() => events.close();
}

class _Input implements MeetingPcmInput {
  final pcm = StreamController<Uint8List>();
  final signals = StreamController<String>.broadcast();
  bool failStart = false, failStop = false;
  int starts = 0, stops = 0;
  @override
  Stream<String> get states => signals.stream;
  @override
  AudioInputRoute get route => const AudioInputRoute(
    id: 'card',
    name: 'CB08',
    type: 'recordingCard',
    verified: true,
    sampleRate: 16000,
    channels: 1,
  );
  @override
  Future<Stream<Uint8List>> start() async {
    starts++;
    if (failStart) throw StateError('录音卡未连接');
    return pcm.stream;
  }

  @override
  Future<void> pause() async {}
  @override
  Future<void> resume() async {}
  @override
  Future<void> stop() async {
    stops++;
    unawaited(pcm.close());
    if (failStop) throw StateError('设备停止未确认');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'Opus transport fragments and combined packets retain every byte in order',
    () {
      final framer = SoniNoteOpusFramer();
      final bytes = Uint8List.fromList(List.generate(120, (i) => i));
      expect(framer.add(Uint8List.sublistView(bytes, 0, 17)), isEmpty);
      final frames = framer.add(Uint8List.sublistView(bytes, 17));
      expect(frames.length, 3);
      expect(frames.expand((f) => f), bytes);
      expect(framer.remainingBytes, 0);
    },
  );
  test(
    'External PCM reaches ASR and WAV without using phone recording APIs',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'yanshu-external-',
      );
      final input = _Input(), speech = _Speech();
      final recorder = DeviceMeetingRecorder(
        directory: directory,
        recognizerFactory: (_) => speech,
      )..externalInput = input;
      try {
        final path = await recorder.start('card-test');
        final pcm = Uint8List.fromList(List.generate(3200, (i) => i % 256));
        input.pcm.add(pcm);
        await Future<void>.delayed(const Duration(milliseconds: 10));
        await recorder.stop();
        expect(speech.received.takeBytes(), pcm);
        final wav = await File(path).readAsBytes();
        expect(wav.sublist(44), pcm);
        expect(ByteData.sublistView(wav).getUint32(40, Endian.little), 3200);
        expect(recorder.inputRoute!.type, 'recordingCard');
        expect(input.stops, 1);
      } finally {
        await recorder.dispose();
        await input.signals.close();
        await directory.delete(recursive: true);
      }
    },
  );
  test('Failed external start never falls back to phone microphone', () async {
    final directory = await Directory.systemTemp.createTemp('yanshu-external-');
    final input = _Input()..failStart = true;
    final recorder = DeviceMeetingRecorder(
      directory: directory,
      recognizerFactory: (_) => _Speech(),
    )..externalInput = input;
    try {
      await expectLater(recorder.start('same-session'), throwsStateError);
      // A resume of the same meeting must retain the card source, even after
      // cleanup clears the next-start selection.
      await expectLater(recorder.start('same-session'), throwsStateError);
      expect(input.starts, 2);
      expect(recorder.inputRoute, isNull);
    } finally {
      await recorder.dispose();
      await input.signals.close();
      await directory.delete(recursive: true);
    }
  });
  test(
    'Stop acknowledgement failure still finalizes the locally received audio',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'yanshu-external-',
      );
      final input = _Input()..failStop = true;
      final recorder = DeviceMeetingRecorder(
        directory: directory,
        recognizerFactory: (_) => _Speech(),
      )..externalInput = input;
      try {
        final path = await recorder.start('stop-test');
        input.pcm.add(Uint8List(3200));
        await Future<void>.delayed(const Duration(milliseconds: 10));
        await expectLater(recorder.stop(), throwsStateError);
        expect(await File(path).length(), 3244);
      } finally {
        await recorder.dispose();
        await input.signals.close();
        await directory.delete(recursive: true);
      }
    },
  );
}
