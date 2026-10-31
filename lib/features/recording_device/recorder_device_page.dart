import '../../shared/widgets/content_skeleton.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../home/views/home_style.dart';
import 'ai_voice_product_artwork.dart';
import 'recorder_device_add_sheet.dart';
import 'recorder_device_view_model.dart';
import 'recorder_device_widgets.dart';
import 'recorder_models.dart';

class RecorderDevicePage extends StatefulWidget {
  const RecorderDevicePage({super.key});
  @override
  State<RecorderDevicePage> createState() => _RecorderDevicePageState();
}

class _RecorderDevicePageState extends State<RecorderDevicePage> {
  @override
  void initState() {
    super.initState();
    scheduleMicrotask(() {
      if (mounted) context.read<RecorderDeviceViewModel>().initialize();
    });
  }

  @override
  Widget build(BuildContext context) {
    final m = context.watch<RecorderDeviceViewModel>();
    void add() => showAddRecorderDevice(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('我的设备'),
        actions: [
          IconButton(
            tooltip: '添加设备',
            onPressed: m.recordsReady ? add : null,
            icon: const Icon(Icons.add),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: DeviceContent(
        children: [
          if (!m.recordsReady) ...[
            if (m.recordsError == null)
              const ContentSkeleton(
                rows: 1,
                layout: SkeletonLayout.device,
                scrollable: false,
                label: '正在读取已添加设备',
              )
            else ...[
              DeviceNotice(m.recordsError!, error: true),
              TextButton(onPressed: m.reloadRecords, child: const Text('重试读取')),
            ],
          ] else if (m.savedDevices.isEmpty) ...[
            const SizedBox(height: 64),
            const Center(child: AiVoiceProductArtwork(size: 120)),
            const SizedBox(height: 20),
            const Center(
              child: Text(
                '还没有添加设备',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
              ),
            ),
            const SizedBox(height: 10),
            const Center(
              child: Text('点击右上角添加 AI Voice 录音卡', textAlign: TextAlign.center),
            ),
          ] else ...[
            if (!m.permissionGranted || !m.bluetoothEnabled)
              DeviceNotice(
                !m.permissionGranted
                    ? '连接设备需要蓝牙权限，已添加记录仍会保留。'
                    : '${m.bluetoothLabel}，已添加记录仍会保留。',
              ),
            if (m.recordsError != null)
              DeviceNotice(m.recordsError!, error: true),
            DeviceGroup(
              children: [
                for (final record in m.savedDevices)
                  _deviceRow(context, m, record),
              ],
            ),
            const DeviceNotice('一次连接一台录音卡。设备记录仅保存在本机。'),
          ],
        ],
      ),
    );
  }

  Widget _deviceRow(
    BuildContext context,
    RecorderDeviceViewModel m,
    SavedRecorderDevice record,
  ) {
    final current = m.isCurrent(record);
    final online = current && m.connected;
    final serial = online
        ? m.info.serialNumber ?? record.serialNumber
        : record.serialNumber;
    final subtitle = [
      '录音卡',
      m.failedConnectionId == record.device.id &&
              m.connection == RecorderConnection.disconnected
          ? '连接失败'
          : current
          ? deviceConnectionLabel(m.connection)
          : '未连接',
      if (m.savedDevices.length > 1 && serial != null) maskedSerial(serial),
    ].join(' · ');
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      leading: const AiVoiceProductArtwork(size: 52),
      title: Text(
        record.displayName,
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
      subtitle: Text(subtitle),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (online && (m.info.battery != null || m.info.charging == true))
            Text(
              m.info.charging == true ? '充电中' : '${m.info.battery}%',
              style: TextStyle(color: HomeStyle.secondary(context)),
            ),
          const Icon(Icons.chevron_right, size: 20),
        ],
      ),
      onTap: () => context.push(
        '/profile/recording-device/${Uri.encodeComponent(record.recordId)}',
      ),
    );
  }
}
