import 'dart:math' as math;
import 'package:flutter/material.dart';

/// Visual phases are derived from the device model by the caller. This widget
/// never starts discovery, connects to a device, or reports success.
enum AiVoiceArtworkPhase { idle, scanning, found, connecting, success, failure }

class AiVoiceProductArtwork extends StatefulWidget {
  const AiVoiceProductArtwork({
    super.key,
    this.phase = AiVoiceArtworkPhase.idle,
    this.size = 160,
    this.animate = false,
    this.semanticLabel = 'AI Voice 录音卡实物',
  });
  static const asset = 'assets/images/ai_voice/ai_voice_front.png';
  final AiVoiceArtworkPhase phase;
  final double size;
  final bool animate;
  final String semanticLabel;

  @override
  State<AiVoiceProductArtwork> createState() => _AiVoiceProductArtworkState();
}

class _AiVoiceProductArtworkState extends State<AiVoiceProductArtwork>
    with SingleTickerProviderStateMixin {
  late final AnimationController _motion = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 3600),
  );
  bool _reducedMotion = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reducedMotion = MediaQuery.disableAnimationsOf(context);
    _syncMotion();
  }

  @override
  void didUpdateWidget(covariant AiVoiceProductArtwork oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncMotion();
  }

  void _syncMotion() {
    final moving =
        widget.animate &&
        !_reducedMotion &&
        (widget.phase == AiVoiceArtworkPhase.scanning ||
            widget.phase == AiVoiceArtworkPhase.connecting);
    if (moving && !_motion.isAnimating) {
      _motion.repeat();
    } else if (!moving && _motion.isAnimating) {
      _motion.stop();
    }
  }

  @override
  void dispose() {
    _motion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final animated = widget.animate && !_reducedMotion;
    final scanning = widget.phase == AiVoiceArtworkPhase.scanning;
    final connecting = widget.phase == AiVoiceArtworkPhase.connecting;
    final image = Image.asset(
      AiVoiceProductArtwork.asset,
      fit: BoxFit.contain,
      filterQuality: FilterQuality.medium,
      cacheWidth: (widget.size * .72 * MediaQuery.devicePixelRatioOf(context))
          .round()
          .clamp(80, 720),
      excludeFromSemantics: true,
    );
    return Semantics(
      image: true,
      label: widget.semanticLabel,
      child: RepaintBoundary(
        child: SizedBox(
          width: widget.size,
          height: widget.size,
          child: AnimatedBuilder(
            animation: _motion,
            child: image,
            builder: (context, child) {
              final wave = animated && (scanning || connecting)
                  ? math.sin(_motion.value * math.pi * 2)
                  : 0.0;
              final pulse = animated && scanning ? (wave + 1) / 2 : .25;
              return Stack(
                alignment: Alignment.center,
                children: [
                  if (widget.animate)
                    Container(
                      width: widget.size * (.68 + pulse * .05),
                      height: widget.size * (.68 + pulse * .05),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: colors.primary.withValues(alpha: .035),
                        border: Border.all(
                          color: colors.primary.withValues(
                            alpha: .09 + pulse * .07,
                          ),
                        ),
                      ),
                    ),
                  AnimatedScale(
                    scale: connecting ? 1.025 : 1,
                    duration: animated
                        ? const Duration(milliseconds: 320)
                        : Duration.zero,
                    curve: connecting
                        ? Curves.easeOutBack
                        : Curves.easeOutCubic,
                    child: Transform.translate(
                      offset: Offset(0, wave * (scanning ? 3 : 1)),
                      child: Transform(
                        alignment: Alignment.center,
                        transform: Matrix4.identity()
                          ..setEntry(3, 2, .001)
                          ..rotateY(wave * (scanning ? .025 : .012)),
                        child: SizedBox(
                          width: widget.size * .72,
                          height: widget.size * .88,
                          child: child,
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
