import 'dart:io';
import 'local_speech.dart';

/// Extracts only the original PCM samples associated with a recognition segment.
/// Generated corrections and speculative repairs never enter playback.
Future<void> writeMeetingAudioClip(
  File source,
  File destination,
  Duration start,
  Duration end,
) async {
  final input = await source.open();
  try {
    final header = await input.read(44);
    if (header.length != 44 ||
        String.fromCharCodes(header.take(4)) != 'RIFF' ||
        String.fromCharCodes(header.skip(36).take(4)) != 'data') {
      throw StateError('Unsupported meeting recording');
    }
    final first = (start.inMicroseconds * 16000 / 1000000).round();
    final last = (end.inMicroseconds * 16000 / 1000000).round();
    final length = await input.length();
    if (first < 0 || last <= first || 44 + last * 2 > length) {
      throw StateError('Recording segment is not available');
    }
    final output = await destination.open(mode: FileMode.write);
    try {
      var remaining = (last - first) * 2;
      await output.writeFrom(meetingWavHeader(remaining));
      await input.setPosition(44 + first * 2);
      while (remaining > 0) {
        final bytes = await input.read(remaining.clamp(0, 65536));
        if (bytes.isEmpty) throw StateError('Incomplete recording segment');
        await output.writeFrom(bytes);
        remaining -= bytes.length;
      }
      await output.flush();
    } finally {
      await output.close();
    }
  } finally {
    await input.close();
  }
}
