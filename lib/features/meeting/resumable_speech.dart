import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'speech_recognizer.dart';

/// 从原始 WAV 读取已落盘采样。断网不停止麦克风、不堆积内存、不跳过缺口。
/// 供应商要求 1:1 速率，恢复期间允许有积压；最终刷尾超时则交给持久恢复队列。
class ResumableSpeechWorker implements MeetingSpeechRecognizer {
  ResumableSpeechWorker({
    required this.factory,
    required this.path,
    required this.committedBytes,
    this.frameDelay = const Duration(milliseconds: 100),
    this.retryDelay = const Duration(seconds: 2),
    this.flushTimeout = const Duration(seconds: 30),
    this.rotateAfterBytes = 32000 * 1800,
    this.unconfirmedWindowBytes = 32000 * 300,
  });
  final MeetingSpeechRecognizer Function() factory;
  final String path;
  final Future<int> Function() committedBytes;
  final Duration frameDelay, retryDelay, flushTimeout;
  final int rotateAfterBytes, unconfirmedWindowBytes;
  int get sentMilliseconds => _sent * 1000 ~/ 32000;
  final _events = StreamController<MeetingTranscript>.broadcast(sync: true);
  final _states = StreamController<String>.broadcast();
  Stream<String> get states => _states.stream;
  @override
  Stream<MeetingTranscript> get transcripts => _events.stream;
  MeetingSpeechRecognizer? _worker;
  Future<void>? _running;
  bool _closed = false, _stopping = false, _finishing = false;
  bool _recovering = false;
  int _sent = 0, _ack = 0, _available = 0, _serial = 0;
  int get backlogMilliseconds =>
      (_available - _sent).clamp(0, 1 << 40) * 1000 ~/ 32000;
  @override
  int get pendingMilliseconds =>
      (_available - _ack).clamp(0, 1 << 40) * 1000 ~/ 32000;

  void _status(bool pending) {
    if (_closed || pending == _recovering) return;
    _recovering = pending;
    _states.add(pending ? 'transcription_pending' : 'transcription_restored');
  }

  @override
  Future<void> start() async {
    if (_closed) throw StateError('识别器已关闭');
    if (_running != null) return;
    _stopping = false;
    _finishing = false;
    _available = await committedBytes();
    _running = _run();
  }

  // PCM 已由录音器写入唯一原始文件；这里只唤醒读取，不再保留第二份音频队列。
  @override
  void accept(Uint8List bytes) {}

