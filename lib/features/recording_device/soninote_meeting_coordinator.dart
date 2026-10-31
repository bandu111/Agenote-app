import 'dart:async';
import 'package:flutter/foundation.dart';
import '../meeting/meeting_models.dart';
import '../meeting/meeting_services.dart';
import '../meeting/meeting_view_model.dart';
import 'recorder_device_view_model.dart';
import 'recorder_models.dart';
import 'soninote_pcm_input.dart';

/// A user start (App or physical key) opens exactly one real meeting. State
/// queries/reconnection never create a second meeting or silently change input.
class SoniNoteMeetingCoordinator extends ChangeNotifier {
  SoniNoteMeetingCoordinator({
    required this.device,
    required this.meeting,
    required this.openMeeting,
    required this.sessionActive,
  }) {
    device.meetingUsesDevice = () =>
        _ownsMeeting && (meeting.active || meeting.busy);
    _subscription = device.service.events.listen(_event);
    meeting.addListener(_meetingChanged);
  }
  final RecorderDeviceViewModel device;
  final MeetingViewModel meeting;
  final void Function() openMeeting;
  final bool Function() sessionActive;
  StreamSubscription<RecorderEvent>? _subscription;
  SoniNotePcmInput? _input;
  bool busy = false, _disposed = false, _ownsMeeting = false;
  bool _physicalStartRequested = false;
  String? error;
  void _meetingChanged() {
    if (!meeting.active && !meeting.busy) _ownsMeeting = false;
    _markSource();
    device.notifyMeetingUsageChanged();
  }

  String? _sourceName;
  void _markSource() {
    final source = meeting.record;
    final name = _sourceName;
    if (!_ownsMeeting ||
        source == null ||
        source.ended ||
        name == null ||
        source.recordingCardFileName == name) {
      return;
    }
    final identity = '${device.platform}:${device.selected?.id}';
    meeting.record = source.copy(
      recordingCardFileName: name,
      recordingCardIdentity: identity,
    );
    unawaited(meeting.store.save(meeting.record!).catchError((Object _) {}));
  }

  void _notify() {
    _markSource();
    device.notifyMeetingUsageChanged();
    if (!_disposed) notifyListeners();
  }

  void _event(RecorderEvent event) {
    if (_disposed ||
        event.epoch != device.connectionEpoch ||
        event.deviceId != device.selected?.id) {
      return;
    }
    if (event.type == 'button' && event.data['button'] == '1') {
      _physicalStartRequested = true;
    }
    if (event.type != 'recording' || event.data['query'] == true) return;
    final fileName = event.data['fileName'];
    if (fileName is String && fileName.isNotEmpty) {
      _sourceName = fileName;
      _markSource();
    }
    if (event.data['state'] == 'recording' && _physicalStartRequested) {
      _physicalStartRequested = false;
      if (_ownsMeeting && (meeting.active || meeting.busy)) {
        if (meeting.phase == MeetingPhase.paused && !meeting.busy) {
          unawaited(meeting.resume());
        }
        return;
      }
      unawaited(
        startMeeting(
          sourceFileName: fileName is String && fileName.isNotEmpty
              ? fileName
              : null,
        ),
      );
    } else if (_ownsMeeting &&
        event.data['state'] == 'recording' &&
        meeting.phase == MeetingPhase.paused &&
        !meeting.busy) {
      unawaited(meeting.resume());
    } else if (_ownsMeeting &&
        event.data['state'] == 'idle' &&
        event.data['saved'] == true &&
        meeting.record?.ended != true &&
        !meeting.busy) {
      _physicalStartRequested = false;
      unawaited(meeting.finish());
    }
  }

  Future<void> startMeeting({
    bool openPage = true,
    String? sourceFileName,
  }) async {
    if (_disposed || busy) return;
    error = null;
    if (!sessionActive()) {
      error = '请登录后开始录音卡会议';
      _notify();
      return;
    }
    if (!device.connected) {
      error = '请先连接录音卡';
      _notify();
      return;
    }
    if (device.identityMismatch) {
      error = '设备身份尚未核对，请重新连接录音卡';
      _notify();
      return;
    }
    if (meeting.active || meeting.busy) {
      if (_ownsMeeting) {
        if (openPage) openMeeting();
        return;
      }
      error = '已有会议正在进行，请先结束当前会议';
      _notify();
      return;
    }
    final recorder = meeting.recorder;
    if (recorder is! DeviceMeetingRecorder) {
      error = '当前录音器不支持录音卡输入';
      _notify();
      return;
    }
    busy = true;
    _notify();
    try {
      _input ??= SoniNotePcmInput(device);
      recorder.externalInput = _input;
      _ownsMeeting = true;
      _sourceName = sourceFileName;
      // Own capture here; navigation only opens the same session.
      final starting = meeting.start(demo: false);
      if (openPage) openMeeting();
      await starting;
      if (!meeting.active) {
        _ownsMeeting = false;
        error = meeting.error;
      }
    } catch (e) {
      _ownsMeeting = false;
      error = e is StateError ? e.message.toString() : '录音卡会议启动失败，请重试';
    } finally {
      if (!meeting.active) recorder.externalInput = null;
      busy = false;
      _notify();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    device.meetingUsesDevice = null;
    meeting.removeListener(_meetingChanged);
    unawaited(_subscription?.cancel());
    unawaited(_input?.dispose().catchError((Object _) {}));
    super.dispose();
  }
}
