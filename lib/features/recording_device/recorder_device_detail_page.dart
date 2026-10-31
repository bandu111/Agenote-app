import 'dart:async';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import '../home/views/home_style.dart';
import 'ai_voice_product_artwork.dart';
import 'recorder_device_view_model.dart';
import 'recorder_device_widgets.dart';
import 'recorder_models.dart';

class RecorderDeviceDetailPage extends StatefulWidget {
  const RecorderDeviceDetailPage({super.key, required this.recordId});
  final String recordId;
  @override
  State<RecorderDeviceDetailPage> createState() =>
      _RecorderDeviceDetailPageState();
}

class _RecorderDeviceDetailPageState extends State<RecorderDeviceDetailPage> {
  Future<void> _rename(
    RecorderDeviceViewModel model,
    SavedRecorderDevice record,
  ) async {
    final name = await showCupertinoDialog<String>(
      context: context,
      builder: (dialogContext) => _RenameDeviceDialog(name: record.displayName),
    );
    if (name == null || !mounted) return;
    final saved = await model.renameDevice(record.recordId, name);
    if (!saved && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('设备名称保存失败，请重试')));
    }
  }

  @override
  void initState() {
    super.initState();
    scheduleMicrotask(() {
      if (mounted) context.read<RecorderDeviceViewModel>().initialize();
    });
  }

  Future<void> _remove(
    RecorderDeviceViewModel m,
    SavedRecorderDevice record,
  ) async {
    final confirm = await showAdaptiveDialog<bool>(
      context: context,
      builder: (context) => AlertDialog.adaptive(
        title: const Text('移除 AI Voice？'),
        content: const Text('仅移除本机 App 中的设备记录，不会删除录音卡上的录音或历史会议资料。'),
        actions: [
          adaptiveAction(context, '取消', () => Navigator.pop(context, false)),
          adaptiveAction(
            context,
            '移除设备',
            () => Navigator.pop(context, true),
            destructive: true,
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;
    final removed = await m.removeDevice(record);
    if (removed && mounted) Navigator.of(context).pop();
  }

  Widget adaptiveAction(
    BuildContext context,
    String text,
    VoidCallback action, {
    bool destructive = false,
  }) => Theme.of(context).platform == TargetPlatform.iOS
      ? CupertinoDialogAction(
          isDestructiveAction: destructive,
          onPressed: action,
          child: Text(text),
        )
      : TextButton(
          onPressed: action,
          style: destructive
              ? TextButton.styleFrom(
                  foregroundColor: Theme.of(context).colorScheme.error,
                )
              : null,
          child: Text(text),
        );
  @override
  Widget build(BuildContext context) {
    final m = context.watch<RecorderDeviceViewModel>();
    SavedRecorderDevice? record;
    for (final r in m.savedDevices) {
      if (r.recordId == widget.recordId) record = r;
    }
    if (record == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('设备详情')),
        body: Center(child: Text(m.recordsReady ? '设备记录不存在或已移除' : '正在读取设备记录')),
      );
    }
    final r = record;
    final current = m.isCurrent(r), online = current && m.connected;
    final sn = online ? m.info.serialNumber ?? r.serialNumber : r.serialNumber;
    final firmware = online ? m.info.firmware ?? r.firmware : r.firmware;
    String readTime(DateTime? at) =>
        at == null ? '时间未知' : at.toLocal().toString().split('.').first;
    final cached = [
      if (r.firmware != null && (!online || m.info.firmware == null))
        '固件版本 ${readTime(r.firmwareObservedAt)}',
      if (r.serialNumber != null && (!online || m.info.serialNumber == null))
        '序列号 ${readTime(r.serialObservedAt)}',
    ];
    String field(String name, String? value) => !online
        ? '连接后查看'
        : m.pendingFields.contains(name) && value == null
        ? '读取中'
        : m.failedFields.contains(name) && value == null
        ? '读取失败'
        : value ?? '未获取';
    final otherConnection =
        !current && m.connection != RecorderConnection.disconnected;
    final locked = m.managementLocked && current;
    return Scaffold(
      appBar: AppBar(title: const Text('设备详情')),
      body: RefreshIndicator(
        onRefresh: () async {
          await m.checkBluetooth();
          if (online) await m.refreshDeviceInfo();
        },
        child: DeviceContent(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 20),
              child: Column(
                children: [
                  const AiVoiceProductArtwork(size: 180),
                  const SizedBox(height: 12),
                  Text(
                    r.displayName,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Semantics(
                    liveRegion: true,
                    child: Text(
                      '录音卡 · ${m.failedConnectionId == r.device.id && m.connection == RecorderConnection.disconnected
                          ? '连接失败'
                          : current
                          ? deviceConnectionLabel(m.connection)
                          : '未连接'}',
                      style: TextStyle(color: HomeStyle.secondary(context)),
                    ),
                  ),
                ],
              ),
            ),
            DeviceGroup(
              children: [
                DeviceInfoRow(
                  '设备名称',
                  r.displayName,
                  icon: Icons.edit_outlined,
                  onTap: () => _rename(m, r),
                ),
                DeviceInfoRow(
                  '电量',
                  field(
                    'battery',
                    m.info.charging == true
                        ? '充电中'
                        : m.info.battery == null
                        ? null
                        : '${m.info.battery}%',
                  ),
                  icon: Icons.battery_std_outlined,
                ),
                DeviceInfoRow(
                  '存储空间',
                  field(
                    'capacity',
                    m.info.usedKb == null
                        ? null
                        : '${deviceCapacity(m.info.usedKb)} / ${deviceCapacity(m.info.totalKb)}',
                  ),
                  icon: Icons.storage_outlined,
                ),
                if (online && m.info.usage != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        LinearProgressIndicator(
                          value: m.info.usage,
                          semanticsLabel: '存储已用比例',
                        ),
                        const SizedBox(height: 8),
                        Text(
                          '剩余 ${deviceCapacity(m.info.freeKb)}',
                          style: TextStyle(color: HomeStyle.secondary(context)),
                        ),
                      ],
                    ),
                  ),
                DeviceInfoRow(
                  '录音状态',
                  online
                      ? field(
                          'recording',
                          m.recording == RecorderState.unknown
                              ? null
                              : deviceRecordingLabel(m.recording),
                        )
                      : '状态未知',
                  icon: Icons.mic_none_outlined,
                ),
              ],
            ),
            DeviceGroup(
              children: [
                DeviceInfoRow('固件版本', firmware ?? field('firmware', null)),
                DeviceInfoRow(
                  '设备序列号',
                  sn == null ? field('serial', null) : maskedSerial(sn),
                  icon: sn == null ? null : Icons.copy_outlined,
                  onTap: sn == null
                      ? null
                      : () async {
                          await Clipboard.setData(ClipboardData(text: sn));
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('序列号已复制')),
                            );
                          }
                        },
                ),
              ],
            ),
            if (cached.isNotEmpty)
              DeviceNotice('上次读取：${cached.join('；')}。连接后自动核对。'),
            if (locked) const DeviceNotice('会议正在使用 AI Voice，请先结束会议再断开或移除。'),
            if (otherConnection)
              const DeviceNotice('另一台设备正在连接或已连接，请先断开后再连接此设备。'),
            if (!m.permissionGranted)
              TextButton(
                onPressed: m.bluetoothAuthorization == 'denied'
                    ? openAppSettings
                    : m.requestPermissions,
                child: Text(
                  m.bluetoothAuthorization == 'denied' ? '前往设置' : '允许蓝牙访问',
                ),
              ),
            if (m.permissionGranted && !m.bluetoothEnabled)
              DeviceNotice(m.bluetoothLabel),
            DeviceGroup(
              children: [
                DeviceInfoRow(
                  online ? '断开连接' : '连接',
                  '',
                  action: true,
                  loading:
                      m.managementBusy ||
                      (current &&
                          (m.connection == RecorderConnection.connecting ||
                              m.connection ==
                                  RecorderConnection.disconnecting)),
                  onTap:
                      locked ||
                          otherConnection ||
                          m.managementBusy ||
                          (current &&
                              m.connection != RecorderConnection.connected &&
                              m.connection != RecorderConnection.disconnected)
                      ? null
                      : online
                      ? () async {
                          if (m.recording == RecorderState.recording ||
                              m.recording == RecorderState.paused) {
                            final ok = await showAdaptiveDialog<bool>(
                              context: context,
                              builder: (c) => AlertDialog.adaptive(
                                title: const Text('断开连接？'),
                                content: const Text('断开蓝牙不会停止录音卡上的独立录音。'),
                                actions: [
                                  adaptiveAction(
                                    c,
                                    '取消',
                                    () => Navigator.pop(c, false),
                                  ),
                                  adaptiveAction(
                                    c,
                                    '断开连接',
                                    () => Navigator.pop(c, true),
                                  ),
                                ],
                              ),
                            );
                            if (ok != true) return;
                          }
                          await m.disconnect();
                        }
                      : () => m.reconnect(r),
                ),
                if (online)
                  DeviceInfoRow(
                    '刷新设备信息',
                    '',
                    action: true,
                    loading: m.refreshing,
                    onTap: m.refreshing ? null : m.refreshDeviceInfo,
                  ),
              ],
            ),
            if (m.error != null) DeviceNotice(m.error!, error: true),
            if (online && m.infoError != null)
              DeviceNotice(m.infoError!, error: true),
            if (m.recordsError != null)
              DeviceNotice(m.recordsError!, error: true),
            DeviceGroup(
              children: [
                DeviceInfoRow(
                  '移除设备',
                  '',
                  action: true,
                  destructive: true,
                  onTap:
                      m.managementLocked ||
                          m.managementBusy ||
                          (current &&
                              m.connection == RecorderConnection.disconnecting)
                      ? null
                      : () => _remove(m, r),
                ),
              ],
            ),
            const DeviceNotice('设备状态来自录音卡回调。断开连接不代表录音已停止或保存。'),
          ],
        ),
      ),
    );
  }
}

