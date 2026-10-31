import 'package:flutter/material.dart';
import 'brand_tokens.dart';

Widget _label(
  String value, {
  Color color = BrandColors.muted,
  double size = 10.5,
}) => Text(value, style: BrandTypography.text(size, color: color));
Widget _pill(String value, {bool blue = false, bool solid = false}) =>
    Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: solid
            ? BrandColors.blue
            : blue
            ? BrandColors.tint
            : BrandColors.background,
        borderRadius: BorderRadius.circular(99),
      ),
      child: _label(
        value,
        color: solid
            ? Colors.white
            : blue
            ? BrandColors.blue
            : BrandColors.secondary,
      ),
    );
Widget _card(
  Widget child, {
  double radius = 24,
  EdgeInsets padding = const EdgeInsets.all(16),
}) => Container(
  clipBehavior: Clip.antiAlias,
  width: double.infinity,
  padding: padding,
  decoration: BoxDecoration(
    color: BrandColors.surface,
    border: Border.all(color: BrandColors.ink.withValues(alpha: .08)),
    borderRadius: BorderRadius.circular(radius),
  ),
  child: child,
);

class ListenVisual extends StatelessWidget {
  const ListenVisual({super.key});
  @override
  Widget build(BuildContext context) => Semantics(
    label: '功能示意：AI Voice 录音卡，将发言整理成重点、待确认信息和原话时间戳。未启动录音。',
    child: ExcludeSemantics(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _card(
            Stack(
              children: [
                Column(
                  children: [
                    Container(
                      height: 172,
                      width: double.infinity,
                      decoration: const BoxDecoration(
                        gradient: RadialGradient(
                          center: Alignment(0, -.4),
                          radius: .85,
                          colors: [BrandColors.tint, BrandColors.surface],
                        ),
                      ),
                      child: Center(
                        child: Image.asset(
                          BrandAssets.device,
                          height: 168,
                          fit: BoxFit.contain,
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const SignalWave(),
                          _pill('AI Voice · 录音卡', blue: true),
                        ],
                      ),
                    ),
                  ],
                ),
                Positioned(
                  top: 16,
                  left: 24,
                  right: 24,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      _label('12:04 · 会议片段', size: 9.5),
                      Row(
                        children: [
                          const Icon(
                            Icons.circle,
                            size: 4,
                            color: BrandColors.blue,
                          ),
                          const SizedBox(width: 4),
                          _label('采集', size: 9.5),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
            radius: BrandRadii.hero,
            padding: EdgeInsets.zero,
          ),
          const SizedBox(height: 20),
          _line(1, emphasis: true),
          const SizedBox(height: 9),
          _line(.86),
          const SizedBox(height: 9),
          _line(.64),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              _pill('重点 · 成本结构', blue: true),
              _pill('待确认'),
              _pill('原话 12:04'),
            ],
          ),
        ],
      ),
    ),
  );
}

Widget _line(double factor, {bool emphasis = false}) => FractionallySizedBox(
  widthFactor: factor,
  child: Container(
    height: 8,
    decoration: BoxDecoration(
      color: BrandColors.ink.withValues(alpha: .07),
      borderRadius: BorderRadius.circular(9),
    ),
    child: emphasis
        ? FractionallySizedBox(
            alignment: Alignment.centerLeft,
            widthFactor: .46,
            child: Container(
              decoration: BoxDecoration(
                color: BrandColors.blue.withValues(alpha: .85),
                borderRadius: BorderRadius.circular(9),
              ),
            ),
          )
        : null,
  ),
);

class SignalWave extends StatelessWidget {
  const SignalWave({super.key});
  @override
  Widget build(BuildContext context) => SizedBox(
    height: 22,
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        for (final value in [
          .2,
          .44,
          .7,
          .96,
          .58,
          .32,
          .56,
          .84,
          .46,
          .24,
          .4,
          .64,
          .3,
        ])
          Padding(
            padding: const EdgeInsets.only(right: 3),
            child: Container(
              width: 3,
              height: (value * 22).clamp(4, 22),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(3),
                gradient: const LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0xFF9BBEFD), BrandColors.blue],
                ),
              ),
            ),
          ),
      ],
    ),
  );
}

