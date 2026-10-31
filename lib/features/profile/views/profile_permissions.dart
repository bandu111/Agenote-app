import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import '../../../app/l10n/app_strings.dart';
import '../services/system_access.dart';
import 'profile_components.dart';

class ProfilePermissionsPage extends StatefulWidget {
  const ProfilePermissionsPage({super.key});
  @override
  State<ProfilePermissionsPage> createState() => _ProfilePermissionsPageState();
}

class _ProfilePermissionsPageState extends State<ProfilePermissionsPage>
    with WidgetsBindingObserver {
  Map<SystemAccess, PermissionStatus> _states = {};
  Map<SystemSetting, bool?> _settings = {};
  bool _loading = true;
  bool _busy = false;
  bool _awaitingConsent = false;
  String? _error;
  int _revision = 0;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    final revision = ++_revision;
    final service = context.read<SystemAccessService>();
    if (mounted) setState(() => _loading = true);
    Map<SystemAccess, PermissionStatus>? states;
    Map<SystemSetting, bool?> settings = {};
    String? error;
    try {
      states = await service.read();
    } catch (_) {
      error = '权限状态读取失败，请重试';
    }
    if (service is SystemAccessSettingsService) {
      try {
        settings = await (service as SystemAccessSettingsService)
            .readSettings();
      } catch (_) {
        error = '录音状态权限读取失败，请重试';
      }
    }
    if (!mounted || revision != _revision) return;
    setState(() {
      _states = states ?? {};
      _settings = settings;
      _error = error;
      _loading = false;
    });
  }

  @override
  void dispose() {
    ++_revision;
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  String _status(PermissionStatus? status) => switch (status) {
    PermissionStatus.granted => '已允许',
    PermissionStatus.provisional => '安静通知已允许',
    PermissionStatus.limited => '仅允许部分照片',
    PermissionStatus.restricted => '受系统限制',
    PermissionStatus.permanentlyDenied => '需前往系统设置',
    PermissionStatus.denied => '未允许',
    _ => '尚未检测',
  };
  Future<void> _manage(SystemAccess access) async {
    if (_busy || _loading || !_states.containsKey(access)) return;
    final service = context.read<SystemAccessService>();
    final denied = _states[access] == PermissionStatus.denied;
    setState(() {
      _busy = true;
      _awaitingConsent = denied;
    });
    try {
      if (denied) {
        final description = _description(access);
        final proceed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text('允许${_title(access)}？'.tr(context)),
            content: Text(description.tr(context)),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text('取消'.tr(context)),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text('继续'.tr(context)),
              ),
            ],
          ),
        );
        if (proceed != true || !mounted) return;
        setState(() => _awaitingConsent = false);
        await service.request(access);
      } else {
        final opened = service is SystemAccessSettingsService
            ? await (service as SystemAccessSettingsService).settingsFor(
                access: access,
              )
            : await service.settings();
        if (!opened && mounted) profileFeedback(context, '无法打开系统设置');
      }
      if (mounted) await _refresh();
    } catch (_) {
      if (mounted) profileFeedback(context, '权限状态读取失败，请重试');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _awaitingConsent = false;
        });
      }
    }
  }

  Future<void> _manageSetting(SystemSetting setting) async {
    if (_busy || _loading) return;
    final service = context.read<SystemAccessService>();
    setState(() => _busy = true);
    try {
      final opened = service is SystemAccessSettingsService
          ? await (service as SystemAccessSettingsService).settingsFor(
              setting: setting,
            )
          : await service.settings();
      if (!opened && mounted) profileFeedback(context, '无法打开系统设置');
      if (mounted) await _refresh();
    } catch (_) {
      if (mounted) profileFeedback(context, '无法打开系统设置');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _awaitingConsent = false;
        });
      }
    }
  }

  String _title(SystemAccess access) => switch (access) {
    SystemAccess.microphone => '麦克风',
    SystemAccess.notifications => '通知',
    SystemAccess.bluetooth => '蓝牙与附近设备',
    SystemAccess.calendar => '日历',
    SystemAccess.photos => '照片',
    SystemAccess.camera => '相机',
  };
  String _description(SystemAccess access) => switch (access) {
    SystemAccess.microphone => '仅授权麦克风，不会开始录音。',
    SystemAccess.notifications => '由系统管理通知权限，你可以随时在设置中关闭。',
    SystemAccess.bluetooth =>
      '用于发现、连接录音卡及蓝牙音源。旧版 Android 扫描蓝牙还需要位置信息权限；授权不会开始扫描或录音。',
    SystemAccess.calendar => '仅在你确认安排后创建日程，并回读核对，不会立即创建日程。',
    SystemAccess.photos => '用于你主动选择的头像、图片和资料，可在系统中管理允许访问的照片。',
    SystemAccess.camera => '供图片选择组件拍摄资料时使用，授权不会开启拍摄。',
  };
  IconData _icon(SystemAccess access) => switch (access) {
    SystemAccess.microphone => Icons.mic_none,
    SystemAccess.notifications => Icons.notifications_none,
    SystemAccess.bluetooth => Icons.bluetooth_rounded,
    SystemAccess.calendar => Icons.calendar_month_outlined,
    SystemAccess.photos => Icons.photo_library_outlined,
    SystemAccess.camera => Icons.camera_alt_outlined,
  };

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text('系统权限'.tr(context))),
    body: SafeArea(
      top: false,
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          if ((_busy && !_awaitingConsent) || _loading)
            const LinearProgressIndicator(minHeight: 2),
          if (_error != null)
            ListTile(
              title: Text(_error!.tr(context)),
              trailing: TextButton(
                onPressed: _busy || _loading ? null : _refresh,
                child: Text('重试'.tr(context)),
              ),
            ),
          ProfileSurface(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                children: [
                  for (final access in _states.keys) ...[
                    if (access != _states.keys.first)
                      const SizedBox(height: 24),
                    InkWell(
                      key: ValueKey('system-permission-${access.name}'),
                      borderRadius: BorderRadius.circular(10),
                      onTap: _busy || _loading ? null : () => _manage(access),
                      child: ProfileSettingRow(
                        icon: _icon(access),
                        title: _title(access),
                        subtitle: _status(_states[access]),
                        stackControl: true,
                        control: const Icon(Icons.chevron_right, size: 18),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          if (_settings.isNotEmpty) ...[
            const SizedBox(height: 22),
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 9),
              child: Text(
                '录音状态展示'.tr(context),
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            ProfileSurface(
              child: Padding(
                padding: const EdgeInsets.all(18),
                child: Column(
                  children: [
                    for (final setting in _settings.keys) ...[
                      if (setting != _settings.keys.first)
                        const SizedBox(height: 24),
                      InkWell(
                        key: ValueKey('system-setting-${setting.name}'),
                        borderRadius: BorderRadius.circular(10),
                        onTap: _busy || _loading
                            ? null
                            : () => _manageSetting(setting),
                        child: ProfileSettingRow(
                          stackControl: true,
                          icon: setting == SystemSetting.liveActivities
                              ? Icons.sensors_rounded
                              : Icons.lock_outline_rounded,
                          title: setting == SystemSetting.liveActivities
                              ? '实时活动 / 流体云'
                              : '锁屏通知',
                          subtitle: _settings[setting] == null
                              ? '由系统管理，点击查看'
                              : _settings[setting] == true
                              ? '已允许'
                              : '未允许，前往系统设置开启',
                          control: const Icon(Icons.chevron_right, size: 18),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
          const SizedBox(height: 14),
          Text(
            '权限状态以系统设置为准，返回 App 后自动更新。文件导入使用系统文件选择器，无需授予整个存储空间的访问权限。'.tr(
              context,
            ),
            style: TextStyle(
              fontSize: 12,
              height: 1.6,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),

          TextButton.icon(
            onPressed: _busy
                ? null
                : () async {
                    try {
                      final opened = await context
                          .read<SystemAccessService>()
                          .settings();
                      if (!opened && context.mounted) {
                        profileFeedback(context, '无法打开系统设置');
                      }
                    } catch (_) {
                      if (context.mounted) {
                        profileFeedback(context, '无法打开系统设置');
                      }
                    }
                  },
            icon: const Icon(Icons.open_in_new, size: 18),
            label: Text('打开系统设置'.tr(context)),
          ),
        ],
      ),
    ),
  );
}
