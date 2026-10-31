import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'brand_tokens.dart';
import 'onboarding_visuals.dart';

const onboardingSlides = [
  (kicker: '听见，也理解', title: '不止记录，更理解会议。', body: '从发言到重点，让重要信息不再被淹没。'),
  (kicker: '让疑问有迹可循', title: '重要的，不再一闪而过。', body: '标记疑问，回看原话与依据，慢慢理清思路。'),
  (kicker: '从纪要到行动', title: '让会议，成为下一步的开始。', body: '整理结论与后续行动，让讨论真正推动工作。'),
];

class OnboardingPage extends StatefulWidget {
  const OnboardingPage({super.key, required this.onComplete});
  final Future<void> Function() onComplete;
  @override
  State<OnboardingPage> createState() => _OnboardingPageState();
}

class _OnboardingPageState extends State<OnboardingPage> {
  final _pages = PageController();
  int _index = 0;
  bool _saving = false, _moving = false;
  String? _error;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Only local assets are decoded; no permissions or recording are started.
    precacheImage(const AssetImage(BrandAssets.device), context);
    precacheImage(const AssetImage(BrandAssets.logo), context);
  }

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  Future<void> _go(int target) async {
    if (_saving || _moving || target < 0 || target > 2 || target == _index) {
      return;
    }
    if (BrandMotion.reduced(context)) {
      _pages.jumpToPage(target);
      return;
    }
    _moving = true;
    try {
      await _pages.animateToPage(
        target,
        duration: BrandMotion.page,
        curve: BrandMotion.curve,
      );
    } finally {
      _moving = false;
    }
  }

  Future<void> _complete() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.onComplete();
    } catch (_) {
      if (mounted) {
        setState(() {
          _error = '引导状态未能保存，请重试';
          _saving = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => AnnotatedRegion<SystemUiOverlayStyle>(
    value: SystemUiOverlayStyle.dark.copyWith(
      statusBarColor: Colors.transparent,
      systemNavigationBarColor: BrandColors.background,
    ),
    child: PopScope(
      canPop: _index == 0 && !_saving,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && !_saving && _index > 0) _go(_index - 1);
      },
      child: Scaffold(
        backgroundColor: BrandColors.background,
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Column(
                children: [
                  SizedBox(
                    height: 58,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Semantics(
                            liveRegion: true,
                            label: '第 ${_index + 1} 屏，共三屏',
                            excludeSemantics: true,
                            child: Text(
                              '0${_index + 1} / 03',
                              style: BrandTypography.text(
                                11,
                                color: BrandColors.muted,
                                spacing: 1.8,
                              ),
                            ),
                          ),
                          if (_index < 2)
                            TextButton(
                              key: const ValueKey('onboarding-skip'),
                              onPressed: _saving ? null : _complete,
                              style: TextButton.styleFrom(
                                minimumSize: const Size(48, 48),
                                foregroundColor: BrandColors.secondary,
                              ),
                              child: Text(
                                '跳过',
                                style: BrandTypography.text(
                                  12,
                                  color: BrandColors.secondary,
                                ),
                              ),
                            )
                          else
                            const SizedBox(width: 48),
                        ],
                      ),
                    ),
                  ),
                  Expanded(
                    child: PageView.builder(
                      controller: _pages,
                      itemCount: 3,
                      physics: _saving
                          ? const NeverScrollableScrollPhysics()
                          : null,
                      onPageChanged: (i) => setState(() => _index = i),
                      itemBuilder: (context, index) => _Slide(index: index),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(28, 4, 28, 20),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            for (var i = 0; i < 3; i++)
                              Semantics(
                                button: true,
                                selected: i == _index,
                                label: '第 ${i + 1} 屏',
                                child: InkWell(
                                  key: ValueKey('onboarding-dot-$i'),
                                  borderRadius: BorderRadius.circular(24),
                                  onTap: _saving ? null : () => _go(i),
                                  child: SizedBox(
                                    width: 48,
                                    height: 48,
                                    child: Center(
                                      child: AnimatedContainer(
                                        duration: BrandMotion.reduced(context)
                                            ? Duration.zero
                                            : BrandMotion.page,
                                        width: i == _index ? 24 : 6,
                                        height: 3,
                                        decoration: BoxDecoration(
                                          color: i == _index
                                              ? BrandColors.blue
                                              : BrandColors.ink.withValues(
                                                  alpha: .15,
                                                ),
                                          borderRadius: BorderRadius.circular(
                                            4,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                        if (_error != null)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: Semantics(
                              liveRegion: true,
                              child: Text(
                                _error!,
                                textAlign: TextAlign.center,
                                style: BrandTypography.text(
                                  12,
                                  color: const Color(0xFFB42332),
                                ),
                              ),
                            ),
                          ),
                        DecoratedBox(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(99),
                            gradient: const LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [BrandColors.blueTop, BrandColors.blue],
                            ),
                          ),
                          child: SizedBox(
                            width: double.infinity,
                            height: 54,
                            child: TextButton(
                              key: const ValueKey('onboarding-next'),
                              style: TextButton.styleFrom(
                                foregroundColor: Colors.white,
                                shape: const StadiumBorder(),
                              ),
                              onPressed: _saving
                                  ? null
                                  : () => _index == 2
                                        ? _complete()
                                        : _go(_index + 1),
                              child: Text(
                                _saving
                                    ? '正在保存…'
                                    : _index == 2
                                    ? '开始使用'
                                    : '继续',
                                style: BrandTypography.text(
                                  15,
                                  color: Colors.white,
                                  weight: FontWeight.w500,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class _Slide extends StatelessWidget {
  const _Slide({required this.index});
  final int index;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
      final height = math.max(
        box.maxHeight,
        scale > 1.2 ? 350 + 330 * scale : 500.0,
      );
      final slide = onboardingSlides[index];
      final text = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            slide.kicker,
            textAlign: TextAlign.center,
            style: BrandTypography.text(
              11,
              color: BrandColors.blue,
              spacing: 1.4,
            ),
          ),
          const SizedBox(height: 12),
          Semantics(
            header: true,
            child: Text(
              slide.title,
              textAlign: TextAlign.center,
              style: BrandTypography.text(
                27,
                weight: FontWeight.w500,
                height: 1.26,
                spacing: -.75,
              ),
            ),
          ),
          const SizedBox(height: 12),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 274),
            child: Text(
              slide.body,
              textAlign: TextAlign.center,
              style: BrandTypography.text(
                13,
                color: BrandColors.secondary,
                height: 22 / 13,
              ),
            ),
          ),
        ],
      );
      return SingleChildScrollView(
        key: ValueKey('onboarding-scroll-$index'),
        padding: const EdgeInsets.fromLTRB(28, 4, 28, 4),
        child: SizedBox(
          height: height - 8,
          child: Column(
            children: [
              if (index == 0) ...[
                const Spacer(),
                const RepaintBoundary(child: ListenVisual()),
                const SizedBox(height: 28),
                text,
                const Spacer(),
              ],
              if (index == 1) ...[
                text,
                const Spacer(),
                const RepaintBoundary(child: TraceVisual()),
                const SizedBox(height: 4),
              ],
              if (index == 2) ...[
                const RepaintBoundary(child: ActionVisual()),
                const Spacer(),
                text,
                const SizedBox(height: 8),
              ],
            ],
          ),
        ),
      );
    },
  );
}
