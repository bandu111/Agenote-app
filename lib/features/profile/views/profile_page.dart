import '../../../shared/widgets/content_skeleton.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../auth/viewmodels/auth_view_model.dart';
import 'package:provider/provider.dart';
import '../../../app/l10n/app_strings.dart';
import '../../home/viewmodels/home_view_model.dart';
import '../../meeting/meeting_view_model.dart';
import '../../progress/viewmodels/voice_evidence_controller.dart';
import '../viewmodels/profile_view_model.dart';
import 'profile_components.dart';
import 'profile_editor.dart';
import 'profile_permissions.dart';
import 'profile_preferences.dart';
import 'profile_security.dart';
import 'profile_summary_card.dart';
import '../../recording_device/recorder_device_view_model.dart';
import '../../voiceprint/voiceprint_page.dart';
import '../../voiceprint/voiceprint_repository.dart';

class ProfilePage extends StatelessWidget {
  const ProfilePage({super.key});
  @override
  Widget build(BuildContext context) {
    final vm = context.watch<ProfileViewModel>();
    final auth = context.watch<AuthViewModel>();
    final device = context.watch<RecorderDeviceViewModel>();
    final colors = Theme.of(context).colorScheme;
    final disabled = vm.loading || vm.saving || !vm.ready || auth.submitting;
    final saved = device.savedFor(device.selected?.id ?? '');
    final deviceSubtitle = device.connected
        ? '${saved?.displayName ?? 'AI Voice'} · 录音卡 · 已连接'
        : device.savedDevices.isNotEmpty
        ? '${device.savedDevices.first.displayName} · 未连接'
        : '添加并管理你的录音设备';
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 600),
            child: vm.loading && !vm.ready
                ? const ContentSkeleton(
                    layout: SkeletonLayout.detail,
                    label: '正在加载个人资料',
                  )
                : ListView(
                    key: const PageStorageKey('profile-scroll'),
                    padding: const EdgeInsets.fromLTRB(20, 14, 20, 30),
                    children: [
                      Text(
                        '我的'.tr(context),
                        style: TextStyle(
                          fontSize: 11,
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '账户与设备'.tr(context),
                        style: TextStyle(
                          fontSize: 24,
                          height: 1.35,
                          fontWeight: FontWeight.w600,
                          color: colors.onSurface,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '设备、权限与偏好都在这里调整。'.tr(context),
                        style: TextStyle(
                          fontSize: 12,
                          height: 1.5,
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 18),
                      if (vm.loading || vm.saving)
                        const LinearProgressIndicator(minHeight: 2),
                      if (vm.error != null) ...[
                        ProfileSurface(
                          child: ListTile(
                            title: Text(vm.error!.tr(context)),
                            trailing: TextButton(
                              onPressed: vm.loading || vm.saving
                                  ? null
                                  : vm.load,
                              child: Text('重试'.tr(context)),
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                      ],
                      ProfileSummaryCard(
                        data: vm.data,
                        enabled: !disabled,
                        onEdit: () => showProfileEditor(context),
                      ),
                      const SizedBox(height: 22),
                      _section(context, '账户与隐私'),
                      const SizedBox(height: 9),
                      ProfileSurface(
                        child: Column(
                          children: [
                            _navigationRow(
                              context,
                              key: 'profile-recording-device',
                              icon: Icons.mic_none_rounded,
                              title: '我的设备',
                              subtitle: deviceSubtitle,
                              trailing:
                                  device.connected &&
                                      device.info.battery != null
                                  ? '电量 ${device.info.battery}%'
                                  : null,
                              onTap: disabled
                                  ? null
                                  : () => context.push(
                                      '/profile/recording-device',
                                    ),
                            ),
                            _navigationRow(
                              context,
                              key: 'profile-wechat-assistant',
                              icon: Icons.forum_outlined,
                              title: '微信助手',
                              subtitle: '绑定微信，接收 AI 工作成果',
                              onTap: disabled
                                  ? null
                                  : () => context.push(
                                      '/profile/wechat-assistant',
                                    ),
                            ),
                            _navigationRow(
                              context,
                              key: 'profile-voiceprint',
                              icon: Icons.record_voice_over_outlined,
                              title: '我的声纹',
                              subtitle: '注册、验证与管理自己的声音',
                              onTap: disabled || !vm.repository.remoteActive
                                  ? null
                                  : () {
                                      final client = vm.repository.client!;
                                      final owner = client.accountId!.call()!;
                                      Navigator.of(
                                        context,
                                        rootNavigator: true,
                                      ).push(
                                        MaterialPageRoute(
                                          builder: (_) => VoiceprintPage(
                                            repository: VoiceprintRepository(
                                              client,
                                              owner,
                                            ),
                                            isMeetingRecording: () {
                                              final meeting = context
                                                  .read<MeetingViewModel>();
                                              return meeting.active ||
                                                  meeting.nativeRecordingActive;
                                            },
                                          ),
                                        ),
                                      );
                                    },
                            ),
                            _navigationRow(
                              context,
                              key: 'profile-permissions',
                              icon: Icons.shield_outlined,
                              title: '系统权限',
                              subtitle: '麦克风、通知与蓝牙',
                              onTap: disabled
                                  ? null
                                  : () => Navigator.of(context).push(
                                      MaterialPageRoute(
                                        builder: (_) =>
                                            const ProfilePermissionsPage(),
                                      ),
                                    ),
                            ),
                            if (auth.supportsAccountSecurity)
                              _navigationRow(
                                context,
                                key: 'profile-security',
                                icon: Icons.lock_outline_rounded,
                                title: '账户安全',
                                subtitle: '邮箱与密码管理',
                                onTap: disabled
                                    ? null
                                    : () => Navigator.of(context).push(
                                        MaterialPageRoute(
                                          builder: (_) =>
                                              const ProfileSecurityPage(),
                                        ),
                                      ),
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 22),
                      const ProfilePreferences(),
                      const SizedBox(height: 22),
                      OutlinedButton.icon(
                        key: const ValueKey('profile-logout'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: colors.error,
                          side: BorderSide(
                            color: colors.error.withValues(alpha: .22),
                          ),
                          minimumSize: const Size(48, 48),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                        onPressed: disabled ? null : () => _logout(context),
                        icon: const Icon(Icons.logout, size: 18),
                        label: Text('退出'.tr(context)),
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }

  Widget _section(BuildContext context, String text) => Padding(
    padding: const EdgeInsets.only(left: 4),
    child: Text(
      text.tr(context),
      style: TextStyle(
        fontSize: 12,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
        height: 1.5,
      ),
    ),
  );

  Widget _navigationRow(
    BuildContext context, {
    required String key,
    required IconData icon,
    required String title,
    required String subtitle,
    String? trailing,
    VoidCallback? onTap,
  }) {
    final colors = Theme.of(context).colorScheme;
    return InkWell(
      key: ValueKey(key),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        child: ProfileSettingRow(
          icon: icon,
          title: title,
          subtitle: subtitle,
          stackControl: true,
          control: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (trailing != null) ...[
                Text(
                  trailing,
                  style: TextStyle(
                    fontSize: 11,
                    color: colors.onSurfaceVariant,
                  ),
                ),
                const SizedBox(width: 6),
              ],
              Icon(
                Icons.chevron_right_rounded,
                size: 18,
                color: colors.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _logout(BuildContext context) async {
    final vm = context.read<ProfileViewModel>();
    final answer = await showDialog<bool>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: .38),
      builder: (context) => const _SignOutDialog(),
    );
    if (answer != true || !context.mounted) return;
    await context.read<MeetingViewModel>().suspendForLogout();
    if (!context.mounted) return;
    await context.read<VoiceEvidenceController>().suspend();
    if (!context.mounted) return;
    context.read<HomeViewModel>().endDemo();
    final auth = context.read<AuthViewModel>();
    final saved = await auth.signOut();
    if (!saved && context.mounted) {
      profileFeedback(context, auth.error ?? vm.error ?? '保存未完成，请重试');
    }
  }
}

class _SignOutDialog extends StatelessWidget {
  const _SignOutDialog();

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    const red = Color(0xFFC51E25);
    return Dialog(
      backgroundColor: colors.surfaceContainerLowest,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 380),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: red.withValues(alpha: .09),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(
                      Icons.logout_rounded,
                      size: 22,
                      color: red,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Text(
                      '是否退出登录？'.tr(context),
                      style: TextStyle(
                        fontSize: 18,
                        height: 1.35,
                        fontWeight: FontWeight.w600,
                        color: colors.onSurface,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 26),
              LayoutBuilder(
                builder: (context, constraints) {
                  final cancel = FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: colors.primary.withValues(alpha: .10),
                      foregroundColor: colors.onSurface,
                      minimumSize: const Size(48, 50),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 12,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      textStyle: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    onPressed: () => Navigator.pop(context, false),
                    child: Text('取消'.tr(context)),
                  );
                  final exit = FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: red,
                      foregroundColor: Colors.white,
                      minimumSize: const Size(48, 50),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 12,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      textStyle: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    onPressed: () => Navigator.pop(context, true),
                    child: Text('退出'.tr(context)),
                  );
                  if (MediaQuery.textScalerOf(context).scale(15) > 23) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [cancel, const SizedBox(height: 12), exit],
                    );
                  }
                  return Row(
                    children: [
                      Expanded(child: cancel),
                      const SizedBox(width: 12),
                      Expanded(child: exit),
                    ],
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class LocalAccountEntry extends StatelessWidget {
  const LocalAccountEntry({super.key});
  @override
  Widget build(BuildContext context) {
    final vm = context.watch<ProfileViewModel>();
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.lock_outline,
                  size: 48,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(height: 20),
                Text(
                  '已退出本机账户'.tr(context),
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 12),
                Text('你的资料保留在这台设备上。'.tr(context), textAlign: TextAlign.center),
                const SizedBox(height: 26),
                FilledButton(
                  key: const ValueKey('profile-resume'),
                  onPressed: vm.saving
                      ? null
                      : () async {
                          final saved = await vm.resumeLocalAccount();
                          if (!saved && context.mounted) {
                            profileFeedback(context, vm.error ?? '保存未完成，请重试');
                          }
                        },
                  child: Text('继续使用本机账户'.tr(context)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
