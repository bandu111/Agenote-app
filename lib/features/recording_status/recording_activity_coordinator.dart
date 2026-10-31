import 'dart:async';
import 'package:flutter/foundation.dart';
import '../meeting/meeting_models.dart';
import '../meeting/meeting_services.dart';
import '../meeting/meeting_view_model.dart';
import '../profile/viewmodels/profile_view_model.dart';
import '../recording_device/recorder_device_view_model.dart';
import 'recording_status_snapshot.dart';
import 'system_recording_activity.dart';

/// Presentation adapter over the existing session. Never uses push messages as facts.
class RecordingActivityCoordinator extends ChangeNotifier {
  RecordingActivityCoordinator({
    required this.meeting,
    required this.profile,
    required this.device,
    this.platform = const NativeRecordingActivity(),
  }) {
    meeting.addListener(refresh);
    profile.addListener(refresh);
    device.addListener(refresh);
    refresh();
  }
  final MeetingViewModel meeting;
  final ProfileViewModel profile;
  final RecorderDeviceViewModel device;
  final SystemRecordingActivity platform;
  RecordingStatusSnapshot? snapshot;
  Map<String, dynamic> systemState = {};
  String? platformError;
  bool _disposed = false, _running = false, _queued = false;
  String? _sent, _observedFingerprint;
  Timer? _retryTimer;
  Timer? _requestTimer;
  Completer<Map<String, dynamic>>? _request;
  int _retryCount = 0;
  DateTime? _lastSent;
  int _sequence = DateTime.now().microsecondsSinceEpoch;
  Future<void> settled = Future.value();
  void refresh() {
    if (_disposed) return;
    final r = meeting.record;
    final recorder = meeting.recorder;
    final input = recorder is DeviceMeetingRecorder ? recorder : null;
    final eligible =
        profile.ready &&
        profile.data.sessionActive &&
        r?.demo == false &&
        (r?.ownerId == null || r?.ownerId == profile.data.accountId) &&
        meeting.active &&
        (meeting.nativeRecordingActive || input?.inputLost == true);
    if (!eligible) {
      snapshot = null;
    } else {
      final lost = input?.inputLost == true;
      final capturing =
          !lost &&
          (input?.captureConfirmed ??
              (meeting.nativeRecordingActive &&
                  meeting.phase == MeetingPhase.recording));
      final route = input?.inputRoute;
      final source =
          (input?.usingExternalInput == true || route?.type == 'recordingCard')
          ? 'aiVoice'
          : route?.type == 'bluetooth'
          ? 'headset'
          : route?.type == 'usb'
          ? 'usb'
          : route?.type == 'wired'
          ? 'wired'
          : route?.type == 'unknown'
          ? 'external'
          : 'phone';
      final details = <String, String>{
        if (route?.verified == true &&
            route!.sampleRate > 0 &&
            route.channels > 0)
          'audio': '${route.sampleRate} Hz · ${route.channels} 声道',
        if (source == 'aiVoice' && device.connected && !lost) ...{
          if (device.info.battery != null) 'battery': '${device.info.battery}%',
          if (device.info.usedKb != null && device.info.totalKb != null)
            'storage':
                '${(device.info.usedKb! / 1048576).toStringAsFixed(1)} / ${(device.info.totalKb! / 1048576).toStringAsFixed(1)} GB',
          if (device.info.firmware != null) 'firmware': device.info.firmware!,
        },
      };
      snapshot = RecordingStatusSnapshot(
        meetingId: r!.id,
        source: source,
        sourceLabel: source == 'aiVoice'
            ? device.savedFor(device.selected?.id ?? '')?.displayName ??
                  'AI Voice'
            : source == 'headset'
            ? route?.name.isNotEmpty == true
                  ? '耳机麦克风 · ${route!.name}'
                  : '耳机麦克风'
            : source == 'phone'
            ? '手机麦克风'
            : '${source == 'usb'
                  ? 'USB 麦克风'
                  : source == 'wired'
                  ? '有线耳机麦克风'
                  : '音频输入'}${route?.name.isNotEmpty == true ? ' · ${route!.name}' : ''}',
        capturing: capturing,
        connected: source == 'aiVoice' ? device.connected && !lost : !lost,
        state: input?.captureStopping == true
            ? 'processing'
            : lost
            ? 'interrupted'
            : capturing
            ? 'recording'
            : meeting.phase == MeetingPhase.paused
            ? 'paused'
            : 'unknown',
        transcription: input?.captureStopping == true
            ? 'processing'
            : input?.transcriptionPending == true || lost
            ? 'interrupted'
            : capturing
            ? 'transcribing'
            : 'off',
        elapsed: meeting.elapsed,
        startedAt: input?.captureConfirmedAt ?? r.startedAt,
        details: details,
      );
    }
    final observed = snapshot?.fingerprint ?? 'idle';
    if (observed != _observedFingerprint) {
      _observedFingerprint = observed;
      _retryCount = 0;
      _retryTimer?.cancel();
    }
    notifyListeners();
    _schedule();
  }

  void reconcile() {
    _sent = null;
    _schedule();
  }

  void _schedule() {
    _queued = true;
    if (!_running) {
      settled = _flush();
    }
  }

  Future<void> _flush() async {
    _running = true;
    while (_queued && !_disposed) {
      _queued = false;
      final value = snapshot, fingerprint = snapshot?.fingerprint ?? 'idle';
      final heartbeat =
          value != null &&
          (_lastSent == null ||
              DateTime.now().difference(_lastSent!).inSeconds >= 60);
      if (_sent == fingerprint && !heartbeat) continue;
      try {
        final result = await _send(value?.payload(++_sequence));
        if (_disposed) break;
        systemState = result;
        platformError = null;
        _retryTimer?.cancel();
        _retryCount = 0;
        _sent = fingerprint;
        _lastSent = DateTime.now();
      } catch (_) {
        if (_disposed) break;
        platformError = '系统录音状态展示暂不可用，录音继续';
        // No retry storm on each waveform/clock event; retry on state change/resume/heartbeat.
        _sent = fingerprint;
        _lastSent = DateTime.now();
        if (_retryCount < 2) {
          _retryCount++;
          _retryTimer?.cancel();
          _retryTimer = Timer(const Duration(seconds: 5), () {
            if (!_disposed) reconcile();
          });
        }
      }
    }
    _running = false;
  }

  Future<Map<String, dynamic>> _send(Map<String, dynamic>? value) {
    final request = Completer<Map<String, dynamic>>();
    _request = request;
    _requestTimer = Timer(const Duration(seconds: 5), () {
      if (!request.isCompleted) {
        request.completeError(TimeoutException('recording status'));
      }
    });
    Future.sync(() => platform.synchronize(value)).then(
      (result) {
        if (!request.isCompleted) {
          _requestTimer?.cancel();
          request.complete(result);
        }
      },
      onError: (Object error, StackTrace trace) {
        if (!request.isCompleted) {
          _requestTimer?.cancel();
          request.completeError(error, trace);
        }
      },
    );
    return request.future;
  }

  @override
  void dispose() {
    _disposed = true;
    _retryTimer?.cancel();
    _requestTimer?.cancel();
    if (_request?.isCompleted == false) _request!.complete({});
    meeting.removeListener(refresh);
    profile.removeListener(refresh);
    device.removeListener(refresh);
    super.dispose();
  }
}
