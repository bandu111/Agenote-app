import '../../shared/widgets/content_skeleton.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../../app/l10n/app_strings.dart';
import '../home/views/home_style.dart';
import 'notification_model.dart';
import 'local_notifications.dart';
import 'account_actions.dart';
import 'package:permission_handler/permission_handler.dart';

/// Tooltips and menus on global controls need an overlay above the router.
class NotificationOverlay extends StatefulWidget {
  const NotificationOverlay({super.key, required this.child});
  final Widget child;
  @override
  State<NotificationOverlay> createState() => _NotificationOverlayState();
}

class _NotificationOverlayState extends State<NotificationOverlay> {
  late final _entry = OverlayEntry(builder: (_) => widget.child);
  @override
  void didUpdateWidget(NotificationOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    _entry.markNeedsBuild();
  }

  @override
  void dispose() {
    _entry.remove();
    _entry.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Overlay(initialEntries: [_entry]);
}

class NotificationAction extends StatelessWidget {
  const NotificationAction({super.key});
  @override
  Widget build(BuildContext context) {
    final count = context.select<NotificationModel, int>((m) => m.pendingCount);
    final icon = Badge(
      isLabelVisible: count > 0,
      label: Text(count > 99 ? '99+' : '$count'),
      child: const Icon(Icons.notifications_none_rounded),
    );
    void open() {
      context.read<NotificationModel>().dismissPrompt();
      context.push('/notifications');
    }

    return IconButton(tooltip: '通知'.tr(context), onPressed: open, icon: icon);
  }
}

/// Above the router so incoming prompts are visible from every app screen.
class NotificationHost extends StatefulWidget {
  const NotificationHost({
    super.key,
    required this.child,
    required this.router,
    required this.navigatorKey,
  });
  final Widget child;
  final GoRouter router;
  final GlobalKey<NavigatorState> navigatorKey;
  @override
  State<NotificationHost> createState() => _NotificationHostState();
}

class _NotificationHostState extends State<NotificationHost> {
  Timer? _timer;
  int _revision = -1;
  NotificationModel? _model;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final model = context.read<NotificationModel>();
    if (!identical(model, _model)) {
      _model?.removeListener(_promptChanged);
      _model = model;
      model.addListener(_promptChanged);
      _revision = -1;
      _promptChanged();
    }
  }