  Future<void> _run() async {
    var failures = 0;
    while (!_stopping && !_closed) {
      final worker = factory();
      _worker = worker;
      var failed = false;
      var rotate = false;
      final base = _ack;
      _sent = base;
      final segments = <int, int>{};
      final finalEnds = <int, int>{};
      final subscription = worker.transcripts.listen(
        (e) {
          if (_stopping || _closed || failed || _worker != worker) return;
          // 身份是连接级展示消息，不分配转写片段号、不推进音频确认位置。
          if (e.identityEvent != null) {
            _events.add(e);
            return;
          }
          final start =
              Duration(microseconds: base * 1000000 ~/ 32000) +
              (e.audioStart ?? Duration.zero);
          final end =
              Duration(microseconds: base * 1000000 ~/ 32000) +
              (e.audioEnd ?? Duration.zero);
          final absoluteEnd = end.inMicroseconds * 32000 ~/ 1000000;
          if (!e.isSpeakerUpdate &&
              e.highlightBatch == null &&
              e.isFinal &&
              absoluteEnd <= base) {
            return;
          }
          final id = segments.putIfAbsent(e.segment, () => _serial++);
          if (e.isSpeakerUpdate && !finalEnds.containsKey(e.segment)) return;
          if (e.isFinal && !e.isSpeakerUpdate) {
            if (finalEnds.containsKey(e.segment)) return;
            if (absoluteEnd > _sent) {
              failed = true;
              _status(true);
              return;
            }
            finalEnds[e.segment] = absoluteEnd;
            if (absoluteEnd > _ack) _ack = absoluteEnd;
          }
          _events.add(
            MeetingTranscript(
              id,
              e.text,
              isFinal: e.isFinal,
              isSpeakerUpdate: e.isSpeakerUpdate,
              highlightBatch: e.highlightBatch,
              speakerId: e.speakerId,
              speakerSeparated: e.speakerSeparated,
              speakerRevision: e.speakerRevision,
              audioStart: start,
              audioEnd: end,
            ),
          );
        },
        onError: (Object _) {
          failed = true;
          _status(true);
        },
      );
      RandomAccessFile? reader;
      try {
        await worker.start();
        if (_stopping || _closed) break;
        reader = await File(path).open();
        await reader.setPosition(44 + base);
        final pace = Stopwatch()..start();
        while (!_stopping && !_closed && !failed) {
          _available = await committedBytes();
          if (_sent >= _available) {
            _status(false);
            failures = 0;
            if (_finishing) {
              await worker.flush();
              if (failed) throw StateError('刷尾未完成');
              _ack = _sent;
              return;
            }
            await Future<void>.delayed(const Duration(milliseconds: 20));
            continue;
          }
          final bytes = await reader.read((_available - _sent).clamp(0, 3200));
          if (bytes.isEmpty || bytes.length.isOdd) {
            throw FileSystemException('录音读取不完整');
          }
          // 先更新上界，以支持同步返回结果的可替换识别器。
          _sent += bytes.length;
          worker.accept(bytes);
          if (backlogMilliseconds > 2000) _status(true);
          final target = frameDelay * ((_sent - base) / 3200);
          final remaining = target - pace.elapsed;
          if (remaining > Duration.zero) await Future<void>.delayed(remaining);
          if ((_sent - base >= rotateAfterBytes ||
                  (_sent - _ack >= unconfirmedWindowBytes &&
                      _sent >= _available)) &&
              !_finishing &&
              !failed) {
            // 长会议自动换连接，刷尾时原录音仍继续落盘；用户不用暂停或发送。
            await worker.flush();
            if (failed) throw StateError('轮换刷尾未完成');
            _ack = _sent;
            rotate = true;
            break;
          }
        }
      } on FileSystemException catch (error, stack) {
        _events.addError(error, stack);
        _stopping = true;
      } catch (_) {
        failed = true;
        _status(true);
      } finally {
        await reader?.close();
        await subscription.cancel();
        try {
          await worker.close().timeout(const Duration(seconds: 3));
        } catch (_) {}
        if (_worker == worker) _worker = null;
      }
      if (_stopping || _closed) break;
      if (rotate) {
        failures = 0;
        continue;
      }
      failures++;
      _status(true);
      // 退避上限 16 秒，避免离线时不停创建计费连接。
      final delay = retryDelay * (1 << (failures - 1).clamp(0, 3));
      final until = DateTime.now().add(delay);
      while (!_stopping && !_closed && DateTime.now().isBefore(until)) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
  }

  @override
  Future<void> flush() async {
    final run = _running;
    if (run == null) return;
    _finishing = true;
    try {
      await run.timeout(flushTimeout);
      if (_stopping || _ack < await committedBytes()) {
        throw StateError('转写仍有待恢复音频');
      }
    } finally {
      _stopping = true;
      await _abort();
      // 运行仍可能处于连接超时中，结束前不能启动第二个发送循环。
      await run;
      _running = null;
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _stopping = true;
    await _abort();
    await _running;
    _running = null;
    _closed = true;
    await _events.close();
    await _states.close();
  }

  Future<void> _abort() async {
    final worker = _worker;
    try {
      if (worker is AbortableMeetingSpeechRecognizer) {
        await (worker as AbortableMeetingSpeechRecognizer).abort();
      } else {
        await worker?.close().timeout(const Duration(seconds: 3));
      }
    } catch (_) {
      /* 未确认的音频仍保留在原 WAV 中。 */
    }
  }
}
