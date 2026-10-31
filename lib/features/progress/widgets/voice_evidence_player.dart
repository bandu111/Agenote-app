import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../home/views/home_style.dart';
import '../models/progress_models.dart';
import '../viewmodels/voice_evidence_controller.dart';

class VoiceEvidencePlayer extends StatefulWidget {
  const VoiceEvidencePlayer({
    super.key,
    required this.evidence,
    this.onDetails,
    this.compact = false,
    this.detail = false,
    this.showIdleLabel = true,
  });
  final VoiceEvidence evidence;
  final VoidCallback? onDetails;
  final bool compact;
  final bool detail;
  final bool showIdleLabel;
  @override
  State<VoiceEvidencePlayer> createState() => _VoiceEvidencePlayerState();
}

class _VoiceEvidencePlayerState extends State<VoiceEvidencePlayer> {
  Duration? _previewPosition;
  VoiceEvidence get evidence => widget.evidence;
  bool get detail => widget.detail;
  bool get compact => widget.compact;
  VoidCallback? get onDetails => widget.onDetails;

  @override
  void didUpdateWidget(covariant VoiceEvidencePlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.evidence.id != evidence.id) _previewPosition = null;
  }

  @override
  Widget build(BuildContext context) {
    final audio = context.watch<VoiceEvidenceController>();
    final selected = audio.evidence?.id == evidence.id;
    final unavailable = evidence.unavailableReason;
    final playing = selected && audio.state == VoicePlaybackState.playing;
    final position =
        _previewPosition ?? (selected ? audio.position : Duration.zero);
    final play = IconButton(
      key: ValueKey('play-${evidence.id}'),
      tooltip: unavailable ?? (playing ? '暂停语音' : '播放语音'),
      onPressed: () async {
        await audio.toggle(evidence);
        if (context.mounted && audio.message != null) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(audio.message!)));
        }
      },
      icon: Icon(
        playing ? Icons.pause_circle_filled : Icons.play_circle_fill,
        color: unavailable == null ? HomeStyle.blue : const Color(0xFF8896DA),
        size: 27,
      ),
    );
    // 详情页仅呈现音频与播放状态；转写由页面顶部统一展示，避免重复占屏。
    if (detail) {
      final duration = evidence.duration.inMilliseconds
          .toDouble()
          .clamp(1, double.infinity)
          .toDouble();
      final progress = position.inMilliseconds
          .toDouble()
          .clamp(0.0, duration)
          .toDouble();
      return Container(
        padding: const EdgeInsets.all(12),
        decoration: HomeStyle.card(context: context, radius: 16),
        child: Column(
          children: [
            Row(
              children: [
                play,
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final enabled =
                          unavailable == null &&
                          audio.state != VoicePlaybackState.loading;
                      // 将手指横坐标映射为片段内时间；越界拖动限制到起点或终点。
                      Duration target(double x) => Duration(
                        milliseconds: (x / constraints.maxWidth * duration)
                            .clamp(0, duration)
                            .round(),
                      );
                      Future<void> commit(Duration value) async {
                        await audio.seek(value, source: evidence);
                        if (mounted) setState(() => _previewPosition = null);
                      }

                      return Semantics(
                        label: '语音播放进度',
                        value:
                            '${voiceTime(position)} / ${voiceTime(evidence.duration)}',
                        enabled: enabled,
                        // 读屏调节需要同时提供目标值，且与控制器的时间边界保持一致。
                        increasedValue: enabled
                            ? '${voiceTime(Duration(milliseconds: (position.inMilliseconds + 5000).clamp(0, evidence.duration.inMilliseconds)))} / ${voiceTime(evidence.duration)}'
                            : null,
                        decreasedValue: enabled
                            ? '${voiceTime(Duration(milliseconds: (position.inMilliseconds - 5000).clamp(0, evidence.duration.inMilliseconds)))} / ${voiceTime(evidence.duration)}'
                            : null,
                        onIncrease: enabled
                            ? () =>
                                  commit(position + const Duration(seconds: 5))
                            : null,
                        onDecrease: enabled
                            ? () =>
                                  commit(position - const Duration(seconds: 5))
                            : null,
                        child: GestureDetector(
                          key: const ValueKey('voice-detail-waveform'),
                          behavior: HitTestBehavior.opaque,
                          onTapUp: enabled
                              ? (event) =>
                                    commit(target(event.localPosition.dx))
                              : null,
                          // 拖动时仅预览时间和着色，松手后执行一次 seek，避免频繁调用音频设备。
                          onHorizontalDragStart: enabled
                              ? (event) => setState(
                                  () => _previewPosition = target(
                                    event.localPosition.dx,
                                  ),
                                )
                              : null,
                          onHorizontalDragUpdate: enabled
                              ? (event) => setState(
                                  () => _previewPosition = target(
                                    event.localPosition.dx,
                                  ),
                                )
                              : null,
                          onHorizontalDragEnd: enabled
                              ? (_) => commit(_previewPosition ?? position)
                              : null,
                          onHorizontalDragCancel: () =>
                              setState(() => _previewPosition = null),
                          child: SizedBox(
                            height: 48,
                            child: CustomPaint(
                              painter: _DetailVoiceMotif(
                                progress / duration,
                                HomeStyle.blue,
                                HomeStyle.secondary(
                                  context,
                                ).withValues(alpha: .22),
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
            const Divider(height: 12),
            // 两侧各占一半可用宽度并贴边对齐；空间不足时缩放，保持时间与凭证状态同一行。
            Row(
              key: const ValueKey('voice-detail-footer'),
              children: [
                Expanded(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        '${voiceTime(position)} / ${voiceTime(evidence.duration)}',
                        key: const ValueKey('voice-detail-time'),
                        maxLines: 1,
                        style: HomeStyle.text(11),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        unavailable == null ? '语音凭证·可播放' : '语音凭证·不可播放',
                        key: const ValueKey('voice-detail-status'),
                        maxLines: 1,
                        style: HomeStyle.text(
                          11,
                          color: HomeStyle.secondary(context),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
            // 较长的不可用原因或播放反馈独立显示，不挤占底部状态行。
            if (unavailable != null || selected && audio.message != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    unavailable ?? audio.message!,
                    style: HomeStyle.text(
                      11,
                      color: HomeStyle.secondary(context),
                    ),
                  ),
                ),
              ),
          ],
        ),
      );
    }
    if (compact) {
      return Container(
        decoration: BoxDecoration(
          color: HomeStyle.tintColor(context, const Color(0xFFF1F4FE)),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                play,
                Expanded(
                  child: Semantics(
                    label: '语音片段',
                    child: SizedBox(
                      height: 24,
                      child: CustomPaint(
                        painter: _VoiceMotif(
                          Theme.of(context).colorScheme.primary,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                // 紧凑行中时长采用固定上限宽度，避免系统大字体挤出播放器。
                SizedBox(
                  width: 42,
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      voiceTime(
                        playing || position != Duration.zero
                            ? position
                            : evidence.duration,
                      ),
                      style: HomeStyle.text(
                        11,
                        color: HomeStyle.secondary(context),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
              ],
            ),
            if (unavailable != null || selected && audio.message != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
                child: Text(
                  unavailable ?? audio.message!,
                  style: HomeStyle.text(
                    10,
                    color: HomeStyle.secondary(context),
                  ),
                ),
              ),
          ],
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final large =
            constraints.maxWidth < 280 ||
            MediaQuery.textScalerOf(context).scale(14) > 20;
        return Container(
          padding: const EdgeInsets.fromLTRB(2, 2, 4, 6),
          decoration: BoxDecoration(
            color: HomeStyle.tintColor(context, const Color(0xFFF1F4FE)),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  play,
                  const Icon(
                    Icons.graphic_eq,
                    color: Color(0xFF8D9AFF),
                    size: 24,
                  ),
                  const SizedBox(width: 7),
                  Text(
                    playing || position != Duration.zero
                        ? voiceTime(position)
                        : voiceTime(evidence.duration),
                    style: HomeStyle.text(12),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: large
                        ? const SizedBox.shrink()
                        : InkWell(
                            onTap: onDetails,
                            child: Text(
                              '“${evidence.transcript}”',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: HomeStyle.text(
                                13,
                                color: HomeStyle.secondary(context),
                              ),
                            ),
                          ),
                  ),
                  if (onDetails != null)
                    IconButton(
                      tooltip: '查看语音证据',
                      onPressed: onDetails,
                      icon: Icon(
                        Icons.chevron_right,
                        color: HomeStyle.foreground(context),
                      ),
                    ),
                ],
              ),
              // 承诺列表隐藏空闲标签，但保留真实播放状态与不可用原因。
              if (widget.showIdleLabel ||
                  unavailable != null ||
                  (selected && audio.message != null))
                Padding(
                  padding: const EdgeInsets.only(left: 12),
                  child: Text(
                    unavailable ??
                        (selected ? audio.message ?? '语音证据' : '语音证据'),
                    style: HomeStyle.text(
                      11,
                      color: HomeStyle.secondary(context),
                    ),
                  ),
                ),
              if (large)
                Padding(
                  padding: const EdgeInsets.all(10),
                  child: InkWell(
                    onTap: onDetails,
                    child: Text(
                      '“${evidence.transcript}”',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: HomeStyle.text(
                        13,
                        color: HomeStyle.secondary(context),
                      ),
                    ),
                  ),
                ),
              if (unavailable == null &&
                  selected &&
                  audio.state != VoicePlaybackState.unavailable)
                Slider(
                  semanticFormatterCallback: (value) =>
                      voiceTime(Duration(milliseconds: value.round())),
                  value: position.inMilliseconds.toDouble().clamp(
                    0,
                    evidence.duration.inMilliseconds.toDouble(),
                  ),
                  max: evidence.duration.inMilliseconds.toDouble().clamp(
                    1,
                    double.infinity,
                  ),
                  onChanged: (value) =>
                      audio.seek(Duration(milliseconds: value.round())),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// A static voice motif, not fabricated sample data or animated playback.
class _VoiceMotif extends CustomPainter {
  _VoiceMotif(this.color);
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    const heights = [
      5,
      9,
      15,
      8,
      19,
      12,
      23,
      14,
      8,
      17,
      11,
      21,
      13,
      7,
      16,
      10,
      6,
      12,
      8,
      4,
      9,
      6,
      3,
    ];
    final paint = Paint()
      ..color = color.withValues(alpha: .55)
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    final count = (size.width / 4).floor().clamp(0, heights.length);
    for (var i = 0; i < count; i++) {
      final h = heights[i].toDouble();
      canvas.drawLine(
        Offset(2 + i * 4, (size.height - h) / 2),
        Offset(2 + i * 4, (size.height + h) / 2),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _VoiceMotif oldDelegate) =>
      oldDelegate.color != color;
}

/// Decorative waveform; color indicates actual playback progress, not amplitude.
class _DetailVoiceMotif extends CustomPainter {
  const _DetailVoiceMotif(this.progress, this.active, this.inactive);
  final double progress;
  final Color active, inactive;
  @override
  void paint(Canvas canvas, Size size) {
    const heights = [
      8.0,
      14.0,
      20.0,
      12.0,
      24.0,
      16.0,
      10.0,
      22.0,
      28.0,
      18.0,
      12.0,
    ];
    final count = (size.width / 7).floor();
    final paint = Paint()
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round;
    for (var i = 0; i < count; i++) {
      final x = i * 7.0 + 3;
      final height = heights[i % heights.length];
      paint.color = x / size.width < progress ? active : inactive;
      canvas.drawLine(
        Offset(x, (size.height - height) / 2),
        Offset(x, (size.height + height) / 2),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _DetailVoiceMotif oldDelegate) =>
      progress != oldDelegate.progress ||
      active != oldDelegate.active ||
      inactive != oldDelegate.inactive;
}