  void _promptChanged() {
    final model = _model!;
    if (_revision == model.promptRevision && model.prompt != null) return;
    _revision = model.promptRevision;
    _timer?.cancel();
    if (model.prompt != null) {
      final revision = _revision;
      _timer = Timer(const Duration(seconds: 8), () {
        if (mounted && model.promptRevision == revision) model.dismissPrompt();
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _model?.removeListener(_promptChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final model = context.watch<NotificationModel>();
    return ListenableBuilder(
      listenable: widget.router.routeInformationProvider,
      builder: (context, _) {
        final path = widget.router.routeInformationProvider.value.uri.path;
        final isCenter = path == '/notifications';
        final navigatorContext = widget.navigatorKey.currentContext;
        return Stack(
          children: [
            widget.child,
            if (model.prompt != null && !isCenter && navigatorContext != null)
              Positioned(
                top: MediaQuery.paddingOf(context).top + 8,
                left: 16,
                right: 16,
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 480),
                    child: Material(
                      elevation: 3,
                      borderRadius: BorderRadius.circular(16),
                      clipBehavior: Clip.antiAlias,
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                          maxHeight: MediaQuery.sizeOf(context).height * .6,
                        ),
                        child: SingleChildScrollView(
                          child: _NoticeCard(
                            notice: model.prompt!,
                            popup: true,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class NotificationsPage extends StatelessWidget {
  const NotificationsPage({super.key});
  @override
  Widget build(BuildContext context) {
    final model = context.watch<NotificationModel>();
    return Scaffold(
      appBar: AppBar(
        title: Text('通知'.tr(context)),
        actions: [
          TextButton(
            onPressed: model.canClear
                ? () async {
                    final count = model.clearAll();
                    await model.flushInbox();
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context)
                      ..hideCurrentSnackBar()
                      ..showSnackBar(
                        SnackBar(
                          content: Text(
                            model.persistenceError ?? '已清除 $count 条通知',
                          ),
                        ),
                      );
                  }
                : null,
            child: Text('清空'.tr(context)),
          ),
        ],
      ),
      bottomNavigationBar: const NotificationDeliveryStatus(),
      body: SafeArea(
        top: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: model.loading && model.items.isEmpty
                ? const ContentSkeleton(label: '正在加载通知')
                : model.loadError != null
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('通知暂时读取失败'.tr(context)),
                        TextButton(
                          onPressed: model.refresh,
                          child: Text('重试'.tr(context)),
                        ),
                      ],
                    ),
                  )
                : model.items.isEmpty
                ? Center(child: Text('暂无通知'.tr(context)))
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                    itemCount: model.items.length + 1,
                    separatorBuilder: (_, _) => const SizedBox(height: 12),
                    itemBuilder: (context, index) => index == 0
                        ? Text(
                            '${'待确认'.tr(context)} · ${model.pendingCount}',
                            style: HomeStyle.text(14, bold: true),
                          )
                        : _NoticeCard(notice: model.items[index - 1]),
                  ),
          ),
        ),
      ),
    );
  }
}

class _NoticeCard extends StatelessWidget {
  const _NoticeCard({required this.notice, this.popup = false});
  final ActionNotice notice;
  final bool popup;
  @override
  Widget build(BuildContext context) {
    final model = context.watch<NotificationModel>();
    final colors = Theme.of(context).colorScheme;
    final pending = notice.state == NoticeState.pending;
    final busy = model.busy(notice.id);
    final warning = notice.kind == NoticeKind.warning;
    final tone = warning ? colors.error : colors.primary;
    Future<void> acknowledge() async {
      model.acknowledge(notice.id);
      await model.flushInbox();
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(content: Text(model.persistenceError ?? '已清除')),
        );
    }

    final stateLabel = switch (notice.state) {
      NoticeState.pending => notice.interrupts ? '待确认' : '不打扰',
      NoticeState.preparing => '处理中',
      NoticeState.allowed => switch (notice.allowLabel) {
        '确认' => '已确认',
        '知道了' => '已知悉',
        '记录' => '已记录',
        '归档' => '已归档',
        '重试' => '已提交重试',
        '打开日历' => '已打开日历编辑器',
        _ => '已允许',
      },
      NoticeState.declined => '已拒绝',
      NoticeState.completed => '已完成',
      NoticeState.unavailable => '已失效',
      NoticeState.cleared => '已清除',
    };
    final statusColor =
        notice.state == NoticeState.allowed ||
            notice.state == NoticeState.completed
        ? HomeStyle.teal
        : pending
        ? tone
        : HomeStyle.secondary(context);
    return Container(
      key: ValueKey('notice-${notice.id}'),
      decoration: BoxDecoration(
        color: HomeStyle.surface(context),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: tone.withValues(alpha: .12)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
            color: warning
                ? colors.error.withValues(alpha: .06)
                : HomeStyle.tintColor(context, const Color(0xFFF1F5FD)),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Icon(
                  warning
                      ? Icons.warning_amber_rounded
                      : Icons.auto_awesome_outlined,
                  size: 16,
                  color: tone,
                ),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    notice.title.tr(context),
                    style: HomeStyle.text(
                      13,
                      bold: true,
                      color: warning ? tone : null,
                    ),
                    maxLines: MediaQuery.textScalerOf(context).scale(13) > 20
                        ? 2
                        : 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 7,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: statusColor.withValues(alpha: .08),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    stateLabel.tr(context),
                    style: HomeStyle.text(10, color: statusColor),
                  ),
                ),
                if (popup)
                  IconButton(
                    tooltip: '稍后处理'.tr(context),
                    visualDensity: VisualDensity.compact,
                    onPressed: model.dismissPrompt,
                    icon: const Icon(Icons.close, size: 16),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      pending ? Icons.back_hand_outlined : Icons.task_alt,
                      size: 18,
                      color: statusColor,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        notice.instruction.tr(context),
                        style: HomeStyle.text(13, bold: pending),
                      ),
                    ),
                  ],
                ),
                if (model.error(notice.id) != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    model.error(notice.id)!.tr(context),
                    style: HomeStyle.text(12, color: colors.error),
                  ),
                ],
                if (pending) ...[
                  const SizedBox(height: 6),
                  Align(
                    alignment: Alignment.centerRight,
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      alignment: WrapAlignment.end,
                      children: [
                        if (notice.kind != NoticeKind.information &&
                            notice.allowLabel != '知道了')
                          OutlinedButton(
                            key: ValueKey('decline-${notice.id}'),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: HomeStyle.secondary(context),
                              side: BorderSide(
                                color: colors.primary.withValues(alpha: .16),
                              ),
                              minimumSize: const Size(60, 34),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                              ),
                              textStyle: HomeStyle.text(12),
                            ),
                            onPressed: busy
                                ? null
                                : () {
                                    if (notice.id.startsWith(
                                      'progress-pending:',
                                    )) {
                                      model.postpone(notice.id);
                                    } else {
                                      model.decide(notice.id, allow: false);
                                    }
                                  },
                            child: Text(
                              (notice.id.startsWith('progress-pending:')
                                      ? '暂不处理'
                                      : '拒绝')
                                  .tr(context),
                            ),
                          ),
                        if (notice.kind != NoticeKind.information &&
                            (notice.interrupts || notice.allowLabel != '知道了'))
                          FilledButton(
                            key: ValueKey('allow-${notice.id}'),
                            style: FilledButton.styleFrom(
                              backgroundColor: colors.primary,
                              foregroundColor: colors.onPrimary,
                              minimumSize: const Size(60, 34),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                              ),
                              textStyle: HomeStyle.text(12, bold: true),
                            ),
                            onPressed: busy
                                ? null
                                : () => model.decide(notice.id, allow: true),
                            child: Text(
                              (busy ? '处理中' : notice.allowLabel).tr(context),
                            ),
                          ),
                        if (!notice.interrupts)
                          TextButton(
                            onPressed: busy ? null : acknowledge,
                            child: Text('知道了'.tr(context)),
                          ),
                      ],
                    ),
                  ),
                ],
                if (!pending)
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: busy ? null : acknowledge,
                      child: Text('知道了'.tr(context)),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 仅异常时出现，沿用通知页配色；不额外制造弹窗打扰。
class NotificationDeliveryStatus extends StatelessWidget {
  const NotificationDeliveryStatus({super.key});
  @override
  Widget build(BuildContext context) {
    final local = context.watch<LocalNotifications?>();
    final actions = context.watch<AccountActions?>();
    final error = local?.error ?? actions?.error;
    if (error == null) return const SizedBox.shrink();
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Material(
          color: HomeStyle.tint(context),
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(error, style: HomeStyle.text(13)),
                Wrap(
                  spacing: 12,
                  children: [
                    TextButton(
                      onPressed: () async {
                        await local?.retry();
                        await actions?.refresh();
                      },
                      child: const Text('重试'),
                    ),
                    if (local?.error != null)
                      TextButton(
                        onPressed: openAppSettings,
                        child: const Text('系统设置'),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
