import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import '../../../app/l10n/app_strings.dart';
import '../services/system_access.dart';
import '../viewmodels/profile_view_model.dart';
import 'profile_components.dart';

class ProfilePreferences extends StatefulWidget {
  const ProfilePreferences({super.key});

  @override
  State<ProfilePreferences> createState() => _ProfilePreferencesState();
}

class _ProfilePreferencesState extends State<ProfilePreferences> {
  bool _requesting = false;

  Future<void> _save(
    Future<bool> Function() action, {
    bool feedback = true,
  }) async {
    final vm = context.read<ProfileViewModel>();
    if (vm.saving || !vm.ready || _requesting) return;
    final ok = await action();
    if (!mounted) return;
    if (!ok) {
      profileFeedback(context, vm.error ?? '保存未完成，请重试');
    } else if (feedback && vm.data.hapticFeedback) {
      await HapticFeedback.selectionClick();
    }
  }

  Future<void> _notifications(bool value) async {
    final vm = context.read<ProfileViewModel>();
    if (_requesting || vm.saving || !vm.ready) return;
    setState(() => _requesting = true);
    try {
      if (value) {
        final access = context.read<SystemAccessService>();
        var states = await access.read();
        if (states[SystemAccess.notifications] == PermissionStatus.denied) {
          await access.request(SystemAccess.notifications);
          states = await access.read();
        }
        final status = states[SystemAccess.notifications];
        if (status != PermissionStatus.granted &&
            status != PermissionStatus.provisional) {
          if (mounted) profileFeedback(context, '请先在系统设置中允许通知');
          return;
        }
      }
      if (!mounted) return;
      final ok = await vm.setBackgroundNotifications(value);
      if (!mounted) return;
      if (!ok) {
        profileFeedback(context, vm.error ?? '保存未完成，请重试');
      } else if (vm.data.hapticFeedback) {
        await HapticFeedback.selectionClick();
      }
    } catch (_) {
      if (mounted) profileFeedback(context, '权限状态读取失败，请重试');
    } finally {
      if (mounted) setState(() => _requesting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<ProfileViewModel>();
    final data = vm.data;
    final colors = Theme.of(context).colorScheme;
    final disabled = vm.loading || vm.saving || !vm.ready || _requesting;
    final tint = colors.primary.withValues(alpha: .065);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4),
          child: Text(
            '系统偏好与交互体验'.tr(context),
            style: TextStyle(
              fontSize: 12,
              height: 1.5,
              color: colors.onSurfaceVariant,
            ),
          ),
        ),
        const SizedBox(height: 9),
        ProfileSurface(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                LayoutBuilder(
                  builder: (context, constraints) {
                    final title = Text(
                      '外观主题模式'.tr(context),
                      style: TextStyle(fontSize: 14, color: colors.onSurface),
                    );
                    final current = Text(
                      (data.appearance == 'system'
                              ? '跟随系统'
                              : data.appearance == 'light'
                              ? '浅色'
                              : '深色')
                          .tr(context),
                      style: TextStyle(
                        fontSize: 12,
                        color: colors.onSurfaceVariant,
                      ),
                    );
                    if (constraints.maxWidth < 280 ||
                        MediaQuery.textScalerOf(context).scale(12) > 18) {
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [title, const SizedBox(height: 5), current],
                      );
                    }
                    return Row(
                      children: [
                        Expanded(child: title),
                        const SizedBox(width: 12),
                        current,
                      ],
                    );
                  },
                ),
                const SizedBox(height: 12),
                LayoutBuilder(
                  builder: (context, constraints) {
                    final vertical =
                        constraints.maxWidth < 240 ||
                        MediaQuery.textScalerOf(context).scale(13) > 19;
                    final options = [
                      ('light', '浅色', Icons.light_mode_outlined),
                      ('dark', '深色', Icons.dark_mode_outlined),
                      ('system', '跟随系统', Icons.devices_outlined),
                    ];
                    Widget option((String, String, IconData) item) {
                      final selected = data.appearance == item.$1;
                      return Semantics(
                        selected: selected,
                        child: AnimatedContainer(
                          duration: MediaQuery.disableAnimationsOf(context)
                              ? Duration.zero
                              : const Duration(milliseconds: 180),
                          decoration: BoxDecoration(
                            color: selected
                                ? colors.surfaceContainerLowest
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(11),
                            border: Border.all(
                              color: selected
                                  ? colors.primary.withValues(alpha: .12)
                                  : Colors.transparent,
                            ),
                          ),
                          child: TextButton(
                            key: ValueKey('profile-theme-${item.$1}'),
                            onPressed: disabled
                                ? null
                                : () => _save(() => vm.setAppearance(item.$1)),
                            style: TextButton.styleFrom(
                              foregroundColor: selected
                                  ? colors.primary
                                  : colors.onSurface,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 4,
                                vertical: 10,
                              ),
                              minimumSize: const Size(48, 44),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(11),
                              ),
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(item.$3, size: 17),
                                const SizedBox(width: 5),
                                Flexible(
                                  child: Text(
                                    item.$2.tr(context),
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: selected
                                          ? FontWeight.w600
                                          : FontWeight.w400,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    }

                    return Container(
                      key: const ValueKey('profile-appearance'),
                      padding: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        color: tint,
                        borderRadius: BorderRadius.circular(15),
                      ),
                      child: vertical
                          ? Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                for (final item in options) option(item),
                              ],
                            )
                          : Row(
                              children: [
                                for (final item in options)
                                  Expanded(child: option(item)),
                              ],
                            ),
                    );
                  },
                ),
                const SizedBox(height: 20),
                _row(
                  context,
                  icon: Icons.language,
                  title: '界面语言',
                  subtitle: '选择适合你的界面语言',
                  control: Container(
                    constraints: const BoxConstraints(
                      minWidth: 88,
                      maxWidth: 132,
                    ),
                    child: PopupMenuButton<String>(
                      key: const ValueKey('profile-language'),
                      enabled: !disabled,
                      position: PopupMenuPosition.under,
                      offset: const Offset(0, 8),
                      color: colors.surfaceContainerLowest,
                      surfaceTintColor: Colors.transparent,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                      tooltip: '语言'.tr(context),
                      onSelected: (value) => _save(() => vm.setLanguage(value)),
                      itemBuilder: (context) => [
                        for (final option in [
                          ('zh', '简体中文'),
                          ('en', 'English'),
                          ('system', '跟随系统'),
                        ])
                          PopupMenuItem<String>(
                            key: ValueKey('profile-option-${option.$1}'),
                            value: option.$1,
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    option.$2.tr(context),
                                    style: TextStyle(
                                      fontSize: 14,
                                      color: colors.onSurface,
                                    ),
                                  ),
                                ),
                                if (data.language == option.$1) ...[
                                  const SizedBox(width: 12),
                                  Icon(
                                    Icons.check_rounded,
                                    size: 18,
                                    color: colors.primary,
                                  ),
                                ],
                              ],
                            ),
                          ),
                      ],
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                (data.language == 'en'
                                        ? 'English'
                                        : data.language == 'zh'
                                        ? '简体中文'
                                        : '跟随系统')
                                    .tr(context),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 12,
                                  height: 1.4,
                                  color: colors.onSurface,
                                ),
                              ),
                            ),
                            const SizedBox(width: 4),
                            const Icon(Icons.chevron_right_rounded, size: 18),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                _row(
                  context,
                  icon: Icons.vibration_outlined,
                  title: '关键决策触觉反馈',
                  subtitle: '在决策确认和权限变更时给予轻微振动',
                  control: _switch(
                    context,
                    key: 'profile-haptics',
                    value: data.hapticFeedback,
                    onChanged: disabled
                        ? null
                        : (value) => _save(() => vm.setHapticFeedback(value)),
                  ),
                ),
                const SizedBox(height: 20),
                _row(
                  context,
                  icon: Icons.notifications_none_outlined,
                  title: '后台任务完成通知',
                  subtitle: '收到待确认事项或后台任务结果时提醒',
                  control: _switch(
                    context,
                    key: 'profile-background-notifications',
                    value: data.backgroundNotifications,
                    onChanged: disabled ? null : _notifications,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _switch(
    BuildContext context, {
    required String key,
    required bool value,
    required ValueChanged<bool>? onChanged,
  }) {
    final colors = Theme.of(context).colorScheme;
    return Switch(
      key: ValueKey(key),
      value: value,
      onChanged: onChanged,
      activeTrackColor: colors.primary,
      activeThumbColor: colors.surfaceContainerLowest,
      inactiveThumbColor: colors.surfaceContainerLowest,
      inactiveTrackColor: colors.primary.withValues(alpha: .17),
      trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
    );
  }

  Widget _row(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String subtitle,
    required Widget control,
  }) => ProfileSettingRow(
    icon: icon,
    title: title,
    subtitle: subtitle,
    control: control,
    stackControl: true,
  );
}
