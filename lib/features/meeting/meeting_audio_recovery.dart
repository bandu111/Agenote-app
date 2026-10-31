import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import '../knowledge/models/knowledge_models.dart';
import 'meeting_models.dart';
import 'speech_recognizer.dart';

/// 只有原话持久化完成，才写入可跨进程使用的确认游标。
final _cursorWrites = <String, Future<void>>{};

Future<void> saveAsrCursor(String path, int bytes) {
  final previous = _cursorWrites[path] ?? Future<void>.value();
  final next = previous
      .catchError((Object _) {})
      .then((_) => _writeAsrCursor(path, bytes));
  _cursorWrites[path] = next;
  unawaited(
    next.then<void>(
      (_) {
        if (identical(_cursorWrites[path], next)) _cursorWrites.remove(path);
      },
      onError: (Object _, StackTrace _) {
        if (identical(_cursorWrites[path], next)) _cursorWrites.remove(path);
      },
    ),
  );
  return next;
}

Future<void> _writeAsrCursor(String path, int bytes) async {
  final f = File('$path.asr-progress.json');
  final temp = File('${f.path}.tmp'), backup = File('${f.path}.backup');
  await temp.writeAsString(
    jsonEncode({'schema': 1, 'asrCompleteBytes': bytes}),
    flush: true,
  );
  if (await backup.exists()) await backup.delete();
  if (await f.exists()) await f.rename(backup.path);
  try {
    await temp.rename(f.path);
  } catch (_) {
    if (await backup.exists()) await backup.rename(f.path);
    rethrow;
  }
  if (await backup.exists()) await backup.delete();
}

class RecoveredAudioEvent {
  const RecoveredAudioEvent(
    this.path,
    this.baseByte,
    this.transcript,
    this.timelineOffset,
  );
  final String path;
  final int baseByte;
  final MeetingTranscript transcript;
  final Duration timelineOffset;
  String get id =>
      'recovered-${knowledgeHash(path).substring(0, 16)}-$baseByte-${transcript.segment}';
  Duration get offset => Duration(microseconds: baseByte * 1000000 ~/ 32000);
}

/// 原始 WAV 就是持久化待转写队列；游标仅在调用方保存原话后推进。
/// 不上传完整文件到业务库，重播严格遵循供应商 1:1 的实时率。
class MeetingAudioRecovery {
  MeetingAudioRecovery(
    this.recognizer, {
    this.frameDelay = const Duration(milliseconds: 100),
  });
  final MeetingSpeechRecognizer Function(String sessionId) recognizer;
  final Duration frameDelay;

  Future<int> _length(String path) async {
    final f = File(path);
    if (!await f.exists()) throw StateError('原始录音文件不可用');
    final file = await f.open();
    try {
      final h = await file.read(44);
      if (h.length != 44 ||
          ascii.decode(h.sublist(0, 4)) != 'RIFF' ||
          ascii.decode(h.sublist(8, 12)) != 'WAVE' ||
          ascii.decode(h.sublist(36, 40)) != 'data' ||
          ByteData.sublistView(h).getUint16(20, Endian.little) != 1 ||
          ByteData.sublistView(h).getUint32(24, Endian.little) != 16000 ||
          ByteData.sublistView(h).getUint16(22, Endian.little) != 1 ||
          ByteData.sublistView(h).getUint16(34, Endian.little) != 16) {
        throw StateError('录音格式不符合补转写协议');
      }
      final size = (await file.length() - 44);
      return size - size % 2;
    } finally {
      await file.close();
    }
  }

  Future<int> _cursor(MeetingRecord r, String path) async {
    final length = await _length(path);
    var cursor = 0;
    for (final u in r.utterances.where(
      (u) => u.audioPath == path && u.audioEnd != null,
    )) {
      final end = u.audioEnd!.inMilliseconds * 32;
      if (end > cursor && end <= length) cursor = end;
    }
    for (final suffix in ['.capture.json', '.asr-progress.json']) {
      final f = File('$path$suffix');
      final backup = File('${f.path}.backup');
      final source = await f.exists() ? f : backup;
      if (!await source.exists()) continue;
      try {
        final j = jsonDecode(await source.readAsString());
        if (j is! Map) continue;
        final value = j['asrCompleteBytes'];
        if (value is int && value >= 0 && value <= length && value > cursor) {
          cursor = value;
        }
      } on FormatException {
        /* 中断写入时根据已保存原话恢复，不信任损坏游标。 */
      }
    }
    return cursor;
  }

  Future<bool> hasPending(MeetingRecord r) async {
    if (r.demo) return false;
    for (final path in r.audioPaths) {
      if (await _cursor(r, path) < await _length(path)) return true;
    }
    return false;
  }

  Future<void> _saveCursor(String path, int bytes) =>
      saveAsrCursor(path, bytes);

  Stream<RecoveredAudioEvent> recover(
    MeetingRecord r, {
    required bool Function() isCurrent,
  }) async* {
    if (r.demo || r.ownerId == null || !isCurrent()) return;
    var timeline = Duration.zero;
    for (final path in r.audioPaths) {
      if (!isCurrent()) return;
      final length = await _length(path);
      final offset = timeline;
      timeline += Duration(microseconds: length * 1000000 ~/ 32000);
      final start = (await _cursor(r, path)).clamp(0, length);
      if (start >= length) continue;
      await for (final event in _replay(r.id, path, start, length, isCurrent)) {
        if (!isCurrent()) return;
        yield RecoveredAudioEvent(path, start, event, offset);
        // await-for 的消费者已完成持久化，之后才确认这段原话。
        final end = start + (event.audioEnd?.inMilliseconds ?? 0) * 32;
        if (event.isFinal && !event.isSpeakerUpdate && end > start) {
          await _saveCursor(path, end.clamp(start, length));
        }
      }
      if (isCurrent()) await _saveCursor(path, length);
    }
  }

  Stream<MeetingTranscript> _replay(
    String id,
    String path,
    int start,
    int length,
    bool Function() isCurrent,
  ) async* {
    final worker = recognizer(id);
    final events = StreamController<MeetingTranscript>();
    var failed = false;
    final subscription = worker.transcripts.listen(
      (e) {
        if ((e.isFinal || e.isSpeakerUpdate) && e.text.trim().isNotEmpty) {
          events.add(e);
        }
      },
      onError: (Object e, StackTrace st) {
        if (!failed) {
          failed = true;
          events.addError(e, st);
        }
      },
    );
    final producer = () async {
      RandomAccessFile? file;
      try {
        await worker.start();
        file = await File(path).open();
        await file.setPosition(44 + start);
        var cursor = start;
        while (cursor < length) {
          if (!isCurrent() || failed) throw StateError('补转写已暂停，游标保留');
          final bytes = await file.read((length - cursor).clamp(0, 3200));
          if (bytes.isEmpty) throw StateError('原始录音读取不完整');
          worker.accept(bytes);
          cursor += bytes.length;
          await Future<void>.delayed(frameDelay);
        }
        await worker.flush();
        if (failed) throw StateError('补转写未完成');
      } catch (e, st) {
        if (!failed) {
          failed = true;
          events.addError(e, st);
        }
      } finally {
        try {
          await file?.close();
          await subscription.cancel();
          await worker.close();
        } catch (e, st) {
          failed = true;
          events.addError(e, st);
        } finally {
          await events.close();
        }
      }
    }();
    try {
      yield* events.stream;
    } finally {
      await producer;
    }
    if (failed) throw StateError('补转写尚未完成');
  }
}
