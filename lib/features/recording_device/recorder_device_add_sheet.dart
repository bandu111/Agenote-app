import 'dart:async';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import 'ai_voice_product_artwork.dart';
import 'recorder_device_view_model.dart';
import 'recorder_device_widgets.dart';
import 'recorder_models.dart';

Future<void> showAddRecorderDevice(BuildContext context) async {
  final model = context.read<RecorderDeviceViewModel>();
  if (!model.recordsReady || model.addingOpen || model.managementBusy) return;
  final token = model.beginAdding();
  try {
    await showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      useSafeArea: true,
      isScrollControlled: true,
      sheetAnimationStyle: MediaQuery.disableAnimationsOf(context)
          ? AnimationStyle.noAnimation
          : null,
      builder: (_) => ChangeNotifierProvider.value(
        value: model,
        child: RecorderDeviceAddSheet(token: token),
      ),
    );
  } finally {
    await model.cancelAdding(token);
  }
}

class RecorderDeviceAddSheet extends StatefulWidget {
  const RecorderDeviceAddSheet({super.key, required this.token});
  final int token;
  @override
  State<RecorderDeviceAddSheet> createState() => _RecorderDeviceAddSheetState();
}

class _RecorderDeviceAddSheetState extends State<RecorderDeviceAddSheet> {
  RecorderDeviceViewModel? _model;
  bool _scanned = false,
      _scheduled = false,
      _choosing = false,
      _success = false;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_model != null) return;
    _model = context.read<RecorderDeviceViewModel>()..addListener(_changed);
    scheduleMicrotask(() async {
      await _model!.checkBluetooth();
      _changed();
    });
  }

  void _changed() {
    final m = _model!;
    if (!mounted ||
        !m.isAdding(widget.token) ||
        _scheduled ||
        _scanned ||
        !m.permissionGranted ||
        !m.bluetoothEnabled ||
        m.managementBusy ||
        m.connection != RecorderConnection.disconnected) {
      return;
    }
    _scheduled = true;
    scheduleMicrotask(() async {
      _scheduled = false;
      if (!mounted || _scanned || !m.isAdding(widget.token)) return;
      _scanned = true;
      await m.startScan();
    });
  }

  Future<void> _choose(RecorderDevice device) async {
    if (_choosing) return;
    setState(() => _choosing = true);
    final ok = await _model!.addDevice(device, widget.token);
    if (!mounted) return;
    setState(() {
      _choosing = false;
      _success = ok;
    });
    if (!ok) return;
    // This is only a visual acknowledgement after the real connection AND
    // successful persistence. It never drives BLE state or claims success early.
    // A static acknowledgement remains visible with reduced motion enabled.
    await Future<void>.delayed(const Duration(milliseconds: 650));
    if (mounted && ModalRoute.of(context)?.isCurrent == true) {
      Navigator.of(context).pop();
    }
  }

  @override
  void dispose() {
    _model?.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final m = context.watch<RecorderDeviceViewModel>();
    final unaddedConnected =
        m.connected && m.selected != null && m.savedFor(m.selected!.id) == null;
    final unavailable =
        m.connection != RecorderConnection.disconnected &&
        !_choosing &&
        !unaddedConnected;
    final largeText = MediaQuery.textScalerOf(context).scale(16) > 22;
    final phase = _success && m.connected
        ? AiVoiceArtworkPhase.success
        : _choosing || m.saving
        ? AiVoiceArtworkPhase.connecting
        : m.scanning
        ? AiVoiceArtworkPhase.scanning
        : m.error != null || m.recordsError != null
        ? AiVoiceArtworkPhase.failure
        : m.devices.isNotEmpty || unaddedConnected
        ? AiVoiceArtworkPhase.found
        : AiVoiceArtworkPhase.idle;
    final status = _success
        ? (m.connected ? 'AI Voice 已添加' : '已添加，设备当前已断开')
        : m.saving
        ? '正在保存设备'
        : _choosing
        ? '正在连接 AI Voice'
        : unavailable
        ? (m.connection == RecorderConnection.disconnecting
              ? '正在断开设备'
              : '已有设备连接')
        : unaddedConnected && m.recordsError != null
        ? '设备已连接，保存失败'
        : unaddedConnected
        ? '设备已连接，尚未添加'
        : m.scanning && m.devices.isNotEmpty
        ? '已发现附近设备'
        : m.scanning
        ? '正在搜索附近设备'
        : m.error != null
        ? '连接未完成'
        : m.message?.contains('未找到') == true
        ? '未找到附近设备'
        : m.devices.isNotEmpty
        ? '发现附近设备'
        : '准备添加 AI Voice';
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: largeText ? .9 : .72,
      minChildSize: .4,
      maxChildSize: .95,
      builder: (context, scroll) => SafeArea(
        top: false,
        child: Column(
          children: [
            SizedBox(
              height: 52,
              child: Row(
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('取消'),
                  ),
                  const Expanded(
                    child: Text(
                      '添加设备',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(width: 64),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                controller: scroll,
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
                children: [
                  const SizedBox(height: 4),
                  Center(
                    child: AiVoiceProductArtwork(
                      phase: phase,
                      size: 176,
                      animate: true,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Semantics(
                    liveRegion: true,
                    child: Center(
                      child: AnimatedSwitcher(
                        duration: MediaQuery.disableAnimationsOf(context)
                            ? Duration.zero
                            : const Duration(milliseconds: 180),
                        child: Row(
                          key: ValueKey(status),
                          mainAxisSize: MainAxisSize.min,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            if (!_success &&
                                (m.scanning || _choosing || m.saving)) ...[
                              if (MediaQuery.disableAnimationsOf(context))
                                Icon(
                                  Icons.bluetooth,
                                  size: 18,
                                  color: Theme.of(context).colorScheme.primary,
                                )
                              else
                                const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                ),
                              const SizedBox(width: 8),
                            ],
                            if (_success && m.connected) ...[
                              Icon(
                                Icons.check_circle,
                                size: 20,
                                color: Theme.of(context).colorScheme.primary,
                              ),
                              const SizedBox(width: 8),
                            ],
                            Flexible(
                              child: Text(
                                status,
                                textAlign: TextAlign.center,
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  if (!_success)
                    const DeviceNotice('请将 AI Voice 录音卡置于附近，并确保设备已开机。'),
                  if (_success) ...[
                    const DeviceNotice('可以在“我的设备”中查看设备状态。'),
                  ] else if (unavailable) ...[
                    DeviceNotice(
                      m.managementLocked
                          ? '会议正在使用 AI Voice，请先结束会议。'
                          : m.connection == RecorderConnection.disconnecting
                          ? '正在取消连接，请稍候。'
                          : '请先断开当前设备，再添加其他设备。',
                    ),
                  ] else if (!m.permissionGranted) ...[
                    DeviceGroup(
                      children: [DeviceInfoRow('蓝牙访问', m.permissionLabel)],
                    ),
                    if (m.bluetoothAuthorization != 'restricted')
                      FilledButton(
                        onPressed:
                            m.bluetoothAuthorization == 'denied' ||
                                m.lastErrorCode ==
                                    'permission_permanently_denied'
                            ? openAppSettings
                            : m.requestPermissions,
                        child: Text(
                          m.bluetoothAuthorization == 'denied' ||
                                  m.lastErrorCode ==
                                      'permission_permanently_denied'
                              ? '前往设置'
                              : '允许蓝牙访问',
                        ),
                      ),
                  ] else if (!m.bluetoothEnabled) ...[
                    DeviceNotice(
                      m.bluetoothState == 'powered_off'
                          ? '请在系统设置中开启蓝牙，返回后会重新检查。'
                          : m.bluetoothLabel,
                    ),
                    TextButton(
                      onPressed: m.checkBluetooth,
                      child: const Text('重新检查'),
                    ),
                  ] else ...[
                    if (unaddedConnected && !_choosing) ...[
                      const DeviceNotice('当前设备已连接，尚未保存到我的设备。'),
                      TextButton(
                        onPressed: () => _choose(m.selected!),
                        child: Text(m.recordsError == null ? '添加当前设备' : '重试保存'),
                      ),
                    ],
                    if (m.devices.isNotEmpty && !unaddedConnected)
                      DeviceGroup(
                        children: [
                          for (final d in m.devices)
                            ListTile(
                              title: const Text('AI Voice'),
                              subtitle: Text(
                                m.savedFor(d.id) != null
                                    ? '已添加'
                                    : '录音卡 · 设备 ${m.devices.indexOf(d) + 1}',
                              ),
                              leading: const AiVoiceProductArtwork(size: 48),
                              trailing: m.savedFor(d.id) != null
                                  ? const Icon(Icons.check)
                                  : Text(
                                      m.error != null ? '重试' : '添加',
                                      style: TextStyle(
                                        color: Theme.of(
                                          context,
                                        ).colorScheme.primary,
                                      ),
                                    ),
                              enabled:
                                  !_choosing &&
                                  !m.managementBusy &&
                                  m.savedFor(d.id) == null,
                              onTap: () => _choose(d),
                            ),
                        ],
                      ),
                    if (!m.scanning &&
                        m.devices.isEmpty &&
                        !_choosing &&
                        !unaddedConnected)
                      const DeviceNotice('未找到录音卡，请确认已开机、靠近手机，且未被其他 App 占用。'),
                    if (!_choosing &&
                        !m.scanning &&
                        m.connection == RecorderConnection.disconnected)
                      TextButton(
                        onPressed: m.startScan,
                        child: const Text('重新搜索'),
                      ),
                  ],
                  if (m.error != null) DeviceNotice(m.error!, error: true),
                  if (m.recordsError != null)
                    DeviceNotice(m.recordsError!, error: true),
                  if (m.connection == RecorderConnection.disconnecting)
                    const DeviceNotice('等待设备确认断开；若长时间未恢复，请关闭系统蓝牙后重试。'),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