class TraceVisual extends StatelessWidget {
  const TraceVisual({super.key});
  @override
  Widget build(BuildContext context) => Semantics(
    label: '功能示意：标记疑问，关联原话与时间戳，回看依据。',
    child: ExcludeSemantics(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _card(
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(
                      Icons.mic_none_rounded,
                      size: 13,
                      color: BrandColors.muted,
                    ),
                    const SizedBox(width: 6),
                    _label('12:04 · 匿名发言', size: 10),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  '「这个方案的成本结构，我们其实还没有确认清楚。」',
                  style: BrandTypography.text(13, height: 1.77),
                ),
                const SizedBox(height: 14),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    _pill('⊙ 标记疑问', blue: true),
                    _label('已关联原话与时间戳', size: 10),
                  ],
                ),
              ],
            ),
            radius: BrandRadii.card,
          ),
          const Padding(
            padding: EdgeInsets.only(left: 24),
            child: SizedBox(
              height: 38,
              child: CustomPaint(size: Size(1, 38), painter: _Dashes()),
            ),
          ),
          Row(
            children: [
              const Icon(Icons.circle, size: 10, color: BrandColors.blue),
              const SizedBox(width: 12),
              Flexible(
                child: _card(
                  _label('回看依据 · 无需重新听完整段录音', color: BrandColors.secondary),
                  radius: 30,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}

class ActionVisual extends StatelessWidget {
  const ActionVisual({super.key});
  @override
  Widget build(BuildContext context) => Semantics(
    label: '功能示意：纪要整理结论与后续行动，负责人待确认。',
    child: ExcludeSemantics(
      child: Container(
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
        decoration: BoxDecoration(
          color: BrandColors.surface,
          borderRadius: BorderRadius.circular(26),
          border: Border.all(color: BrandColors.ink.withValues(alpha: .08)),
          gradient: const RadialGradient(
            center: Alignment(1, -1),
            radius: 1.4,
            colors: [BrandColors.tint, BrandColors.surface],
          ),
        ),
        child: Column(
          children: [
            _card(
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      _label('会议纪要 · 01', size: 10),
                      _label('✓ 已整理', color: BrandColors.blue, size: 10),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _line(.92),
                  const SizedBox(height: 8),
                  _line(.74),
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 14),
                    child: Divider(height: 1, color: Color(0x140E122F)),
                  ),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: 18,
                        height: 18,
                        decoration: BoxDecoration(
                          color: BrandColors.tint,
                          border: Border.all(
                            color: BrandColors.blue.withValues(alpha: .5),
                          ),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: const Icon(
                          Icons.check,
                          size: 12,
                          color: BrandColors.blue,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '补齐成本结构说明，下次评审前同步',
                              style: BrandTypography.text(12, height: 1.6),
                            ),
                            const SizedBox(height: 4),
                            _label('行动项 · 负责人待确认', size: 10),
                          ],
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                const SizedBox(width: 16),
                const CustomPaint(size: Size(1, 32), painter: _Dashes()),
                const SizedBox(width: 8),
                _pill('下一步', solid: true),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}

class _Dashes extends CustomPainter {
  const _Dashes();
  @override
  void paint(Canvas canvas, Size size) {
    for (double y = 0; y < size.height; y += 6) {
      canvas.drawLine(
        Offset(0, y),
        Offset(0, (y + 3).clamp(0, size.height)),
        Paint()
          ..color = BrandColors.blue.withValues(alpha: .4)
          ..strokeWidth = 1,
      );
    }
  }

  @override
  bool shouldRepaint(_Dashes oldDelegate) => false;
}
