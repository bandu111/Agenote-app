import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:flutter/foundation.dart';
import 'recorder_device_repository.dart';
import 'recorder_device_service.dart';
import 'recorder_models.dart';

class RecorderDeviceViewModel extends ChangeNotifier
    with WidgetsBindingObserver {
  RecorderDeviceViewModel(
    this.service, {
    this.scanTimeout = const Duration(seconds: 12),
    this.commandTimeout = const Duration(seconds: 12),
    this.readyDelay = const Duration(seconds: 2),
    RecorderDeviceRepository? repository,
  }) : repository = repository ?? SecureRecorderDeviceRepository();
  final RecorderDeviceService service;
  final RecorderDeviceRepository repository;
  List<SavedRecorderDevice> _saved = [];
  List<SavedRecorderDevice> get savedDevices => List.unmodifiable(_saved);
  bool recordsReady = false, saving = false, managementBusy = false;
  String? recordsError;
  String? lastErrorCode;
  String? failedConnectionId;
  bool identityMismatch = false;
  final Set<String> failedFields = {};
  Set<String> get pendingFields => Set.unmodifiable(_awaitingInfo);
  bool Function()? meetingUsesDevice;
  bool get managementLocked => meetingUsesDevice?.call() == true;
  void notifyMeetingUsageChanged() => _emit();
  int _managementToken = 0;
  int? _addToken;
  bool get addingOpen => _addToken != null;
  bool isAdding(int token) => _addToken == token;
  bool _connectSubmitted = false;
  String? _managementDeviceId;
  Future<void> _storageQueue = Future.value();
  final Set<VoidCallback> _waiting = {};
  String get platform => defaultTargetPlatform.name;
  bool isCurrent(SavedRecorderDevice record) =>
      record.platform == platform && selected?.id == record.device.id;
  SavedRecorderDevice? savedFor(String id) {
    for (final record in _saved) {
      if (record.platform == platform && record.device.id == id) return record;
    }
    return null;
  }

  Future<bool> renameDevice(String recordId, String name) async {
    final cleaned = name.trim();
    if (cleaned.isEmpty || cleaned.runes.length > 30) return false;
    return _writeRecords(
      () => _saved
          .map((r) => r.recordId == recordId ? r.withName(cleaned) : r)
          .toList(),
      valid: () => _saved.any((r) => r.recordId == recordId),
    );
  }

  Future<void> reloadRecords() async {
    try {
      _saved = await repository.load();
      recordsError = null;
      recordsReady = true;
    } catch (_) {
      recordsError = '无法读取已添加设备，请重试';
      // Never overwrite unreadable storage with an empty list.
      recordsReady = false;
    }
    _emit();
  }

  Future<bool> _writeRecords(
    List<SavedRecorderDevice> Function() build, {
    bool Function()? valid,
  }) async {
    var committed = false;
    final operation = _storageQueue.then((_) async {
      if (_disposed || !recordsReady || valid?.call() == false) return;
      final next = build();
      final previous = List<SavedRecorderDevice>.of(_saved);
      await repository.save(next);
      if (valid?.call() == false) {
        await repository.save(previous);
        return;
      }
      _saved = next;
      recordsError = null;
      committed = true;
      _emit();
    });
    _storageQueue = operation.catchError((Object _) {});
    try {
      await operation;
    } catch (_) {
      recordsError = '设备记录保存失败，请重试';
      _emit();
    }
    return committed;
  }

  Future<bool> _waitFor(
    bool Function() success,
    bool Function() abort,
    Duration timeout,
  ) async {
    final done = Completer<bool>();
    Timer? timer;
    void check() {
      if (done.isCompleted) return;
      if (_disposed || abort()) {
        done.complete(false);
      } else if (success()) {
        done.complete(true);
      }
    }

    _waiting.add(check);
    addListener(check);
    timer = Timer(timeout, () {
      if (!done.isCompleted) done.complete(false);
    });
    check();
    try {
      return await done.future;
    } finally {
      timer.cancel();
      removeListener(check);
      _waiting.remove(check);
    }
  }

  int beginAdding() {
    _addToken = ++_managementToken;
    _managementDeviceId = null;
    error = message = null;
    _emit();
    return _addToken!;
  }

  Future<void> cancelAdding(int token) async {
    if (_addToken != token) return;
    _addToken = null;
    ++_managementToken;
    final ownedId = _managementDeviceId;
    _managementDeviceId = null;
    _emit();
    if (scanning) await stopScan();
    if (ownedId != null &&
        selected?.id == ownedId &&
        connection != RecorderConnection.disconnected &&
        !managementLocked) {
      await disconnect();
    }
  }

  Future<bool> addDevice(RecorderDevice device, int token) async {
    if (_addToken != token || managementBusy || !recordsReady) return false;
    if (connection != RecorderConnection.disconnected &&
        !(connected && selected?.id == device.id)) {
      error = '请先断开当前设备，再添加其他设备';
      _emit();
      return false;
    }
    managementBusy = true;
    _managementDeviceId = device.id;
    _emit();
    try {
      if (!(connected && selected?.id == device.id)) {
        await connect(device);
        if (connection == RecorderConnection.disconnected) return false;
        final ok = await _waitFor(
          () => connected,
          () =>
              _addToken != token ||
              connection == RecorderConnection.disconnected,
          commandTimeout,
        );
        if (!ok) return false;
      }
      if (_addToken != token || !connected || identityMismatch) return false;
      saving = true;
      _emit();
      final ok = await _saveCurrent(
        valid: () => _addToken == token && connected,
      );
      if (ok && _addToken == token) {
        _addToken = null;
        _managementDeviceId = null;
        message = '已添加 AI Voice';
        final epoch = _epoch;
        if (savedFor(device.id)?.serialNumber != info.serialNumber ||
            savedFor(device.id)?.firmware != info.firmware) {
          unawaited(
            _saveCurrent(
              valid: () => connected && _epoch == epoch && !identityMismatch,
            ),
          );
        }
      }
      return ok;
    } finally {
      managementBusy = saving = false;
      _emit();
    }
  }

  Future<bool> _saveCurrent({bool Function()? valid}) {
    final device = selected;
    if (device == null) return Future.value(false);
    return _writeRecords(() {
      SavedRecorderDevice? existing = savedFor(device.id);
      if (existing == null && info.serialNumber != null) {
        for (final record in _saved) {
          if (record.platform == platform &&
              record.serialNumber == info.serialNumber) {
            existing = record;
            break;
          }
        }
      }
      final record =
          (existing ??
                  SavedRecorderDevice(
                    recordId:
                        '${DateTime.now().microsecondsSinceEpoch}-$_epoch',
                    platform: platform,
                    device: device,
                    addedAt: DateTime.now(),
                  ))
              .withInfo(info, device: device);
      return [
        ..._saved.where(
          (r) =>
              r.recordId != record.recordId &&
              !(r.platform == platform &&
                  (r.device.id == device.id ||
                      (info.serialNumber != null &&
                          r.serialNumber == info.serialNumber))),
        ),
        record,
      ];
    }, valid: valid);
  }

  Future<void> reconnect(SavedRecorderDevice record) async {
    if (managementBusy || connection != RecorderConnection.disconnected) return;
    managementBusy = true;
    final token = ++_managementToken;
    _emit();
    try {
      await startScan();
      if (!scanning) return;
      final found = await _waitFor(
        () => _devices.containsKey(record.device.id),
        () => token != _managementToken || !scanning,
        scanTimeout,
      );
      if (!found) {
        if (token == _managementToken) error = '未发现这台设备，请确认已开机并靠近手机';
        return;
      }
      await connect(_devices[record.device.id]!);
      final ok = await _waitFor(
        () => connected,
        () =>
            token != _managementToken ||
            connection == RecorderConnection.disconnected,
        commandTimeout,
      );
      if (!ok && error == null) error = '连接未完成，请重试';
    } finally {
      if (scanning) await stopScan();
      managementBusy = false;
      _emit();
    }
  }

  Future<bool> removeDevice(SavedRecorderDevice record) async {
    if (managementBusy || managementLocked || !recordsReady) return false;
    managementBusy = true;
    _emit();
    try {
      if (isCurrent(record) && connection != RecorderConnection.disconnected) {
        await disconnect();
        final ok = await _waitFor(
          () => connection == RecorderConnection.disconnected,
          () => managementLocked,
          commandTimeout,
        );
        if (!ok) return false;
      }
      return await _writeRecords(
        () => _saved.where((r) => r.recordId != record.recordId).toList(),
        valid: () => !managementLocked,
      );
    } finally {
      managementBusy = false;
      _emit();
    }
  }

  final Duration scanTimeout, commandTimeout, readyDelay;
  final Map<String, RecorderDevice> _devices = {};
  List<RecorderDevice> get devices => List.unmodifiable(_devices.values);
  RecorderDevice? selected;
  RecorderConnection connection = RecorderConnection.disconnected;
  RecorderState recording = RecorderState.unknown;
  RecorderInfo info = RecorderInfo();
  bool permissionGranted = false,
      bluetoothEnabled = false,
      scanning = false,
      initializing = false,
      refreshing = false;
  String bluetoothState = 'unknown';
  String bluetoothAuthorization = 'not_determined';
  String? _bluetoothError;
  String get permissionLabel => switch (bluetoothAuthorization) {
    'authorized' => '已允许',
    'denied' => '未允许，请在设置中开启',
    'restricted' => '系统限制使用',
    _ => '待授权',
  };
  String get bluetoothLabel {
    if (!permissionGranted) return '授权后可检测';
    return switch (bluetoothState) {
      'powered_on' => '已开启',
      'powered_off' => '未开启',
      'unauthorized' => '未授权',
      'unsupported' => '设备不支持',
      'resetting' => '正在恢复连接',
      _ => '正在确认状态',
    };
  }

  String get _bluetoothUnavailableMessage {
    if (!permissionGranted) return '请先允许蓝牙权限';
    return switch (bluetoothState) {
      'powered_off' => '请先开启系统蓝牙',
      'unauthorized' => '请在系统设置中允许蓝牙权限后重试',
      'unsupported' => '当前设备不支持蓝牙连接',
      _ => '蓝牙状态确认中，请稍候重试',
    };
  }

  String? error, infoError, message, lastDiagnostic;
  final Set<String> _awaitingInfo = {};
  int _epoch = 0;
  int get connectionEpoch => _epoch;
  int _scanRevision = 0;
  bool _disposed = false, _started = false, _permissionRequest = false;
  Future<void>? _init;
  StreamSubscription<RecorderEvent>? _subscription;
  Timer? _scanTimer, _commandTimer, _infoTimer, _durationTimer;
  bool get connected => connection == RecorderConnection.connected;
  bool get recordingBusy => const [
    RecorderState.starting,
    RecorderState.pausing,
    RecorderState.resuming,
    RecorderState.stopping,
  ].contains(recording);
  void _emit() {
    if (!_disposed) notifyListeners();
  }

  Future<void> initialize() => _init ??= _initialize();
  Future<void> _initialize() async {
    initializing = true;
    WidgetsBinding.instance.addObserver(this);
    _subscription = service.events.listen(_event);
    try {
      await service.initialize();
      _started = true;
      await reloadRecords();
    } catch (e) {
      _failure(e);
    } finally {
      initializing = false;
      _emit();
    }
  }

  void _failure(Object e) {
    lastErrorCode = e is RecorderFailure ? e.code : null;
    error = e is RecorderFailure ? e.message : '设备操作未完成，请重试';
    _emit();
  }

  Future<void> requestPermissions() async {
    if (_permissionRequest || _disposed) return;
    _permissionRequest = true;
    error = null;
    try {
      await service.requestPermissions();
    } catch (e) {
      _failure(e);
    } finally {
      _permissionRequest = false;
      _emit();
    }
  }

  Future<void> checkBluetooth() async {
    try {
      await service.checkBluetooth();
    } catch (e) {
      _failure(e);
    }
  }

  Future<void> startScan() async {
    if (_disposed ||
        scanning ||
        connection != RecorderConnection.disconnected) {
      return;
    }
    if (!permissionGranted || !bluetoothEnabled) {
      error = _bluetoothError = _bluetoothUnavailableMessage;
      _emit();
      return;
    }
    scanning = true;
    final scanRevision = ++_scanRevision;
    error = null;
    message = null;
    _devices.clear();
    _emit();
    _scanTimer?.cancel();
    _scanTimer = Timer(scanTimeout, () {
      unawaited(stopScan());
      message = _devices.isEmpty ? '未找到兼容录音卡，请确认设备已开启且未被其他应用占用' : '扫描已结束';
      _emit();
    });
    try {
      await service.startScan();
    } catch (e) {
      if (_disposed || scanRevision != _scanRevision) return;
      scanning = false;
      _scanTimer?.cancel();
      _failure(e);
    }
  }

  Future<void> stopScan() async {
    ++_scanRevision;
    _scanTimer?.cancel();
    scanning = false;
    _emit();
    try {
      await service.stopScan();
    } catch (e) {
      _failure(e);
    }
  }

  Future<void> connect(RecorderDevice device) async {
    if (_disposed ||
        connection != RecorderConnection.disconnected ||
        !_devices.containsKey(device.id)) {
      return;
    }
    if (!permissionGranted || !bluetoothEnabled) {
      error = _bluetoothError = _bluetoothUnavailableMessage;
      _emit();
      return;
    }
    selected = device;
    _connectSubmitted = false;
    failedConnectionId = null;
    identityMismatch = false;
    connection = RecorderConnection.connecting;
    recording = RecorderState.unknown;
    info = RecorderInfo();
    error = null;
    message = null;
    final epoch = ++_epoch;
    _emit();
    _commandTimer?.cancel();
    _commandTimer = Timer(commandTimeout, () {
      if (_epoch != epoch || connection != RecorderConnection.connecting) {
        return;
      }
      error = '连接超时，正在断开；请等待设备断开后重试';
      failedConnectionId = device.id;
      unawaited(disconnect());
    });
    try {
      await stopScan();
      if (_disposed ||
          epoch != _epoch ||
          connection != RecorderConnection.connecting) {
        return;
      }
      _connectSubmitted = true;
      await service.connect(device, epoch);
    } catch (e) {
      if (_disposed || epoch != _epoch) return;
      if (connection == RecorderConnection.disconnecting) {
        _failure(e);
        return;
      }
      _commandTimer?.cancel();
      connection = RecorderConnection.disconnected;
      failedConnectionId = device.id;
      _epoch++;
      _failure(e);
    }
  }

  Future<void> disconnect() async {
    if (managementLocked) {
      error = '请先结束正在使用 AI Voice 的会议';
      _emit();
      return;
    }
    if (_disposed ||
        connection == RecorderConnection.disconnected ||
        connection == RecorderConnection.disconnecting) {
      return;
    }
    if (connection == RecorderConnection.connecting && !_connectSubmitted) {
      _disconnected();
      _emit();
      return;
    }
    _commandTimer?.cancel();
    _infoTimer?.cancel();
    _durationTimer?.cancel();
    refreshing = false;
    connection = RecorderConnection.disconnecting;
    recording = RecorderState.unknown;
    _emit();
    final epoch = _epoch;
    _commandTimer = Timer(commandTimeout, () {
      if (_epoch != epoch || connection != RecorderConnection.disconnecting) {
        return;
      }
      error = '尚未收到断开确认，请关闭系统蓝牙后重试；录音卡可能仍在独立录音';
      _emit();
    });
    try {
      await service.disconnect();
    } catch (e) {
      _failure(e);
    }
  }

  Future<void> _connectedInfo(int epoch) async {
    // 官方 Demo 在连接回调后等待服务就绪；延迟可取消，不阻塞 UI。
    await Future<void>.delayed(readyDelay);
    if (_disposed || !connected || epoch != _epoch) return;
    try {
      await service.syncTime();
      if (_disposed || !connected || epoch != _epoch) return;
      await service.setForeground(
        WidgetsBinding.instance.lifecycleState != AppLifecycleState.paused,
      );
      await refreshDeviceInfo();
    } catch (e) {
      if (epoch == _epoch) _failure(e);
    }
  }

  Future<void> refreshDeviceInfo() async {
    if (_disposed || !connected || refreshing) return;
    refreshing = true;
    infoError = null;
    _awaitingInfo
      ..clear()
      ..addAll([
        'battery',
        'capacity',
        'firmware',
        'firmware_code',
        'serial',
        'recording',
      ]);
    failedFields.clear();
    final epoch = _epoch;
    _infoTimer?.cancel();
    _infoTimer = Timer(commandTimeout, () {
      if (_disposed || epoch != _epoch || !connected) return;
      refreshing = false;
      failedFields.addAll(_awaitingInfo);
      _awaitingInfo.clear();
      infoError = '部分设备信息未返回，请刷新重试';
      _emit();
    });
    _emit();
    try {
      await service.refreshDeviceInfo();
    } catch (e) {
      if (_disposed || epoch != _epoch) return;
      refreshing = false;
      failedFields.addAll(_awaitingInfo);
      _awaitingInfo.clear();
      _infoTimer?.cancel();
      infoError = '设备信息查询失败，请刷新重试';
      _emit();
    }
  }

  Future<void> _record(
    RecorderState pending,
    Set<RecorderState> from,
    Future<void> Function() action,
  ) async {
    if (_disposed || !connected || recordingBusy || !from.contains(recording)) {
      return;
    }
    error = null;
    recording = pending;
    final epoch = _epoch;
    _emit();
    _commandTimer?.cancel();
    _commandTimer = Timer(commandTimeout, () {
      if (_disposed || epoch != _epoch || !connected || !recordingBusy) return;
      recording = RecorderState.unknown;
      error = '录音操作未获设备确认，请查询状态，不要重复开始录音';
      _emit();
      unawaited(queryRecording());
    });
    try {
      await action();
    } catch (e) {
      if (_disposed || epoch != _epoch) return;
      _commandTimer?.cancel();
      recording = RecorderState.unknown;
      _failure(e);
    }
  }

  Future<void> startRecording() => _record(RecorderState.starting, {
    RecorderState.idle,
  }, service.startRecording);
  Future<void> pauseRecording() => _record(RecorderState.pausing, {
    RecorderState.recording,
  }, service.pauseRecording);
  Future<void> resumeRecording() => _record(RecorderState.resuming, {
    RecorderState.paused,
  }, service.resumeRecording);
  Future<void> stopRecording() => _record(RecorderState.stopping, {
    RecorderState.recording,
    RecorderState.paused,
    RecorderState.unknown,
  }, service.stopRecording);
  Future<void> queryRecording() async {
    if (!connected || _disposed) return;
    final epoch = _epoch;
    try {
      await service.queryRecording();
    } catch (e) {
      if (_disposed || epoch != _epoch) return;
      _failure(e);
    }
  }

  void _event(RecorderEvent e) {
    if (_disposed) return;
    if (e.type == 'bluetooth') {
      permissionGranted = e.data['authorized'] == true;
      bluetoothEnabled = e.data['enabled'] == true;
      // Android currently sends booleans; iOS also reports all CoreBluetooth states.
      bluetoothAuthorization =
          e.data['authorization']?.toString() ??
          (permissionGranted ? 'authorized' : 'not_determined');
      bluetoothState =
          e.data['state']?.toString() ??
          (bluetoothEnabled ? 'powered_on' : 'powered_off');
      if (permissionGranted && bluetoothEnabled && error == _bluetoothError) {
        error = null;
        _bluetoothError = null;
      }
      if (const ['denied', 'restricted'].contains(bluetoothAuthorization) ||
          const [
            'powered_off',
            'unauthorized',
            'unsupported',
            'resetting',
          ].contains(bluetoothState)) {
        scanning = false;
        _scanTimer?.cancel();
        if (connection != RecorderConnection.disconnected) _disconnected();
      }
      _emit();
      return;
    }
    if (e.type == 'discovered') {
      if (!scanning) return;
      final id = e.deviceId, name = e.data['name']?.toString();
      if (id == null || id.isEmpty || name == null) return;
      _devices[id] = RecorderDevice(
        id,
        name,
        productType: e.data['productType']?.toString(),
      );
      _emit();
      return;
    }
    if (e.type == 'error' && e.epoch == 0) {
      _failure(
        RecorderFailure(
          e.data['code']?.toString() ?? 'sdk_failed',
          e.data['message']?.toString() ?? '蓝牙操作失败',
        ),
      );
      return;
    }
    if (e.epoch != _epoch || e.deviceId != selected?.id) return;
    if (e.type == 'connection') {
      if (e.data['connected'] == true &&
          connection == RecorderConnection.connecting) {
        _commandTimer?.cancel();
        connection = RecorderConnection.connected;
        unawaited(_connectedInfo(_epoch));
      } else if (e.data['connected'] == false) {
        if (connection == RecorderConnection.connecting) {
          failedConnectionId = selected?.id;
          error ??= '连接失败，请重试';
        }
        _disconnected();
      }
    } else if (!connected) {
      return;
    } else if (e.type == 'recording') {
      if (recordingBusy && e.data['query'] == true) return;
      final state = switch (e.data['state']) {
        'idle' => RecorderState.idle,
        'recording' => RecorderState.recording,
        'paused' => RecorderState.paused,
        _ => RecorderState.unknown,
      };
      if (recording == RecorderState.stopping &&
          state == RecorderState.idle &&
          e.data['saved'] == true) {
        message = '设备已确认停止并保存录音';
      }
      recording = state;
      _receivedField('recording');
      _commandTimer?.cancel();
      _durationTimer?.cancel();
      if (state == RecorderState.recording) {
        _durationTimer = Timer.periodic(const Duration(seconds: 3), (_) {
          if (connected) {
            unawaited(service.queryDuration().catchError((Object _) {}));
          }
        });
      }
    } else if (e.type == 'diagnostic') {
      lastDiagnostic = e.data['code']?.toString();
    } else if (e.type == 'error') {
      if (recordingBusy) {
        _commandTimer?.cancel();
        recording = RecorderState.unknown;
      }
      error = e.data['message']?.toString() ?? '设备响应失败，请查询当前状态';
    } else {
      info.update(e.type, e.data);
      _receivedField(e.type);
      if (e.type == 'serial' && info.serialNumber != null) {
        final previous = savedFor(selected!.id)?.serialNumber;
        if (previous != null && previous != info.serialNumber) {
          identityMismatch = true;
          error = '设备序列号与已添加记录不一致，请重新核对设备';
          if (!managementLocked) unawaited(disconnect());
          _emit();
          return;
        }
      }
      if ((e.type == 'serial' || e.type == 'firmware') &&
          !identityMismatch &&
          savedFor(selected!.id) != null &&
          (savedFor(selected!.id)!.serialNumber == null ||
              savedFor(selected!.id)!.serialNumber == info.serialNumber)) {
        final epoch = _epoch;
        unawaited(_saveCurrent(valid: () => connected && _epoch == epoch));
      }
    }
    _emit();
  }

  void _receivedField(String type) {
    _awaitingInfo.remove(type);
    failedFields.remove(type);
    if (_awaitingInfo.isEmpty) {
      refreshing = false;
      _infoTimer?.cancel();
      infoError = null;
    }
  }

  void _disconnected() {
    _commandTimer?.cancel();
    _infoTimer?.cancel();
    _durationTimer?.cancel();
    _epoch++;
    _connectSubmitted = false;
    connection = RecorderConnection.disconnected;
    recording = RecorderState.unknown;
    refreshing = false;
    _awaitingInfo.clear();
    failedFields.clear();
    info = RecorderInfo();
    message = '连接已断开，录音卡可能仍在独立录音';
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_started || _disposed) return;
    final foreground = state == AppLifecycleState.resumed;
    if (!foreground) _durationTimer?.cancel();
    if (!foreground && scanning) unawaited(stopScan());
    if (connected) {
      unawaited(service.setForeground(foreground).catchError((Object _) {}));
    }
    if (foreground) {
      unawaited(service.checkBluetooth().catchError((Object _) {}));
      if (connected) {
        unawaited(queryRecording());
        unawaited(refreshDeviceInfo());
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    for (final complete in _waiting.toList()) {
      complete();
    }
    WidgetsBinding.instance.removeObserver(this);
    _scanTimer?.cancel();
    _commandTimer?.cancel();
    _infoTimer?.cancel();
    _durationTimer?.cancel();
    unawaited(_subscription?.cancel());
    unawaited(service.dispose());
    super.dispose();
  }
}
