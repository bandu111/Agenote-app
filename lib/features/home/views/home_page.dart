import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:provider/provider.dart';
import '../viewmodels/home_view_model.dart';
import '../viewmodels/schedule_view_model.dart';
import 'home_style.dart';
import 'schedule_section.dart';
import 'weekly_rhythm_card.dart';
import 'package:go_router/go_router.dart';
import '../../notifications/notification_views.dart';
import '../../meeting/meeting_view_model.dart';
import '../../profile/viewmodels/profile_view_model.dart';
import '../../recording_device/recorder_device_view_model.dart';
import '../../recording_device/recorder_device_widgets.dart';
import 'recording_source_sheet.dart';
import '../../recording_device/ai_voice_product_artwork.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  ScheduleViewModel? _schedule;
  bool _foreground = true;
  bool _visible = true;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _schedule = context.read<ScheduleViewModel>();
    _visible = TickerMode.valuesOf(context).enabled;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _syncClock();
        context.read<RecorderDeviceViewModel>().initialize();
      }
    });
  }

  void _syncClock() {
    if (_foreground && _visible) {
      _schedule?.resume();
      // Returning from a meeting must fetch newly generated minutes actions,
      // rather than only restarting the clock and waiting for periodic polling.
      if (_schedule != null && !_schedule!.loading) {
        _schedule!.refresh(resetDateToToday: true);
      }
    } else {
      _schedule?.pause();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _syncClock();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      Consumer2<HomeViewModel, MeetingViewModel>(
        builder: (context, home, meeting, _) => Scaffold(
          backgroundColor: HomeStyle.canvas(context),
          body: SafeArea(
            bottom: false,
            child: CustomScrollView(
              key: const PageStorageKey('home-scroll'),
              slivers: [
                SliverAppBar(
                  key: const ValueKey('home-pinned-header'),
                  pinned: true,
                  primary: false,
                  automaticallyImplyLeading: false,
                  backgroundColor: HomeStyle.canvas(context),
                  surfaceTintColor: Colors.transparent,
                  elevation: 0,
                  scrolledUnderElevation: 0,
                  titleSpacing: 0,
                  toolbarHeight:
                      MediaQuery.textScalerOf(context).scale(21) * 1.25 + 12,
                  title: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 600),
                      child: const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 16),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            Expanded(child: _StatusHeader()),
                            SizedBox(width: 4),
                            NotificationAction(),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                SliverToBoxAdapter(
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 600),
                      child: Padding(
                        padding: EdgeInsets.fromLTRB(
                          16,
                          24,
                          16,
                          meeting.active && home.sessionCapsuleHidden ? 84 : 24,
                        ),
                        child: const Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _DeviceCard(),
                            SizedBox(height: 14),
                            WeeklyRhythmCard(),
                            SizedBox(height: 14),
                            ScheduleSection(),
                            SizedBox(height: 16),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          bottomNavigationBar: meeting.active && !home.sessionCapsuleHidden
              ? const _SessionCapsule()
              : null,
          floatingActionButton: meeting.active && home.sessionCapsuleHidden
              ? const _CollapsedSessionEntry()
              : null,
          floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
        ),
      );
}

class _StatusHeader extends StatefulWidget {
  const _StatusHeader();
  @override
  State<_StatusHeader> createState() => _StatusHeaderState();
}

class _StatusHeaderState extends State<_StatusHeader>
    with WidgetsBindingObserver {
  Timer? _timer;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _armClock();
  }

  void _armClock() {
    _timer?.cancel();
    final now = DateTime.now();
    _timer = Timer(
      Duration(milliseconds: 60000 - now.second * 1000 - now.millisecond),
      () {
        if (!mounted) return;
        setState(() {});
        _armClock();
      },
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      setState(() {});
      _armClock();
    } else {
      _timer?.cancel();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now().toLocal();
    final name = context.select<ProfileViewModel, String>(
      (profile) => profile.data.name.trim(),
    );
    final greeting = now.hour >= 6 && now.hour < 12
        ? '上午好'
        : now.hour >= 12 && now.hour < 18
        ? '下午好'
        : '晚上好';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        GestureDetector(
          onLongPress: kDebugMode ? () => _showClockControls(context) : null,
          child: Text(
            name.isEmpty ? greeting : '$greeting，$name',
            key: const ValueKey('home-greeting'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: HomeStyle.text(
              21,
              bold: true,
              color: HomeStyle.foreground(context),
            ),
          ),
        ),
      ],
    );
  }
}

class _DeviceCard extends StatelessWidget {
  const _DeviceCard();

  @override
  Widget build(BuildContext context) {
    final device = context.watch<RecorderDeviceViewModel>();
    final meeting = context.watch<MeetingViewModel>();
    final connected = device.connected;
    final saved = device.selected == null
        ? null
        : device.savedFor(device.selected!.id);
    final record = connected
        ? saved
        : (device.savedDevices.isEmpty ? null : device.savedDevices.first);
    final name = record?.displayName ?? 'AI Voice';
    final info = device.info;
    final battery = connected ? info.battery : null;
    final usage = connected ? info.usage : null;
    final status = connected ? '已连接' : deviceConnectionLabel(device.connection);
    void details() {
      if (record == null) {
        context.push('/profile/recording-device');
      } else {
        context.push(
          '/profile/recording-device/${Uri.encodeComponent(record.recordId)}',
        );
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(child: HomeSectionTitle('设备与硬件')),
            Icon(
              Icons.circle,
              size: 7,
              color: connected ? HomeStyle.blue : HomeStyle.secondary(context),
            ),
            const SizedBox(width: 5),
            Text(
              status,
              style: HomeStyle.text(
                12,
                color: connected
                    ? HomeStyle.blue
                    : HomeStyle.secondary(context),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Container(
          key: const ValueKey('device-card'),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: HomeStyle.surface(context),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: HomeStyle.secondary(context).withValues(alpha: .18),
            ),
          ),
          child: Column(
            children: [
              InkWell(
                onTap: details,
                borderRadius: BorderRadius.circular(12),
                child: Row(
                  children: [
                    Container(
                      width: 60,
                      height: 60,
                      decoration: BoxDecoration(
                        color: HomeStyle.tint(context),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: const AiVoiceProductArtwork(size: 54),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: HomeStyle.text(15, bold: true),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            record == null
                                ? '添加 AI Voice 录音卡'
                                : [
                                    'AI Voice 录音卡',
                                    if (record.device.productType != null)
                                      record.device.productType!,
                                    if ((connected
                                            ? info.firmware
                                            : record.firmware) !=
                                        null)
                                      '固件 ${connected ? info.firmware : record.firmware}',
                                  ].join(' · '),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: HomeStyle.text(
                              11,
                              color: HomeStyle.secondary(context),
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            connected
                                ? deviceRecordingLabel(device.recording)
                                : '连接设备后查看状态',
                            style: HomeStyle.text(
                              11,
                              color: HomeStyle.secondary(context),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Icon(
                      Icons.chevron_right,
                      color: HomeStyle.secondary(context),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  Expanded(
                    child: _DeviceMetric(
                      label: '电量',
                      value: battery == null
                          ? (connected && info.charging == true ? '充电中' : '未获取')
                          : '$battery%',
                      progress: battery == null ? null : battery / 100,
                      color: HomeStyle.blue,
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: _DeviceMetric(
                      label: '存储',
                      value: usage == null
                          ? '未获取'
                          : '${deviceCapacity(info.usedKb)} / ${deviceCapacity(info.totalKb)}',
                      progress: usage,
                      color: HomeStyle.secondary(context),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      key: const ValueKey('connect-device'),
                      onPressed: () => showRecordingSourceSheet(context),
                      style: FilledButton.styleFrom(
                        backgroundColor: HomeStyle.blue,
                        minimumSize: const Size(0, 40),
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        textStyle: HomeStyle.text(13, bold: true),
                        shape: const StadiumBorder(),
                      ),
                      icon: const Icon(Icons.mic_none, size: 18),
                      label: Text(
                        meeting.active || meeting.busy ? '查看会议' : '开始录音',
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton(
                    key: const ValueKey('device-details-button'),
                    onPressed: details,
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(76, 40),
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      textStyle: HomeStyle.text(12),
                      foregroundColor: HomeStyle.secondary(context),
                      side: BorderSide(
                        color: HomeStyle.secondary(
                          context,
                        ).withValues(alpha: .18),
                      ),
                      shape: const StadiumBorder(),
                    ),
                    child: Text(record == null ? '我的设备' : '设备详情'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _DeviceMetric extends StatelessWidget {
  const _DeviceMetric({
    required this.label,
    required this.value,
    required this.progress,
    required this.color,
  });
  final String label, value;
  final double? progress;
  final Color color;
  @override
  Widget build(BuildContext context) => Column(
    children: [
      Row(
        children: [
          Text(
            label,
            style: HomeStyle.text(11, color: HomeStyle.secondary(context)),
          ),
          const Spacer(),
          Flexible(
            child: Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.end,
              style: HomeStyle.text(11, color: HomeStyle.secondary(context)),
            ),
          ),
        ],
      ),
      const SizedBox(height: 6),
      ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: LinearProgressIndicator(
          value: (progress ?? 0).clamp(0.0, 1.0),
          minHeight: 4,
          backgroundColor: HomeStyle.tint(context),
          color: color,
        ),
      ),
    ],
  );
}

class _CollapsedSessionEntry extends StatelessWidget {
  const _CollapsedSessionEntry();
  @override
  Widget build(BuildContext context) {
    final home = context.watch<HomeViewModel>();
    return FloatingActionButton.extended(
      key: const ValueKey('restore-session-capsule'),
      heroTag: 'home-active-meeting',
      onPressed: home.showSessionCapsule,
      backgroundColor: HomeStyle.surface(context),
      foregroundColor: HomeStyle.blue,
      elevation: 1,
      icon: const Icon(Icons.graphic_eq),
      label: const Text('会议进行中 · 展开'),
    );
  }
}

class _SessionCapsule extends StatelessWidget {
  const _SessionCapsule();
  @override
  Widget build(BuildContext context) {
    final home = context.watch<HomeViewModel>();
    const color = HomeStyle.blue;
    final capsule = Container(
      key: const ValueKey('session-capsule'),
      decoration: HomeStyle.card(context: context, radius: 32),
      child: InkWell(
        borderRadius: BorderRadius.circular(32),
        onTap: () => context.push('/meeting'),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 8, 2, 8),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: home.sessionActive
                      ? HomeStyle.tintColor(context, const Color(0xFFE2FAF7))
                      : HomeStyle.tintColor(context, const Color(0xFFEFF5FF)),
                ),
                child: Icon(Icons.mic_none, color: color),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('会议进行中', style: HomeStyle.text(13, bold: true)),
                    Text(
                      '点击返回当前会议',
                      style: HomeStyle.text(
                        11,
                        color: HomeStyle.secondary(context),
                      ),
                    ),
                  ],
                ),
              ),
              if (home.sessionActive)
                TextButton(
                  onPressed: () => context.push('/meeting'),
                  style: TextButton.styleFrom(
                    foregroundColor: const Color(0xFFE43A4C),
                    backgroundColor: HomeStyle.tintColor(
                      context,
                      const Color(0xFFFFEDF0),
                    ),
                    minimumSize: const Size(48, 32),
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                  ),
                  child: const Text('查看'),
                )
              else
                const Icon(Icons.graphic_eq, color: HomeStyle.blue, size: 20),
              IconButton(
                key: const ValueKey('hide-session-capsule'),
                tooltip: '隐藏会话入口',
                onPressed: home.hideSessionCapsule,
                color: HomeStyle.secondary(context),
                iconSize: 20,
                icon: const Icon(Icons.chevron_right),
              ),
            ],
          ),
        ),
      ),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
      child: Align(
        alignment: Alignment.centerRight,
        heightFactor: 1,
        child: MediaQuery.disableAnimationsOf(context)
            ? capsule
            : AnimatedSize(
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOutCubic,
                alignment: Alignment.centerRight,
                child: capsule,
              ),
      ),
    );
  }
}

Future<void> showSessionGuide(BuildContext context) =>
    showRecordingSourceSheet(context);

Future<void> _showClockControls(BuildContext context) async {
  final model = context.read<ScheduleViewModel>();
  final clock = model.clock;
  if (clock is! PreviewScheduleClock) return;
  await showModalBottomSheet<void>(
    context: context,
    useSafeArea: true,
    useRootNavigator: true,
    isScrollControlled: true,
    builder: (context) => StatefulBuilder(
      builder: (context, update) => SafeArea(
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('开发测试 · 模拟时间', style: HomeStyle.text(20, bold: true)),
                const SizedBox(height: 12),
                Text(
                  clock.toLocal(clock.now).toString().split('.').first,
                  style: HomeStyle.text(16),
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final step in const [
                      ('推进 30 分钟', Duration(minutes: 30)),
                      ('推进 1 小时', Duration(hours: 1)),
                      ('推进 1 天', Duration(days: 1)),
                    ])
                      OutlinedButton(
                        onPressed: () {
                          clock.advance(step.$2);
                          model.checkTime();
                          update(() {});
                        },
                        child: Text(step.$1),
                      ),
                    TextButton(
                      onPressed: () {
                        clock.reset();
                        model.checkTime();
                        update(() {});
                      },
                      child: const Text('恢复设备时间'),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                const Text('仅调试版本可用。不会改变设备系统时间，也不会写入真实日程。'),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
