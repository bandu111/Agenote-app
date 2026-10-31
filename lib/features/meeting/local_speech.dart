import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;
import 'speech_engine.dart';
import 'speech_recognizer.dart';
export 'speech_recognizer.dart' show MeetingTranscript;

/// 原生识别在独立线程运行，麦克风只采集一次。
class LocalSpeechWorker implements MeetingSpeechRecognizer {
  LocalSpeechWorker({this.model = MeetingSpeechModel.chinese});
  final MeetingSpeechModel model;
  List<String> get modelFiles => [
    'encoder.int8.onnx',
    model.decoderFile,
    'joiner.int8.onnx',
    'tokens.txt',
  ];
  final _events = StreamController<MeetingTranscript>.broadcast(sync: true);
  @override
  Stream<MeetingTranscript> get transcripts => _events.stream;
  ReceivePort? _receive;
  Isolate? _isolate;
  SendPort? _send;
  Completer<void>? _flush;
  Completer<void>? _closed;
  int _pendingSamples = 0;
  bool _overloaded = false;
  @override
  int get pendingMilliseconds => _pendingSamples * 1000 ~/ 16000;

  @override
  Future<void> start() async {
    final root = await getApplicationSupportDirectory();
    final directory = await Directory(
      '${root.path}/speech-${model.id}',
    ).create(recursive: true);
    for (final name in modelFiles) {
      final file = File('${directory.path}/$name');
      final data = await rootBundle.load('${model.assets}/$name');
      if (!await file.exists() || await file.length() != data.lengthInBytes) {
        final temp = File('${file.path}.tmp');
        await temp.writeAsBytes(
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
          flush: true,
        );
        await temp.rename(file.path);
      }
    }
    final ready = Completer<void>();
    _receive = ReceivePort();
    _receive!.listen((dynamic value) {
      if (value is SendPort) {
        _send = value;
        if (!ready.isCompleted) ready.complete();
      } else if (value is List && value[0] == 'text') {
        _events.add(
          MeetingTranscript(
            value[1] as int,
            value[2] as String,
            isFinal: value[3] as bool,
            audioStart: Duration(
              microseconds: (value[4] as int) * 1000000 ~/ 16000,
            ),
            audioEnd: Duration(
              microseconds: (value[5] as int) * 1000000 ~/ 16000,
            ),
          ),
        );
      } else if (value == 'flushed') {
        if (_flush?.isCompleted == false) _flush!.complete();
      } else if (value == 'closed') {
        if (_closed?.isCompleted == false) _closed!.complete();
      } else if (value is List && value[0] == 'accepted') {
        _pendingSamples = (_pendingSamples - (value[1] as int)).clamp(
          0,
          160000,
        );
      } else if (value is List && value[0] == 'error') {
        final error = StateError('本地转写引擎未能启动：${value[1]}');
        if (!ready.isCompleted) {
          ready.completeError(error);
        } else {
          _events.addError(error);
          if (_flush?.isCompleted == false) _flush!.completeError(error);
        }
      }
    });
    _isolate = await Isolate.spawn(_speechMain, [
      _receive!.sendPort,
      directory.path,
      model,
    ]);
    try {
      await ready.future.timeout(const Duration(seconds: 60));
    } catch (_) {
      await close();
      rethrow;
    }
  }

  @override
  void accept(Uint8List bytes) {
    if (_send == null || _overloaded) return;
    if (_pendingSamples + bytes.length ~/ 2 > 160000) {
      _overloaded = true;
      _events.addError(StateError('转写处理积压超过10秒，已停止接纳新转写；原始录音保留，请暂停后重试'));
      return;
    }
    _pendingSamples += bytes.length ~/ 2;
    _send!.send(TransferableTypedData.fromList([bytes]));
  }

