import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:io';
import 'dart:typed_data';
import 'local_speech.dart';
export 'local_speech.dart' show MeetingTranscript;
import 'package:record/record.dart';
import 'package:path_provider/path_provider.dart';
import 'package:add_2_calendar/add_2_calendar.dart';
import 'meeting_models.dart';
import 'audio_input_route.dart';
import 'pcm_audio.dart';
import 'speech_engine.dart';
import 'speech_recognizer.dart';
import 'tencent_speech.dart';
import 'recording_background.dart';
import 'resumable_speech.dart';
import 'meeting_audio_recovery.dart';
import 'meeting_pcm_input.dart';

abstract interface class MeetingRecorder {
  Stream<double> get levels;
  Stream<MeetingTranscript> get transcripts;
  Stream<String> get states;
  Future<String> start(String sessionId);
  Future<void> pause();
  Future<void> resume();
  Future<void> stop();
  Future<void> dispose();
}

abstract interface class BackgroundRecordingStatus {
  bool get backgroundActive;
}

enum MeetingInputPreference { automatic, phone, bluetooth }

class DeviceMeetingRecorder
    implements MeetingRecorder, BackgroundRecordingStatus {
  DeviceMeetingRecorder({
    this.directory,
    this.recognizerFactory,
    this.requireBluetooth = false,
    this.speechModel = MeetingSpeechModel.chinese,
    this.recoverNetwork = false,
  });
  final MeetingSpeechRecognizer Function(String sessionId)? recognizerFactory;
  final MeetingSpeechModel speechModel;
  final Directory? directory;
  final bool requireBluetooth;
  final bool recoverNetwork;
  MeetingPcmInput? externalInput;
  MeetingPcmInput? _activeInput;
  MeetingPcmInput? _lastExternalInput;
  StreamSubscription<String>? _externalStates;
  bool get usingExternalInput => _activeInput != null;
  StreamSubscription<String>? _recoveryStates;
  final _background = RecordingBackground();
  @override
  bool backgroundActive = false;
  bool _needsRecovery = false, _speechFlushed = false;
  Timer? _checkpointTimer;
  bool get transcriptionPending => _needsRecovery;
  int get transcriptionBacklogMilliseconds => _speech is ResumableSpeechWorker
      ? (_bytes * 1000 ~/ 32000 -
                (_speech as ResumableSpeechWorker).sentMilliseconds)
            .clamp(0, 1 << 40)
      : 0;
  final _inputMonitor = DeviceAudioInputMonitor();
  AudioInputRoute? inputRoute;
  AudioInputRoute? _capturedInput;
  String? _capturePath;
  bool _routeLost = false;
  bool get inputLost => _routeLost;
  bool captureStopping = false;
  bool get captureConfirmed =>
      _live && _accepting && !_paused && !_routeLost && !captureStopping;
  DateTime? captureConfirmedAt;
  InputDevice? selectedInput;
  MeetingInputPreference inputPreference = MeetingInputPreference.automatic;
  Future<List<InputDevice>> availableInputs() => device.listInputDevices();
  MeetingPcmBuffer _buffer = MeetingPcmBuffer();
  Map<String, Object?> get diagnostics => {
    ..._buffer.diagnostics,
    'selectedInput': selectedInput?.toMap(),
    'actualInput': inputRoute?.toMap(),
    'capturedInput': _capturedInput?.toMap(),
    'routeLost': _routeLost,
    'recognizerPendingMs': _speech?.pendingMilliseconds ?? 0,
  };
  StreamSubscription<AudioInputRoute>? _inputChanges;
  StreamSubscription<RecordState>? _deviceStates;
  final _states = StreamController<String>.broadcast();
  bool _accepting = false, _paused = false, _usedBluetooth = false;
  String? _lastSession;
  Future<void>? _inputStopping;
  Future<void>? _stopping;
  bool _disposed = false;
  AudioRecorder? _device;
  AudioRecorder get device => _device ??= AudioRecorder();
  MeetingSpeechRecognizer? _speech;
  StreamSubscription<Uint8List>? _pcm;
  StreamSubscription<MeetingTranscript>? _text;
  final _transcripts = StreamController<MeetingTranscript>.broadcast(
    sync: true,
  );
  final _levels = StreamController<double>.broadcast();
  RandomAccessFile? _file;
  Future<void> _writes = Future.value();
  int _bytes = 0;
  String? get questionAudioPart => _capturePath?.split(RegExp(r'[/\\]')).last;
  int get questionAudioSample => _buffer.samples;
  int persistenceRevision = 0;
  bool _live = false;
  Completer<void>? _pcmDone;
  @override
  Stream<MeetingTranscript> get transcripts => _transcripts.stream;
  @override
  Stream<double> get levels => _levels.stream;
  @override
  Stream<String> get states => _states.stream;
  @override
  Future<String> start(String sessionId) async {
    await _inputStopping;
    await _stopping;
    if (_disposed) throw StateError('录音器已关闭');
    if (_live) throw StateError('录音已在进行中');
    captureStopping = false;
    captureConfirmedAt = null;
    _activeInput =
        externalInput ??
        (sessionId == _lastSession ? _lastExternalInput : null);
    _lastExternalInput = _activeInput;
    if (_activeInput == null && !await device.hasPermission()) {
      throw StateError('麦克风权限未允许，请在系统设置中开启');
    }
    if (_activeInput == null) {
      _deviceStates ??= device.onStateChanged().listen(
        (state) => _states.add(state.name),
      );
      final inputs = await device.listInputDevices();
      selectedInput = selectMeetingInput(inputs, preference: inputPreference);
      if (inputPreference != MeetingInputPreference.automatic &&
          selectedInput == null) {
        throw StateError('所选麦克风暂不可用，请检查连接后重新选择音源');
      }
      final bluetooth =
          selectedInput?.type == InputDeviceType.bluetoothSco ||
          selectedInput?.type == InputDeviceType.bluetoothLe;
      if ((requireBluetooth || _lastSession == sessionId && _usedBluetooth) &&
          !bluetooth) {
        throw StateError('耳机麦克风未连接，请连接耳机并开启通话音频后继续');
      }
      _lastSession = sessionId;
      _usedBluetooth = bluetooth;
    }
    _lastSession = sessionId;
    _accepting = false;
    _paused = false;
    _buffer = MeetingPcmBuffer();
    _routeLost = false;
    final root = directory ?? await getApplicationSupportDirectory();
    await root.create(recursive: true);
    final path =
        '${root.path}/meeting-$sessionId-${DateTime.now().microsecondsSinceEpoch}.wav';
    _capturePath = path;
    try {
      _file = await File(path).open(mode: FileMode.write);
      await _file!.writeFrom(meetingWavHeader(0));
      _bytes = 0;
      _writes = Future.value();
      // Subscribe to the recording card before network/ASR startup. Its bounded
      // startup buffer retains speech while the authenticated socket opens.
      final externalStream = await _activeInput?.start();
      _externalStates = _activeInput?.states.listen((state) {
        if (state == 'input_lost') {
          if (_routeLost) return;
          _accepting = false;
          _routeLost = true;
          if (_live) _inputStopping = _stopAfterInputLoss();
        } else {
          _states.add(state);
        }
      });
      _speech = recoverNetwork && recognizerFactory != null
          ? ResumableSpeechWorker(
              factory: () => recognizerFactory!(sessionId),
              path: path,
              committedBytes: () async {
                await _writes;
                return _bytes;
              },
            )
          : recognizerFactory?.call(sessionId) ??
                LocalSpeechWorker(model: speechModel);
      if (_speech is ResumableSpeechWorker) {
        _recoveryStates = (_speech as ResumableSpeechWorker).states.listen((
          state,
        ) {
          _needsRecovery = state == 'transcription_pending';
          _states.add(state);
        });
      }
      try {
        await _speech!.start();
        _needsRecovery = false;
      } catch (_) {
        if (_speech is! TencentSpeechWorker) rethrow;
        // 网络不能成为本地采音的前置条件；音频落盘后补转写。
        _needsRecovery = true;
      }
      _text = _speech!.transcripts.listen(
        (event) {
          if (event.isFinal || event.isSpeakerUpdate) persistenceRevision++;
          _transcripts.add(event);
        },
        onError: (Object e) {
          if (_speech is TencentSpeechWorker) {
            _needsRecovery = true;
            _states.add('transcription_pending');
          } else {
            _transcripts.addError(e);
          }
        },
      );
      if (_routeLost) throw StateError('录音卡音频已中断，请重新连接');
      await _background.start(externalDevice: _activeInput != null);
      backgroundActive = true;
      _speechFlushed = false;
      final stream =
          externalStream ??
          await device.startStream(
            RecordConfig(
              encoder: AudioEncoder.pcm16bits,
              sampleRate: 16000,
              numChannels: 1,
              device: selectedInput,
              streamBufferSize: 3200,
              androidConfig: AndroidRecordConfig(
                manageBluetooth:
                    inputPreference != MeetingInputPreference.phone,
                audioManagerMode: _usedBluetooth
                    ? AudioManagerMode.modeInCommunication
                    : AudioManagerMode.modeNormal,
              ),
              // 只允许带麦克风的蓝牙通话路由；A2DP是播放，不是耳机采音。
              iosConfig: IosRecordConfig(
                categoryOptions: [
                  if (inputPreference != MeetingInputPreference.phone)
                    IosAudioCategoryOption.allowBluetooth,
                  IosAudioCategoryOption.defaultToSpeaker,
                ],
              ),
            ),
          );
      _live = true;
      _pcmDone = Completer<void>();
      if (_activeInput != null) _accepting = true;
      _pcm = stream.listen(
        (chunk) {
          if (!_accepting) return;
          for (final frame in _buffer.add(chunk)) {
            _consume(frame);
          }
        },
        onError: (Object e) {
          _transcripts.addError(e);
          if (_activeInput != null && !_routeLost) {
            _accepting = false;
            _routeLost = true;
            _inputStopping = _stopAfterInputLoss();
          }
        },
        onDone: () {
          if (_pcmDone?.isCompleted == false) _pcmDone!.complete();
        },
      );
      await _verifyInput(bluetooth: _usedBluetooth);
      captureConfirmedAt = DateTime.now();
      _accepting = true;
      _checkpointTimer = Timer.periodic(const Duration(seconds: 5), (_) {
        unawaited(
          _checkpoint().catchError(
            (Object error) => _transcripts.addError(error),
          ),
        );
      });
      if (_activeInput == null) {
        _inputChanges = _inputMonitor.changes.listen(
          (route) {
            inputRoute = route;
            if (!_accepting || _paused || !_live) return;
            _states.add('input_route');
            if (!route.verified ||
                route.silenced ||
                _usedBluetooth && !route.bluetooth ||
                inputPreference == MeetingInputPreference.phone &&
                    route.type != 'builtIn') {
              // 立即停止接纳路由切换后的采样；不能悄悄切回手机麦克风。
              _accepting = false;
              _routeLost = true;
              _inputStopping = _stopAfterInputLoss();
            }
          },
          onError: (Object error) {
            _transcripts.addError(error);
          },
        );
      }
      return path;
    } catch (_) {
      _checkpointTimer?.cancel();
      await _background.stop();
      backgroundActive = false;
      if (_activeInput != null) {
        try {
          await _activeInput!.stop();
        } catch (_) {
          /* Close remaining startup resources below. */
        }
      } else {
        await _device?.stop();
      }
      await _externalStates?.cancel();
      _externalStates = null;
      _activeInput = externalInput = null;
      await _inputChanges?.cancel();
      _inputChanges = null;
      await _pcm?.cancel();
      await _text?.cancel();
      await _recoveryStates?.cancel();
      await _speech?.close();
      _speech = null;
      await _file?.close();
      _file = null;
      _live = false;
      _accepting = false;
      rethrow;
    }
  }

  Future<void> _verifyInput({required bool bluetooth}) async {
    if (_activeInput != null) {
      inputRoute = _capturedInput = _activeInput!.route;
      if (!inputRoute!.verified) throw StateError('未收到录音卡的有效音频');
      return;
    }
    for (var i = 0; i < 20; i++) {
      final route = await _inputMonitor.snapshot();
      inputRoute = route;
      if (route.verified &&
          !route.silenced &&
          (!bluetooth || route.bluetooth) &&
          (inputPreference != MeetingInputPreference.phone ||
              route.type == 'builtIn')) {
        if (Platform.isAndroid &&
            (route.sampleRate != 16000 || route.channels != 1)) {
          throw StateError('录音采样格式不匹配，请重新连接输入设备');
        }
        _capturedInput = route;
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    throw StateError(
      bluetooth ? '未能启用耳机麦克风，请检查通话音频后重试' : '未能核实麦克风采音，请检查系统录音权限',
    );
  }

  void _consume(Uint8List copy) {
    if (copy.isEmpty) return;
    _speechFlushed = false;
    _writes = _writes.then((_) async {
      await _file!.writeFrom(copy);
      _bytes += copy.length;
    });
    unawaited(_writes.catchError((Object e) => _transcripts.addError(e)));
    if (!_needsRecovery || _speech is ResumableSpeechWorker) {
      _speech?.accept(copy);
    }
    final view = ByteData.sublistView(copy);
    var squares = 0.0;
    for (var i = 0; i < copy.length; i += 2) {
      final value = view.getInt16(i, Endian.little) / 32768;
      squares += value * value;
    }
    _levels.add(sqrt(squares / (copy.length / 2)).clamp(0, 1));
  }

  Future<void> _stopAfterInputLoss() async {
    try {
      await stop();
    } catch (error) {
      _transcripts.addError(error);
    } finally {
      if (!_disposed) _states.add('input_lost');
    }
  }

  Future<void> _checkpoint() async {
    // 与 PCM 写入共用串行队列，避免刷新 WAV 头时新采样写错位置。
    final operation = _writes.then((_) async {
      if (_file == null) return;
      await _file!.setPosition(0);
      await _file!.writeFrom(meetingWavHeader(_bytes));
      await _file!.setPosition(_bytes + 44);
      await _file!.flush();
      if (_capturePath != null) {
        await File('$_capturePath.capture.json').writeAsString(
          jsonEncode({'schema': 1, ...diagnostics, 'asrCompleteBytes': 0}),
          flush: true,
        );
      }
    });
    _writes = operation;
    await operation;
  }

  Future<void> confirmPersisted(MeetingRecord saved, int revision) async {
    final path = _capturePath;
    if (path != null &&
        saved.audioPaths.contains(path) &&
        revision == persistenceRevision &&
        _speechFlushed &&
        !_needsRecovery) {
      await saveAsrCursor(path, _bytes);
    }
  }

  @override
  Future<void> pause() async {
    _paused = true;
    if (_activeInput != null) {
      await _activeInput!.pause();
    } else {
      await device.pause();
    }
    await Future<void>.delayed(Duration.zero);
    _accepting = false;
    _consume(_buffer.finish());
    try {
      await _speech?.flush();
      _speechFlushed = true;
    } catch (_) {
      if (_speech is! TencentSpeechWorker &&
          _speech is! ResumableSpeechWorker) {
        rethrow;
      }
      _needsRecovery = true;
    } finally {
      try {
        await _checkpoint();
      } finally {
        await _background.stop();
        backgroundActive = false;
      }
    }
  }

  @override
  Future<void> resume() async {
    if (recognizerFactory != null &&
        (!_needsRecovery || _speech is ResumableSpeechWorker)) {
      try {
        await _speech?.start();
      } catch (_) {
        if (_speech is! TencentSpeechWorker &&
            _speech is! ResumableSpeechWorker) {
          rethrow;
        }
        _needsRecovery = true;
      }
    }
    await _background.start(externalDevice: _activeInput != null);
    backgroundActive = true;
    if (_activeInput != null) {
      await _activeInput!.resume();
    } else {
      await device.resume();
    }
    try {
      await _verifyInput(bluetooth: _usedBluetooth);
      _paused = false;
      _accepting = true;
    } catch (_) {
      if (_activeInput != null) {
        await _activeInput!.pause();
      } else {
        await device.pause();
      }
      await _background.stop();
      backgroundActive = false;
      rethrow;
    }
  }

  @override
  Future<void> stop() =>
      _stopping ??= _stop().whenComplete(() => _stopping = null);

  Future<void> _stop() async {
    if (!_live) return;
    _checkpointTimer?.cancel();
    await _inputChanges?.cancel();
    _inputChanges = null;
    await _externalStates?.cancel();
    _externalStates = null;
    Object? stopError;
    StackTrace? stopTrace;
    if (_activeInput != null) {
      try {
        await _activeInput!.stop();
      } catch (e, trace) {
        stopError = e;
        stopTrace = trace;
      }
    } else {
      await device.stop();
    }
    if (stopError == null) {
      captureStopping = true;
      _states.add('capture_stopped');
    }
    // 先等待原生采样流的尾部，再关闭识别器，保留结束前最后一句。
    await _pcmDone?.future.timeout(
      const Duration(seconds: 2),
      onTimeout: () {},
    );
    await _pcm?.cancel();
    _pcm = null;
    _accepting = false;
    try {
      _consume(_buffer.finish());
      try {
        await _speech?.flush();
        _speechFlushed = true;
      } catch (_) {
        if (_speech is! TencentSpeechWorker &&
            _speech is! ResumableSpeechWorker) {
          rethrow;
        }
        _needsRecovery = true;
      } finally {
        await _checkpoint();
      }
    } finally {
      try {
        await _text?.cancel();
        _text = null;
        await _recoveryStates?.cancel();
        _recoveryStates = null;
      } finally {
        try {
          await _speech?.close();
          _speech = null;
        } finally {
          try {
            await _file?.close();
          } finally {
            _file = null;
            _live = false;
            _activeInput = externalInput = null;
            await _background.stop();
            backgroundActive = false;
          }
        }
      }
    }
    if (stopError != null) Error.throwWithStackTrace(stopError, stopTrace!);
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    try {
      await stop();
    } finally {
      await _device?.dispose();
      await _deviceStates?.cancel();
      await _states.close();
      await _transcripts.close();
      await _levels.close();
    }
  }
}

/// 输入设备可替换，ASR、原始证据和会议协议不依赖耳机型号。
InputDevice? selectMeetingInput(
  List<InputDevice> inputs, {
  MeetingInputPreference preference = MeetingInputPreference.automatic,
}) {
  if (preference != MeetingInputPreference.automatic) {
    for (final input in inputs) {
      if (preference == MeetingInputPreference.phone
          ? input.type == InputDeviceType.builtIn
          : input.type == InputDeviceType.bluetoothSco ||
                input.type == InputDeviceType.bluetoothLe) {
        return input;
      }
    }
    return null;
  }
  for (final type in [
    InputDeviceType.bluetoothLe,
    InputDeviceType.bluetoothSco,
    InputDeviceType.usb,
    InputDeviceType.wiredHeadset,
    InputDeviceType.builtIn,
  ]) {
    for (final input in inputs) {
      if (input.type == type) return input;
    }
  }
  return null;
}

abstract interface class MeetingCalendar {
  Future<bool> openEditor(String title, DateTime startsAt);
}

class DeviceMeetingCalendar implements MeetingCalendar {
  @override
  Future<bool> openEditor(String title, DateTime startsAt) =>
      Add2Calendar.addEvent2Cal(
        Event(
          title: title,
          startDate: startsAt,
          endDate: startsAt.add(const Duration(hours: 1)),
          description: '来自言枢会议。请核对时间后保存。',
        ),
      );
}

/// Backend contract: final/partial ASR text and insight events are separate from raw audio.
abstract interface class MeetingAnalysisService {
  Future<List<MeetingInsight>> analyze(List<MeetingUtterance> utterances);
}

/// Deterministic sample workers; not a remote AI or claims about real participants.
class DemoMeetingAnalysis implements MeetingAnalysisService {
  @override
  Future<List<MeetingInsight>> analyze(
    List<MeetingUtterance> utterances,
  ) async {
    final ids = utterances.map((u) => u.id).toSet();
    final batches = await Future.wait([
      Future(
        () => [
          if (ids.contains('demo-1'))
            const MeetingInsight(
              id: 'clarify',
              kind: InsightKind.question,
              title: '范围待补全',
              body: 'Windows 是否纳入一期？需要明确预算与验收范围。',
              evidenceIds: ['demo-1', 'demo-2'],
            ),
        ],
      ),
      Future(
        () => [
          if (ids.contains('demo-3'))
            const MeetingInsight(
              id: 'risk',
              kind: InsightKind.risk,
              title: '范围与工期可能冲突',
              body: '新增桌面端，同时保持 30 天，尚无明确可行性结论。',
              evidenceIds: ['demo-1', 'demo-3'],
            ),
        ],
      ),
      Future(
        () => [
          if (ids.contains('demo-3'))
            const MeetingInsight(
              id: 'branch',
              kind: InsightKind.prediction,
              title: '接下来可能讨论验收标准',
              body: '推演分支：保留双端先交付；桌面端分期；整体调整排期。建议先确认范围，不把“评估一下”视为同意。',
              evidenceIds: ['demo-1', 'demo-2', 'demo-3'],
            ),
        ],
      ),
      Future(
        () => [
          if (ids.contains('demo-5'))
            const MeetingInsight(
              id: 'stitch',
              kind: InsightKind.stitch,
              title: '跨片段补齐交付范围',
              body: '推测补齐：前文暂未明确的桌面端需求，可能与后文“第二期再说”指同一事项。请核对，不能作为已确认结论。',
              evidenceIds: ['demo-1', 'demo-5'],
            ),
        ],
      ),
    ]);
    return batches
        .expand((batch) => batch)
        .where((i) => i.evidenceIds.every(ids.contains))
        .toList();
  }
}

/// Only explicit, unambiguous future dates become calendar proposals.
DateTime? explicitMeetingDate(String text, DateTime now) {
  final match = RegExp(
    r'(\d{4})[-/年](\d{1,2})[-/月](\d{1,2})日?\s*(\d{1,2})[:：点](\d{2})?',
  ).firstMatch(text);
  if (match == null) return null;
  final year = int.parse(match[1]!),
      month = int.parse(match[2]!),
      day = int.parse(match[3]!);
  final hour = int.parse(match[4]!), minute = int.tryParse(match[5] ?? '') ?? 0;
  final date = DateTime(year, month, day, hour, minute);
  if (date.year != year ||
      date.month != month ||
      date.day != day ||
      hour > 23 ||
      minute > 59 ||
      !date.isAfter(now)) {
    return null;
  }
  return date;
}
