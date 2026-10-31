import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../../app/router/destinations.dart';
import '../../../shared/widgets/page_components.dart';

class AuthPlaceholderPage extends StatelessWidget {
  const AuthPlaceholderPage(this.route, {super.key});
  final String route;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(switch (route) {
        'login' => '登录',
        'register' => '注册',
        'setup' => '首次设置',
        _ => '欢迎来到言枢',
      }),
    ),
    body: PageBody(
      children: [
        Text('理解当下，提前一步。', style: Theme.of(context).textTheme.headlineMedium),
        const SizedBox(height: 16),
        const Text('账号与首次设置功能暂未开放。当前可浏览基础界面，尚未登录或连接后端。'),
        const SizedBox(height: 24),
        if (route == 'login')
          TextButton(
            onPressed: () => context.pushNamed('register'),
            child: const Text('去注册'),
          ),
        if (route == 'register')
          TextButton(
            onPressed: () =>
                context.canPop() ? context.pop() : context.goNamed('login'),
            child: const Text('返回登录'),
          ),
        FilledButton(
          onPressed: () => context.go(AppRoutes.home),
          child: const Text('浏览基础界面'),
        ),
      ],
    ),
  );
}
