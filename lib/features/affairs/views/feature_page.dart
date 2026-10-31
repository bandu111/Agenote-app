import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../../app/router/destinations.dart';
import '../../../shared/widgets/page_components.dart';

class FeaturePage extends StatelessWidget {
  const FeaturePage(this.destination, {super.key});
  final Destination destination;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(destination.title),
      leading: BackButton(
        onPressed: () =>
            context.canPop() ? context.pop() : context.go(AppRoutes.affairs),
      ),
    ),
    body: PageBody(
      children: [
        Icon(
          destination.icon,
          size: 48,
          color: Theme.of(context).colorScheme.primary,
        ),
        const SizedBox(height: 24),
        Text(
          destination == Destination.about ? '言枢' : '暂未开放',
          style: Theme.of(context).textTheme.headlineMedium,
        ),
        const SizedBox(height: 12),
        Text(destination.description),
        const SizedBox(height: 32),
        for (final child in destination.children) ...[
          SettingsRow(child),
          const Divider(),
        ],
        if (destination == Destination.permissions) ...[
          const SwitchListTile.adaptive(
            value: false,
            onChanged: null,
            title: Text('自动创建内部暂定日程'),
          ),
          const SwitchListTile.adaptive(
            value: false,
            onChanged: null,
            title: Text('自动创建内部个人待办'),
          ),
          const SwitchListTile.adaptive(
            value: false,
            onChanged: null,
            title: Text('会前自动准备'),
          ),
        ],
      ],
    ),
  );
}
