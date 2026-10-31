import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import '../../core/network/api_client.dart';
import 'speech_recognizer.dart';
import 'transcript_highlight_models.dart';
import 'live_speaker_identity.dart';

/// 云端仅接收瞬时 PCM；手机仍独立保存原始录音。
class TencentSpeechWorker
    implements MeetingSpeechRecognizer, AbortableMeetingSpeechRecognizer {
  TencentSpeechWorker(this.api, this.sessionId);
  final ApiClient api;
  final String sessionId;
  final _events = StreamController<MeetingTranscript>.broadcast(sync: true);
  WebSocket? _socket;
  StreamSubscription<dynamic>? _subscription;
  Completer<void>? _ready, _done;
  String? _owner;
  String? _speakerScope;
  String? _identitySessionId;
  int _bytes = 0, _offsetMs = 0, _segmentBase = 0, _nextSegment = 0;
  bool _ending = false, _closed = false, _failed = false;
  @override
  Stream<MeetingTranscript> get transcripts => _events.stream;
  @override
  int get pendingMilliseconds => 0;

  @override
  Future<void> start() async {
    _owner ??= api.accountId?.call();
    if (_owner == null || _owner != api.accountId?.call()) {
      throw StateError('请先登录后使用实时转写');
    }
    if (_socket != null) return;
    await api.get(
      'meetings/asr/capabilities',
      authenticated: true,
      accountId: _owner,
    );
    final token = await api.accessToken?.call();
    if (token == null || _owner != api.accountId?.call()) {
      throw StateError('登录状态已改变');
    }
    final base = Uri.parse(
      api.dio.options.baseUrl,
    ).resolve('meetings/asr/stream');
    final uri = base.replace(
      scheme: base.scheme == 'https' ? 'wss' : 'ws',
      queryParameters: {'client_id': sessionId},
    );
    _ready = Completer<void>();
    unawaited(
      _ready!.future.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
    );
    _done = Completer<void>();
    _ending = false;
    _failed = false;
    _segmentBase = _nextSegment;
    _offsetMs = _bytes * 1000 ~/ 32000;
    try {
      _socket = await WebSocket.connect(
        uri.toString(),
        headers: {'Authorization': 'Bearer $token'},
      ).timeout(const Duration(seconds: 12));
      if (_closed || _owner != api.accountId?.call()) {
        await _disconnect();
        throw StateError('转写已取消');
      }
      _socket!.pingInterval = const Duration(seconds: 20);
      _subscription = _socket!.listen(
        _message,
        onError: (Object _) => _fail('实时转写连接中断，录音仍保存在手机'),
        onDone: () {
          if (!_ending || _done?.isCompleted != true) {
            _fail('实时转写连接已结束，正在自动恢复');
          }
        },
      );
      await _ready!.future.timeout(const Duration(seconds: 15));
    } catch (_) {
      await _disconnect();
      throw StateError('实时转写未能启动，请检查网络或服务额度');
    }
  }

  void _message(dynamic value) {
    if (_closed) return;
    try {
      final data = jsonDecode(value as String) as Map<String, dynamic>;
      switch (data['type']) {
        case 'transcript_highlights':
          // 独立注释通道的格式错误不触发 ASR 重连或中断录音。
          try {
            final text = data['text'] as String;
            final highlights = TranscriptHighlight.parse(
              text,
              data['highlights'],
            );
            final trace = data['trace_id'] as String;
            final revision = data['revision'] as String;
            if (highlights.isEmpty || _owner != api.accountId?.call()) return;
            final received = Stopwatch()..start();
            final socket = _socket;
            _events.add(
              MeetingTranscript(
                _segmentBase + (data['segment'] as int),
                text,
                isFinal: false,
                highlightBatch: TranscriptHighlightBatch(
                  text,
                  revision,
                  trace,
                  highlights,
                  onDisplayed: () {
                    if (!_closed &&
                        !_ending &&
                        socket != null &&
                        identical(socket, _socket) &&
                        _owner == api.accountId?.call()) {
                      try {
                        socket.add(
                          jsonEncode({
                            'type': 'highlight_displayed',
                            'trace_id': trace,
                            'render_ms': received.elapsedMicroseconds / 1000,
                          }),
                        );
                      } catch (_) {
                        /* 诊断 ACK 失败不改变转写状态。 */
                      }
                    }
                  },
                ),
              ),
            );
          } catch (_) {
            /* 保留原文，丢弃无效注释。 */
          }
        case 'ready':
          _speakerScope = data['speaker_scope'] as String?;
          _identitySessionId = data['identity_session_id'] as String?;
          if (_identitySessionId != null && _speakerScope != null) {
            _emitIdentity(
              LiveSpeakerIdentityEvent(
                sessionId: _identitySessionId!,
                scope: _speakerScope!,
                isSession: true,
                status: data['self_identification'] as String? ?? 'unavailable',
              ),
            );
          }
          if (_ready?.isCompleted == false) _ready!.complete();
        case 'speaker_identity_update':
        case 'speaker_identity_status':
          // 新旁路的无效事件独立丢弃，不能导致原有ASR连接失败。
          try {
            if (_owner != api.accountId?.call() ||
                _identitySessionId == null ||
                data['identity_session_id'] != _identitySessionId) {
              return;
            }
            if (data['type'] == 'speaker_identity_status') {
              _emitIdentity(
                LiveSpeakerIdentityEvent(
                  sessionId: _identitySessionId!,
                  scope: _speakerScope!,
                  status: data['self_identification'] as String,
                ),
              );
            } else {
              final speaker = data['speaker_id'];
              final revision = data['identity_revision'];
              if (data['speaker_scope'] != _speakerScope ||
                  speaker is! int ||
                  speaker < 0 ||
                  speaker > 9 ||
                  revision is! int ||
                  revision < 1 ||
                  !['self', 'other', 'unknown'].contains(data['identity'])) {
                return;
              }
              _emitIdentity(
                LiveSpeakerIdentityEvent(
                  sessionId: _identitySessionId!,
                  scope: _speakerScope!,
                  speakerId: 'asr:$_speakerScope:$speaker',
                  identity: data['identity'] as String,
                  revision: revision,
                  persisted: data['persisted'] == true,
                  meetingRevision: data['meeting_identity_revision'] is int
                      ? data['meeting_identity_revision'] as int
                      : 0,
                ),
              );
            }
          } catch (_) {
            /* 保留ABC和文字，忽略无效身份消息。 */
          }
        case 'speaker_update':
        case 'transcript':
          final id = _segmentBase + (data['segment'] as int);
          if (id >= _nextSegment) _nextSegment = id + 1;
          _events.add(
            MeetingTranscript(
              id,
              data['text'] as String,
              isFinal: data['is_final'] == true,
              isSpeakerUpdate: data['type'] == 'speaker_update',
              speakerRevision: (data['speaker_revision'] as int?) ?? 0,
              speakerId: data['speaker_id'] is int && _speakerScope != null
                  ? 'asr:$_speakerScope:${data['speaker_id']}'
                  : null,
              speakerSeparated:
                  data['speaker_id'] is int && _speakerScope != null,
              audioStart: Duration(
                milliseconds: _offsetMs + (data['start_ms'] as int),
              ),
              audioEnd: Duration(
                milliseconds: _offsetMs + (data['end_ms'] as int),
              ),
            ),
          );
        case 'done':
          if (_done?.isCompleted == false) _done!.complete();
          if (!_ending) _fail('实时转写连接提前结束，正在自动恢复');
        case 'error':
          _fail('实时转写服务不可用，请检查服务额度或稍后续录');
      }
    } catch (_) {
      _fail('实时转写返回格式异常');
    }
  }

  void _fail(String message) {
    if (_failed || _closed) return;
    _failed = true;
    _resetIdentity();
    final error = StateError(message);
    if (_ready?.isCompleted == false) {
      _ready!.completeError(error);
    } else {
      _events.addError(error);
    }
    if (_ending && _done?.isCompleted == false) _done!.completeError(error);
  }

  @override
  void accept(Uint8List bytes) {
    if (_failed || _ending || _socket == null || _closed) return;
    if (_owner != api.accountId?.call()) {
      _fail('账户已切换，已停止原账户转写');
      unawaited(_disconnect());
      return;
    }
    _socket!.add(bytes);
    _bytes += bytes.length;
  }

  @override
  Future<void> flush() async {
    if (_failed) {
      await _disconnect();
      throw StateError('转写连接中断，音频尚未完整确认');
    }
    if (_socket == null) return;
    try {
      if (!_failed) {
        _ending = true;
        _socket!.add('{"type":"end"}');
        await _done!.future.timeout(const Duration(seconds: 22));
      }
    } finally {
      await _disconnect();
    }
  }

  Future<void> _disconnect() async {
    _resetIdentity();
    final socket = _socket;
    _socket = null;
    await _subscription?.cancel();
    _subscription = null;
    await socket?.close();
  }

  void _emitIdentity(LiveSpeakerIdentityEvent event) {
    if (!_events.isClosed) {
      _events.add(
        MeetingTranscript(-1, '', isFinal: false, identityEvent: event),
      );
    }
  }

  void _resetIdentity() {
    if (_identitySessionId != null && _speakerScope != null) {
      _emitIdentity(
        LiveSpeakerIdentityEvent(
          sessionId: _identitySessionId!,
          scope: _speakerScope!,
          status: 'disconnected',
        ),
      );
    }
    _identitySessionId = null;
  }

  @override
  Future<void> abort() async {
    if (_closed) return;
    _closed = true;
    if (_ready?.isCompleted == false) {
      _ready!.completeError(StateError('转写已取消'));
    }
    if (_ending && _done?.isCompleted == false) {
      _done!.completeError(StateError('刷尾已取消'));
    }
    await _disconnect();
    await _events.close();
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    try {
      await flush();
    } finally {
      _closed = true;
      await _disconnect();
      await _events.close();
    }
  }
}
