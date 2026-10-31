import 'dart:typed_data';
import 'audio_input_route.dart';

/// External capture must supply real PCM16LE at 16kHz mono, never a phone fallback.
abstract interface class MeetingPcmInput {
  Stream<String> get states;
  AudioInputRoute get route;
  Future<Stream<Uint8List>> start();
  Future<void> pause();
  Future<void> resume();
  Future<void> stop();
}
