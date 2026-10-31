import 'dart:io';
import 'dart:ffi';
import 'dart:typed_data';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;
import 'package:yanshu/features/meeting/speech_engine.dart';

void main(List<String> args) {
  if (args.length != 1) {
    throw ArgumentError('Pass an official model sample WAV path');
  }
  if (Platform.isWindows) {
    final path = sherpa.resolveSherpaOnnxPathSync()!;
    DynamicLibrary.open('$path/onnxruntime.dll');
  }
  sherpa.initBindings();
  final recognizer = createMeetingSpeechEngine('assets/speech');
  final stream = recognizer.createStream();
  final wave = sherpa.readWave(args.single);
  var partials = 0;
  var finals = 0;
  var previous = '';
  final output = StringBuffer();
  void decode({bool finalResult = false}) {
    while (recognizer.isReady(stream)) {
      recognizer.decode(stream);
    }
    final text = recognizer.getResult(stream).text;
    if (text.isNotEmpty && text != previous) partials++;
    previous = text;
    if (finalResult || recognizer.isEndpoint(stream)) {
      if (text.isNotEmpty) {
        output.write(text);
        finals++;
      }
      recognizer.reset(stream);
      previous = '';
    }
  }

  for (var start = 0; start < wave.samples.length; start += 3200) {
    final end = (start + 3200).clamp(0, wave.samples.length);
    stream.acceptWaveform(
      samples: Float32List.sublistView(wave.samples, start, end),
      sampleRate: wave.sampleRate,
    );
    decode();
  }
  stream.acceptWaveform(
    samples: Float32List(8000),
    sampleRate: wave.sampleRate,
  );
  stream.inputFinished();
  decode(finalResult: true);
  stream.free();
  recognizer.free();
  if (output.isEmpty || partials < 2 || finals == 0) {
    throw StateError('Streaming speech smoke check failed');
  }
  stdout.writeln(
    'PASS: partialUpdates=$partials finalSegments=$finals recognizedCharacters=${output.length}',
  );
  stdout.writeln(output.toString());
}
