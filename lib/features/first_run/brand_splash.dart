import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'brand_tokens.dart';

class BrandMark extends StatelessWidget {
  const BrandMark({super.key, this.size = 104});
  final double size;
  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(size * .28),
    child: ColoredBox(
      color: Colors.white,
      child: Padding(
        padding: EdgeInsets.all(size * .05),
        child: Image.asset(
          BrandAssets.logo,
          width: size * .9,
          height: size * .9,
          semanticLabel: 'Agenote 应用图标',
        ),
      ),
    ),
  );
}

/// Visible only while real initialization runs. No timer controls routing.
class BrandSplash extends StatefulWidget {
  const BrandSplash({super.key, this.error, this.onRetry});
  final String? error;
  final VoidCallback? onRetry;
  @override
  State<BrandSplash> createState() => _BrandSplashState();
}

class _BrandSplashState extends State<BrandSplash>
    with SingleTickerProviderStateMixin {
  late final _orbit = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 14),
  );
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (BrandMotion.reduced(context)) {
      _orbit.stop();
    } else {
      _orbit.repeat();
    }
  }

  @override
  void dispose() {
    _orbit.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnnotatedRegion<SystemUiOverlayStyle>(
    value: SystemUiOverlayStyle.light.copyWith(
      statusBarColor: Colors.transparent,
      systemNavigationBarColor: BrandColors.splash,
    ),
    child: Scaffold(
      backgroundColor: BrandColors.splash,
      body: Stack(
        children: [
          Positioned.fill(
            child: ExcludeSemantics(
              child: RepaintBoundary(
                child: CustomPaint(painter: _OrbitPainter(_orbit)),
              ),
            ),
          ),
          const Center(child: BrandMark()),
          Center(
            child: Transform.translate(
              offset: const Offset(0, 128),
              child: _Entrance(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Agenote',
                      style: BrandTypography.text(
                        34,
                        color: Colors.white,
                        height: 1,
                        spacing: -1,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      '记录会议，推进工作',
                      style: BrandTypography.text(
                        12,
                        color: Colors.white60,
                        spacing: 2.4,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(32, 16, 32, 20),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'Agenote',
                        style: BrandTypography.text(
                          10,
                          color: Colors.white54,
                          spacing: 2,
                        ),
                      ),
                      Text(
                        'Est. 2026',
                        style: BrandTypography.text(
                          10,
                          color: Colors.white54,
                          spacing: 2,
                        ),
                      ),
                    ],
                  ),
                  Column(
                    children: [
                      if (widget.error != null) ...[
                        Text(
                          widget.error!,
                          textAlign: TextAlign.center,
                          style: BrandTypography.text(
                            13,
                            color: Colors.white70,
                          ),
                        ),
                        TextButton(
                          onPressed: widget.onRetry,
                          child: const Text(
                            '重试',
                            style: TextStyle(color: Colors.white),
                          ),
                        ),
                      ],
                      const Divider(color: Colors.white12, height: 1),
                      const SizedBox(height: 12),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            'AI 会议理解与行动伙伴',
                            style: BrandTypography.text(
                              10,
                              color: Colors.white54,
                            ),
                          ),
                          Semantics(
                            liveRegion: true,
                            child: Text(
                              widget.error == null ? '正在准备' : '暂未就绪',
                              style: BrandTypography.text(
                                10,
                                color: Colors.white54,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

class _Entrance extends StatelessWidget {
  const _Entrance({required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    tween: Tween(begin: BrandMotion.reduced(context) ? 1 : 0, end: 1),
    duration: BrandMotion.reduced(context) ? Duration.zero : BrandMotion.enter,
    curve: BrandMotion.curve,
    builder: (_, t, child) => Opacity(
      opacity: t,
      child: Transform.translate(offset: Offset(0, 10 * (1 - t)), child: child),
    ),
    child: child,
  );
}

class _OrbitPainter extends CustomPainter {
  _OrbitPainter(this.animation) : super(repaint: animation);
  final Animation<double> animation;
  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    canvas.drawCircle(
      center,
      220,
      Paint()
        ..shader = const RadialGradient(
          colors: [Color(0x773B81FF), Color(0x001663F9)],
          stops: [0, 1],
        ).createShader(Rect.fromCircle(center: center, radius: 220)),
    );
    for (final radius in [80.0, 150.0, 190.0]) {
      canvas.drawCircle(
        center,
        radius,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = Colors.white.withValues(alpha: radius == 190 ? .06 : .10),
      );
    }
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: 80),
      animation.value * math.pi * 2,
      math.pi * .65,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..color = BrandColors.blueTop.withValues(alpha: .6),
    );
  }

  @override
  bool shouldRepaint(_OrbitPainter oldDelegate) =>
      oldDelegate.animation != animation;
}
