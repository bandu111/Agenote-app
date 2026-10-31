import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../../meeting/meeting_services.dart';
import '../../meeting/meeting_view_model.dart';
import '../../recording_device/recorder_device_view_model.dart';
import '../../recording_device/soninote_meeting_coordinator.dart';
import 'home_style.dart';

Future<void> showRecordingSourceSheet(BuildContext context) async {
  final meeting = context.read<MeetingViewModel>();
  if (meeting.active || meeting.busy) {
    context.push('/meeting');
    return;
  }
  final source = await showModalBottomSheet<String>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: HomeStyle.canvas(context),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
    ),
    builder: (_) => const _RecordingSourceSheet(),
  );
  if (!context.mounted || source == null) return;
  if (source == 'manage') {
    context.push('/profile/recording-device');
    return;
  }
  // Recheck after closing the sheet: a physical key may have started a meeting.
  if (meeting.active || meeting.busy) {
    context.push('/meeting');
    return;
  }
  if (source == 'card') {
    final coordinator = context.read<SoniNoteMeetingCoordinator>();
    await coordinator.startMeeting();
    if (context.mounted && coordinator.error != null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(coordinator.error!)));
    }
    return;
  }
  final recorder = meeting.recorder;
  if (recorder is DeviceMeetingRecorder) {
    recorder.externalInput = null;
    recorder.inputPreference = source == 'phone'
        ? MeetingInputPreference.phone
        : MeetingInputPreference.bluetooth;
  }
  if (context.mounted) context.push('/meeting?record=1');
}

class _RecordingSourceSheet extends StatefulWidget {
  const _RecordingSourceSheet();
  @override
  State<_RecordingSourceSheet> createState() => _RecordingSourceSheetState();
}

class _RecordingSourceSheetState extends State<_RecordingSourceSheet> {
  bool _checking = true, _bluetooth = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    try {
      final recorder = context.read<MeetingViewModel>().recorder;
      final inputs = recorder is DeviceMeetingRecorder
          ? await recorder.availableInputs()
          : null;
      if (mounted) {
        setState(() {
          _checking = false;
          _error = null;
          _bluetooth =
              inputs != null &&
              selectMeetingInput(
                    inputs,
                    preference: MeetingInputPreference.bluetooth,
                  ) !=
                  null;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _checking = false;
          _error = '无法读取耳机状态，点击重试';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final device = context.watch<RecorderDeviceViewModel>();
    final connected = device.connected;
    final rows = <Widget>[
      _row(
        'phone',
        '手机麦克风',
        connected ? '使用手机内置麦克风' : '默认音源 · 使用手机内置麦克风',
        Icons.phone_iphone,
        true,
      ),
      _row(
        'card',
        'AI Voice 录音卡',
        connected
            ? '已连接${device.info.battery == null ? '' : ' · 电量 ${device.info.battery}%'} · 优先音源'
            : '未连接录音卡',
        Icons.mic_none,
        connected,
      ),
      _row(
        'bluetooth',
        '蓝牙耳机',
        _checking
            ? '正在检查耳机麦克风'
            : _error ?? (_bluetooth ? '已连接 · 使用耳机麦克风' : '目前不可用'),
        Icons.headphones_outlined,
        _bluetooth && !_checking,
      ),
    ];
    if (connected) {
      final card = rows.removeAt(1);
      rows.insert(0, card);
    }
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(22, 12, 22, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: HomeStyle.secondary(context).withValues(alpha: .25),
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '选择这次录音的音源',
                      style: HomeStyle.text(17, bold: true),
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    tooltip: '关闭',
                    style: IconButton.styleFrom(
                      backgroundColor: HomeStyle.tint(context),
                    ),
                    icon: const Icon(Icons.close, size: 18),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              ...rows,
              if (_error != null)
                TextButton(onPressed: _check, child: const Text('重新检查耳机')),
              const SizedBox(height: 4),
              Text(
                '同一场录音只对应一个会话。已有会议时将返回当前会议，不会重复创建。',
                style: HomeStyle.text(11, color: HomeStyle.secondary(context)),
              ),
              const SizedBox(height: 8),
              Center(
                child: TextButton.icon(
                  onPressed: () => Navigator.pop(context, 'manage'),
                  icon: const Icon(Icons.bluetooth, size: 16),
                  label: const Text('在「我的」里管理设备'),
                  style: TextButton.styleFrom(
                    foregroundColor: HomeStyle.blue,
                    textStyle: HomeStyle.text(12, bold: true),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _row(
    String source,
    String title,
    String note,
    IconData icon,
    bool enabled,
  ) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Material(
      color: enabled ? HomeStyle.surface(context) : HomeStyle.tint(context),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
          color: HomeStyle.secondary(context).withValues(alpha: .15),
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        key: ValueKey('recording-source-$source'),
        enabled: enabled,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        leading: Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            color: HomeStyle.tint(context),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(
            icon,
            size: 19,
            color: HomeStyle.blue.withValues(alpha: enabled ? 1 : .4),
          ),
        ),
        title: Text(title, style: HomeStyle.text(13, bold: true)),
        subtitle: Text(
          note,
          style: HomeStyle.text(11, color: HomeStyle.secondary(context)),
        ),
        trailing: enabled
            ? Icon(
                Icons.chevron_right,
                size: 19,
                color: HomeStyle.secondary(context),
              )
            : Text(
                _checking && source == 'bluetooth' ? '检测中' : '未连接',
                style: HomeStyle.text(10, color: HomeStyle.secondary(context)),
              ),
        onTap: enabled ? () => Navigator.pop(context, source) : null,
      ),
    ),
  );
}
