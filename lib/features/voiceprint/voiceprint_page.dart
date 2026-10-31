import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:record/record.dart';
import 'package:permission_handler/permission_handler.dart';
import '../../shared/widgets/content_skeleton.dart';
import '../../core/network/api_config.dart';
import 'voiceprint_capture.dart';
import 'voiceprint_repository.dart';

part 'voiceprint_views.dart';

enum _VoiceStage { home, prepare, record, verify, success }

/// Account-bound registration only. No meeting/ASR is started and audio never
/// enters meeting storage or the knowledge library.
class VoiceprintPage extends StatefulWidget {
  const VoiceprintPage({
    super.key,
    required this.repository,
    required this.isMeetingRecording,
    this.capture,
    this.requestMicrophonePermission,
  });
  final VoiceprintRepository repository;
  final bool Function() isMeetingRecording;
  final VoiceprintCapture? capture;
  final Future<PermissionStatus> Function()? requestMicrophonePermission;
  @override
  State<VoiceprintPage> createState() => _VoiceprintPageState();
}

class _VoiceprintPageState extends State<VoiceprintPage>
    with WidgetsBindingObserver {
  late final VoiceprintCapture _capture =
      widget.capture ?? DeviceVoiceprintCapture();
  Map<String, dynamic>? _data;
  String? _error, _path, _slot;
  bool _busy = false,
      _recording = false,
      _stopping = false,
      _routeChecking = false;
  int _seconds = 0, _refreshGeneration = 0;
  String? _uploadingSlot;
  String _device = '录音开始后核实实际麦克风';
  Timer? _ticker, _poll;
  StreamSubscription<double>? _amplitude;
  StreamSubscription<RecordState>? _recordState;
  _VoiceStage _stage = _VoiceStage.home;
  int _activeIndex = 0;
  PermissionStatus? _permission;
  final List<double> _levels = [];
  bool get _registered => _data?['registered'] == true;
  Map? get _enrollment => _data?['enrollment'] as Map?;
  bool get _processing =>
      _samples.values.any((s) => (s as Map)['status'] == 'processing');
  bool get _blocked => _busy || _recording || _stopping || _processing;
  bool _accepted(int index) =>
      (_samples['$index'] as Map?)?['status'] == 'accepted' &&
      !(_slot == '$index' && _path != null);
  int get _acceptedCount => List.generate(3, (i) => i).where(_accepted).length;
  int get _nextIndex =>
      List.generate(3, (i) => i).where((i) => !_accepted(i)).firstOrNull ?? 2;
  String? get _enrollmentId => (_data?['enrollment'] as Map?)?['id'] as String?;
  Map get _samples =>
      ((_data?['enrollment'] as Map?)?['samples'] as Map?) ?? {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _recordState = _capture.states.listen((state) {
      if (_recording && !_stopping && state != RecordState.record) {
        unawaited(_stop(discard: true, reason: '录音被系统中断，请重录当前片段'));
      }
    });
    unawaited(_refresh());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed && _recording) {
      unawaited(_stop(discard: true, reason: '已离开前台，请重录当前片段'));
    }
  }

  String _message(Object error) =>
      error is ApiFailure ? error.message : '操作未完成，请重试；已有声纹不会被覆盖';

  Future<void> _refresh() async {
    final generation = ++_refreshGeneration;
    try {
      final result = await widget.repository.status();
      if (!mounted || generation != _refreshGeneration) return;
      setState(() {
        if (_stage == _VoiceStage.verify &&
            _enrollment != null &&
            result['enrollment'] == null &&
            result['registered'] == true &&
            result['verifiedAt'] != _data?['verifiedAt']) {
          _stage = _VoiceStage.success;
        } else if (_stage != _VoiceStage.home &&
            _enrollment != null &&
            result['enrollment'] == null) {
          _stage = _VoiceStage.home;
        }
        _data = result;
        _error = null;
      });
      final processing = _samples.values.any(
        (s) => (s as Map)['status'] == 'processing',
      );
      _poll?.cancel();
      if (processing) {
        _poll = Timer(const Duration(seconds: 2), () => unawaited(_refresh()));
      }
    } catch (error) {
      if (mounted && generation == _refreshGeneration) {
        setState(() => _error = _message(error));
      }
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    ++_refreshGeneration;
    _poll?.cancel();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      widget.repository.checkAccount();
      await action();
      await _refresh();
    } catch (error) {
      if (mounted) setState(() => _error = _message(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool> _confirm(String title, String text, String button) =>
      _showVoiceConfirmation(context, title: title, text: text, button: button);

  Future<void> _begin() async {
    // Keep the redesigned consent sheet aligned with the connected backend's capability.
    final agreed = await _showVoiceConsent(
      context,
      realtimeAvailable: _data?['realtimeIdentificationAvailable'] == true,
    );
    if (!agreed || !mounted) return;
    await _run(
      () => widget.repository.post('/enrollments', {
        'consentVersion': _data!['consentVersion'],
      }),
    );
    if (mounted && _enrollmentId != null && _error == null) {
      setState(() => _stage = _VoiceStage.prepare);
    }
  }

  Future<void> _prepareRecording() async {
    if (_blocked) return;
    await _run(() async {
      if (widget.isMeetingRecording()) throw const ApiFailure('请先结束会议录音，再注册声纹');
      _permission =
          await (widget.requestMicrophonePermission?.call() ??
              Permission.microphone.request());
      if (_permission!.isGranted && mounted) {
        setState(() {
          _activeIndex = _nextIndex;
          _stage = _enrollment?['status'] == 'ready'
              ? _VoiceStage.verify
              : _VoiceStage.record;
        });
      }
    });
  }

  Future<void> _back() async {
    if (_busy || _recording || _stopping) return;
    if (_path != null) {
      if (!await _confirm(
        '录音尚未保存',
        '当前录音还未上传成功。退出会丢弃这份本地录音，已通过的片段不受影响。',
        '丢弃并退出',
      )) {
        return;
      }
      await _clearClip();
    }
    if (!mounted) return;
    if (_stage != _VoiceStage.home) {
      setState(() => _stage = _VoiceStage.home);
    } else {
      Navigator.of(context).pop();
    }
  }

  Future<void> _buildTemplate() async {
    await _run(
      () => widget.repository.post('/enrollments/$_enrollmentId/build'),
    );
    // A failed consistency check can invalidate all three server samples. Reload
    // them before allowing a retry, rather than continuing with stale acceptance.
    final failure = _error;
    if (failure != null) {
      await _refresh();
      if (mounted) {
        setState(() {
          _error = failure;
          _activeIndex = _nextIndex;
        });
      }
      return;
    }
    if (mounted && _enrollment?['status'] == 'ready') {
      setState(() => _stage = _VoiceStage.verify);
    }
  }

  Future<void> _cancelEnrollment() async {
    if (!await _confirm('取消本次注册？', '清理本次临时特征，已有声纹不受影响。', '取消注册')) return;
    await _run(() async {
      await widget.repository.delete('/enrollments/$_enrollmentId');
      await _clearClip();
    });
    if (mounted && _error == null) setState(() => _stage = _VoiceStage.home);
  }

  Future<void> _deleteVoiceprint() async {
    if (!await _confirm(
      '撤回同意并删除声纹？',
      '将停用并删除在线声纹模板和未完成的注册数据，之后需要重新注册。历史备份按保留策略清理。会议录音和纪要不会被删除。',
      '撤回同意并删除',
    )) {
      return;
    }
    await _run(() async {
      await widget.repository.delete('');
      await _clearClip();
    });
    if (mounted && _error == null) setState(() => _stage = _VoiceStage.home);
  }

  Future<void> _start(String slot) async {
    // 本地录音在上传确认前不能被另一段覆盖。仅允许明确确认后重录本段。
    if (_path != null) {
      if (_slot != slot) {
        setState(() => _error = '请先保存当前片段，通过检查后再录下一段');
        return;
      }
      if (!await _confirm('重录当前片段？', '当前片段尚未上传成功。重录将丢弃这份本地录音。', '确认重录')) return;
      if (!mounted) return;
    }
    await _run(() async {
      if (widget.isMeetingRecording()) {
        throw const ApiFailure('请先结束会议录音，再注册声纹');
      }
      await _clearClip();
      _slot = slot;
      _path = await _capture.start();
      if (!mounted) {
        await _capture.stop();
        await _clearClip();
        return;
      }
      setState(() {
        _recording = true;
        _seconds = 0;
        _levels.clear();
        _device = '正在核实实际麦克风';
      });
      _amplitude = _capture.levels.listen((value) {
        if (mounted) {
          setState(() {
            _levels.add(value);
            if (_levels.length > 27) _levels.removeAt(0);
          });
        }
      });
      // Read actual native recording configuration rather than trusting a device label.
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted || !_recording) return;
        setState(() => _seconds++);
        unawaited(_checkRoute());
        if (_seconds >= 20) unawaited(_stop());
      });
    });
  }

  Future<void> _checkRoute() async {
    if (_routeChecking || !_recording) return;
    _routeChecking = true;
    try {
      widget.repository.checkAccount();
      final route = await _capture.route();
      if (!_recording) return;
      if (!route.verified || route.type != 'builtIn' || route.silenced) {
        await _stop(discard: true, reason: '无法核实内置麦克风或采音已变化，请检查后重录');
      } else if (mounted) {
        setState(() => _device = '手机内置麦克风 · 已核实');
      }
    } catch (_) {
      await _stop(discard: true, reason: '采音状态或账户已变化，请重新进入后录制');
    } finally {
      _routeChecking = false;
    }
  }

  Future<void> _stop({bool discard = false, String? reason}) async {
    if (!_recording || _stopping) return;
    setState(() => _stopping = true);
    _ticker?.cancel();
    await _amplitude?.cancel();
    try {
      // Take a final route snapshot before releasing the active recording.
      if (!discard) {
        final route = await _capture.route();
        if (!route.verified || route.type != 'builtIn' || route.silenced) {
          discard = true;
          reason = '实际麦克风未核实，请重录';
        }
      }
      await _capture.stop();
      if (discard) await _clearClip();
    } catch (_) {
      await _capture.cancel();
      await _clearClip();
      reason = '录音未完整保存，请重录';
    } finally {
      _stopping = false;
      if (mounted) {
        setState(() {
          _recording = false;
          _error = reason;
        });
      }
    }
    // 停止即保存并上传当前段；上传失败保留本地文件，不能静默丢弃。
    if (mounted && !discard && reason == null && _path != null) await _upload();
  }

  Future<void> _clearClip() async {
    await _capture.stopPlayback();
    final path = _path;
    _path = null;
    if (path != null && await File(path).exists()) await File(path).delete();
  }

  Future<void> _upload() async {
    if (_busy || _path == null || _slot == null || _enrollmentId == null) {
      return;
    }
    setState(() => _uploadingSlot = _slot);
    try {
      await _run(() async {
        if (_path == null || _slot == null || _enrollmentId == null) return;
        await widget.repository.upload(
          _enrollmentId!,
          _slot!,
          await File(_path!).readAsBytes(),
        );
        await _clearClip();
      });
    } finally {
      if (mounted) setState(() => _uploadingSlot = null);
    }
  }

  String _reason(Object? value) => switch (value) {
    'invalid_audio' => '请录制8～20秒，使用手机内置麦克风',
    'insufficient_speech' => '有效说话不足，请减少停顿并继续朗读',
    'clipping' => '音量过大，请稍微远离麦克风',
    'too_quiet' => '声音过轻，请靠近麦克风正常说话',
    'too_noisy' => '环境噪声较大，请换到安静位置',
    'inconsistent_voice' => '声音片段不一致，请独自正常说话并重录',
    'verification_mismatch' => '未通过独立声音验证，请确认设备并重试',
    'processing_interrupted' => '服务处理被中断，请重录该段',
    'version_conflict' => '声纹已更新，请取消本次注册后重新开始',
    _ => '处理未完成，请重录或稍后重试',
  };

  void _showStage(_VoiceStage stage) {
    if (!_blocked) setState(() => _stage = stage);
  }

  void _selectSample(int index) {
    if (!_blocked &&
        _path == null &&
        (_accepted(index) || index == _nextIndex)) {
      setState(() => _activeIndex = index);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop:
        _stage == _VoiceStage.home &&
        !_busy &&
        !_recording &&
        !_stopping &&
        _path == null,
    onPopInvokedWithResult: (didPop, result) {
      if (!didPop) unawaited(_back());
    },
    child: _VoiceprintView(state: this),
  );

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker?.cancel();
    _poll?.cancel();
    unawaited(_amplitude?.cancel());
    unawaited(_recordState?.cancel());
    // Stop the native writer before deleting its private temporary file.
    unawaited(() async {
      await _capture.cancel();
      await _clearClip();
      await _capture.dispose();
    }());
    super.dispose();
  }
}
