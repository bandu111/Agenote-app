import 'dart:math' as math;
import 'package:flutter/material.dart';

/// 仅包裹实际生成中的语音卡；动画不参与业务状态，也不改变列表布局。
class MeetingAiGlow extends StatefulWidget {
  const MeetingAiGlow({super.key, required this.active, required this.child});
  final bool active;
  final Widget child;

  @override
  State<MeetingAiGlow> createState() => _MeetingAiGlowState();
}

class _MeetingAiGlowState extends State<MeetingAiGlow>
    with TickerProviderStateMixin {
  late final _lift = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 360),
    reverseDuration: const Duration(milliseconds: 480),
  );
  late final _flow = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2800),
  );
  bool _reduced = false;

  @override
  void initState() {
    super.initState();
    _lift.addStatusListener((status) {
      if (status == AnimationStatus.dismissed) _flow.stop();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduced = MediaQuery.disableAnimationsOf(context);
    _sync();
  }

  @override
  void didUpdateWidget(MeetingAiGlow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.active != widget.active) _sync();
  }

  void _sync() {
    if (_reduced) {
      _flow.stop();
      _lift.value = widget.active ? 1 : 0;
    } else if (widget.active) {
      _lift.forward();
      if (!_flow.isAnimating) _flow.repeat();
    } else {
      _lift.reverse();
    }
  }

  @override
  void dispose() {
    _lift.dispose();
    _flow.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _lift,
    child: RepaintBoundary(child: widget.child),
    builder: (context, child) {
      final amount = Curves.easeOutCubic.transform(_lift.value);
      return Transform.translate(
        offset: Offset(0, _reduced ? 0 : -3 * amount),
        child: Transform.scale(
          scale: _reduced ? 1 : 1 + .008 * amount,
          child: CustomPaint(
            foregroundPainter: _GlowPainter(_flow, amount),
            child: child,
          ),
        ),
      );
    },
  );
}

/// 独立绘制四边流光，避免每帧重建文字、音频控件与补全面板。
class _GlowPainter extends CustomPainter {
  _GlowPainter(this.flow, this.amount) : super(repaint: flow);
  final Animation<double> flow;
  final double amount;

  @override
  void paint(Canvas canvas, Size size) {
    if (amount == 0 || size.isEmpty) return;
    final rect = (Offset.zero & size).deflate(1);
    final outline = RRect.fromRectAndRadius(rect, const Radius.circular(14));
    final shader = SweepGradient(
      colors: const [
        Color(0xFF409CFF),
        Color(0xFF816BFF),
        Color(0xFFE877CD),
        Color(0xFFFFB789),
        Color(0xFF62DCEC),
        Color(0xFF409CFF),
      ],
      transform: GradientRotation(flow.value * math.pi * 2),
    ).createShader(rect);
    canvas.saveLayer(
      rect.inflate(14),
      Paint()..color = Colors.white.withValues(alpha: amount),
    );
    canvas.drawRRect(
      outline,
      Paint()
        ..shader = shader
        ..style = PaintingStyle.stroke
        ..strokeWidth = 5
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5),
    );
    canvas.drawRRect(
      outline,
      Paint()
        ..shader = shader
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.8,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_GlowPainter oldDelegate) =>
      oldDelegate.amount != amount || oldDelegate.flow != flow;
}