class _RenameDeviceDialog extends StatefulWidget {
  const _RenameDeviceDialog({required this.name});
  final String name;
  @override
  State<_RenameDeviceDialog> createState() => _RenameDeviceDialogState();
}

class _RenameDeviceDialogState extends State<_RenameDeviceDialog> {
  late final TextEditingController controller = TextEditingController(
    text: widget.name,
  );

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  void submit() {
    if (controller.text.trim().isNotEmpty) {
      Navigator.pop(context, controller.text);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final valid = controller.text.trim().isNotEmpty;
    return CupertinoTheme(
      data: CupertinoThemeData(
        brightness: Theme.of(context).brightness,
        primaryColor: colors.primary,
      ),
      child: CupertinoAlertDialog(
        title: const Text('设备名称'),
        content: Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('输入你希望显示的设备名称。', textAlign: TextAlign.center),
              const SizedBox(height: 14),
              CupertinoTextField(
                controller: controller,
                autofocus: true,
                maxLength: 30,
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 8),
                placeholder: '设备名称',
                style: TextStyle(color: colors.onSurface, fontSize: 15),
                suffix: controller.text.isEmpty
                    ? null
                    : Material(
                        color: Colors.transparent,
                        child: IconButton(
                          tooltip: '清空名称',
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints.tightFor(
                            width: 36,
                            height: 36,
                          ),
                          icon: Icon(
                            Icons.cancel,
                            size: 18,
                            color: colors.onSurfaceVariant,
                          ),
                          onPressed: () => setState(controller.clear),
                        ),
                      ),
                suffixMode: OverlayVisibilityMode.editing,
                decoration: BoxDecoration(
                  color: CupertinoDynamicColor.resolve(
                    CupertinoColors.tertiarySystemBackground,
                    context,
                  ),
                  borderRadius: BorderRadius.circular(7),
                  border: Border.all(
                    color: CupertinoDynamicColor.resolve(
                      CupertinoColors.separator,
                      context,
                    ),
                    width: 0.5,
                  ),
                ),
                textInputAction: TextInputAction.done,
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) => submit(),
              ),
            ],
          ),
        ),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          CupertinoDialogAction(
            isDefaultAction: true,
            onPressed: valid ? submit : null,
            child: const Text('完成'),
          ),
        ],
      ),
    );
  }
}