  @override
  Future<void> flush() async {
    if (_send == null) return;
    if (_flush != null) return _flush!.future;
    final pending = _flush = Completer<void>();
    _send!.send('flush');
    try {
      await pending.future.timeout(const Duration(seconds: 30));
      _overloaded = false;
    } on TimeoutException {
      _overloaded = true;
      _events.addError(StateError('本地转写引擎响应超时，转写已停止；原始录音保留，请结束后重试'));
      rethrow;
    } finally {
      _flush = null;
    }
  }

  @override
  Future<void> close() async {
    if (_send != null) {
      _closed = Completer<void>();
      _send!.send('close');
      try {
        await _closed!.future.timeout(const Duration(seconds: 5));
      } on TimeoutException {
        // 超时后终止异常工作线程；正常线程会先释放原生资源。
      }
    }
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _send = null;
    _receive?.close();
    _receive = null;
    await _events.close();
  }
}

void _speechMain(List<Object> args) {
  final send = args[0] as SendPort;
  final directory = args[1] as String;
  try {
    sherpa.initBindings();
    final recognizer = createMeetingSpeechEngine(
      directory,
      model: args[2] as MeetingSpeechModel,
    );
    var stream = recognizer.createStream();
    var segment = 0;
    var previous = '';
    var samplesReceived = 0, segmentStart = 0;
    void decode({bool finalResult = false}) {
      while (recognizer.isReady(stream)) {
        recognizer.decode(stream);
      }
      final text = recognizer.getResult(stream).text.trim();
      final endpoint = finalResult || recognizer.isEndpoint(stream);
      if (endpoint || text.isNotEmpty && text != previous) {
        send.send([
          'text',
          segment,
          text,
          endpoint,
          segmentStart,
          samplesReceived,
        ]);
      }
      previous = text;
      if (endpoint) {
        recognizer.reset(stream);
        segment++;
        segmentStart = samplesReceived;
        previous = '';
      }
    }

    final receive = ReceivePort();
    send.send(receive.sendPort);
    receive.listen((dynamic message) {
      try {
        if (message is TransferableTypedData) {
          final bytes = message.materialize().asUint8List();
          final view = ByteData.sublistView(bytes);
          final samples = Float32List(bytes.length ~/ 2);
          for (var i = 0; i < samples.length; i++) {
            samples[i] = view.getInt16(i * 2, Endian.little) / 32768;
          }
          samplesReceived += samples.length;
          stream.acceptWaveform(samples: samples, sampleRate: 16000);
          decode();
          send.send(['accepted', samples.length]);
        } else if (message == 'flush') {
          stream.acceptWaveform(samples: Float32List(8000), sampleRate: 16000);
          stream.inputFinished();
          decode(finalResult: true);
          stream.free();
          stream = recognizer.createStream();
          send.send('flushed');
        } else if (message == 'close') {
          stream.free();
          recognizer.free();
          send.send('closed');
          receive.close();
        }
      } catch (e) {
        send.send(['error', e.toString()]);
      }
    });
  } catch (e) {
    send.send(['error', e.toString()]);
  }
}

Uint8List meetingWavHeader(int pcmBytes) {
  final header = ByteData(44);
  void chars(int offset, String value) {
    for (var i = 0; i < value.length; i++) {
      header.setUint8(offset + i, value.codeUnitAt(i));
    }
  }

  chars(0, 'RIFF');
  header.setUint32(4, pcmBytes + 36, Endian.little);
  chars(8, 'WAVE');
  chars(12, 'fmt ');
  header.setUint32(16, 16, Endian.little);
  header.setUint16(20, 1, Endian.little);
  header.setUint16(22, 1, Endian.little);
  header.setUint32(24, 16000, Endian.little);
  header.setUint32(28, 32000, Endian.little);
  header.setUint16(32, 2, Endian.little);
  header.setUint16(34, 16, Endian.little);
  chars(36, 'data');
  header.setUint32(40, pcmBytes, Endian.little);
  return header.buffer.asUint8List();
}
