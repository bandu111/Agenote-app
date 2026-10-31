import 'content_skeleton.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../app/router/destinations.dart';
import '../../app/theme/app_theme.dart';
import '../../core/viewmodels/loadable_view_model.dart';

class PageBody extends StatelessWidget {
  const PageBody({
    super.key,
    required this.children,
    this.storageKey,
    this.onRefresh,
  });
  final List<Widget> children;
  final String? storageKey;
  final Future<void> Function()? onRefresh;
  @override
  Widget build(BuildContext context) {
    final content = CustomScrollView(
      key: PageStorageKey(storageKey),
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: [
        SliverToBoxAdapter(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 680),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 24, 24, 104),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: children,
                ),
              ),
            ),
          ),
        ),
      ],
    );
    return SafeArea(
      bottom: false,
      child: onRefresh == null
          ? content
          : RefreshIndicator(onRefresh: onRefresh!, child: content),
    );
  }
}

class Section extends StatelessWidget {
  const Section(this.title, this.message, {super.key, this.action});
  final String title;
  final String message;
  final Widget? action;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 20),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        Text(message),
        if (action != null) ...[const SizedBox(height: 8), action!],
      ],
    ),
  );
}

class SettingsRow extends StatelessWidget {
  const SettingsRow(this.destination, {super.key, this.subtitle});
  final Destination destination;
  final String? subtitle;
  @override
  Widget build(BuildContext context) => ListTile(
    contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
    leading: Icon(destination.icon, color: AppTheme.blue),
    title: Text(destination.title),
    subtitle: subtitle == null ? null : Text(subtitle!),
    trailing: const Icon(Icons.chevron_right, size: 20),
    onTap: () => context.pushNamed(destination.route),
  );
}

class LoadStatus extends StatelessWidget {
  const LoadStatus(this.model, {super.key});
  final LoadableViewModel model;
  @override
  Widget build(BuildContext context) {
    if (model.loading) {
      return const ContentSkeleton(rows: 1, scrollable: false);
    }
    if (model.error != null) {
      return Section(
        '加载未完成',
        model.error!,
        action: TextButton(onPressed: model.refresh, child: const Text('重试')),
      );
    }
    return const SizedBox.shrink();
  }
}
