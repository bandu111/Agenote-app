import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../l10n/app_strings.dart';

class MainShell extends StatefulWidget {
  const MainShell(this.shell, {super.key});
  final StatefulNavigationShell shell;
  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
    value: 1,
  );
  late int _lastIndex = widget.shell.currentIndex;
  late final Animation<double> _opacity = Tween<double>(
    begin: .82,
    end: 1,
  ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic));

  @override
  void didUpdateWidget(MainShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_lastIndex != widget.shell.currentIndex) {
      _lastIndex = widget.shell.currentIndex;
      if (MediaQuery.disableAnimationsOf(context)) {
        _controller.value = 1;
      } else {
        _controller.forward(from: 0);
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: FadeTransition(opacity: _opacity, child: widget.shell),
    bottomNavigationBar: NavigationBar(
      height: 52 + MediaQuery.textScalerOf(context).scale(12),
      selectedIndex: widget.shell.currentIndex,
      animationDuration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : const Duration(milliseconds: 240),
      onDestinationSelected: (index) {
        if (index != widget.shell.currentIndex) widget.shell.goBranch(index);
      },
      destinations: [
        NavigationDestination(
          icon: Icon(Icons.home_outlined),
          selectedIcon: Icon(Icons.home_rounded),
          label: '首页'.tr(context),
        ),
        NavigationDestination(
          icon: Icon(Icons.bar_chart_outlined),
          selectedIcon: Icon(Icons.bar_chart_rounded),
          label: '进展'.tr(context),
        ),
        NavigationDestination(
          icon: Icon(Icons.menu_book_outlined),
          selectedIcon: Icon(Icons.menu_book_rounded),
          label: '知识库'.tr(context),
        ),
        NavigationDestination(
          icon: Icon(Icons.person_outline),
          selectedIcon: Icon(Icons.person_rounded),
          label: '我的'.tr(context),
        ),
      ],
    ),
  );
}
