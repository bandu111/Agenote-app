import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../home/views/home_style.dart';
import '../meeting_models.dart';
import 'meeting_minutes_data.dart';

class MinutesMindMap extends StatefulWidget {
  const MinutesMindMap({
    super.key,
    required this.record,
    required this.data,
    required this.onSource,
    this.onInteractionChanged,
  });
  final MeetingRecord record;
  final MeetingMinutesData data;
  final ValueChanged<MinutesEntry> onSource;
  final ValueChanged<bool>? onInteractionChanged;
  @override
  State<MinutesMindMap> createState() => _MinutesMindMapState();
}

class _MinutesMindMapState extends State<MinutesMindMap> {
  final _transform = TransformationController();
  final _collapsed = <String>{};
  MinutesEntry? _selected;
  double _fit = .4;
  Size? _viewport;
  final _pointers = <int>{};

  void _pointerDown(PointerDownEvent event) {
    if (_pointers.add(event.pointer) && _pointers.length == 1) {
      widget.onInteractionChanged?.call(true);
    }
  }

  void _pointerEnd(PointerEvent event) {
    if (_pointers.remove(event.pointer) && _pointers.isEmpty) {
      widget.onInteractionChanged?.call(false);
    }
  }

  @override
  void dispose() {
    if (_pointers.isNotEmpty) {
      final callback = widget.onInteractionChanged;
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => callback?.call(false),
      );
    }
    _transform.dispose();
    super.dispose();
  }

  void _reset() {
    final box = _viewport;
    if (box == null) return;
    final height = math.max(480.0, widget.data.topics.length * 150.0);
    _fit = math.min(box.width / 780, box.height / height) * .94;
    _transform.value = Matrix4.identity()
      ..translateByDouble(
        (box.width - 780 * _fit) / 2,
        (box.height - height * _fit) / 2,
        0,
        1,
      )
      ..scaleByDouble(_fit, _fit, 1, 1);
  }

  @override
  Widget build(BuildContext context) {
    final topics = widget.data.topics;
    final muted = HomeStyle.secondary(context);
    final line = HomeStyle.tintColor(context, const Color(0xFFDDE8FD));
    final height = math.max(480.0, topics.length * 150.0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('会议结构', style: HomeStyle.text(16, bold: true)),
            const SizedBox(width: 7),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: HomeStyle.tint(context),
                borderRadius: BorderRadius.circular(5),
              ),
              child: Text(
                'AI 生成',
                style: HomeStyle.text(10, color: HomeStyle.blue),
              ),
            ),
            const Spacer(),
            Text(
              '${topics.length} 个议题 · ${topics.fold<int>(0, (sum, t) => sum + t.points.length)} 个要点',
              style: HomeStyle.text(10, color: muted),
            ),
          ],
        ),
        const SizedBox(height: 18),
        if (topics.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 80),
            child: Center(
              child: Text(
                '暂无已整理的议题结构',
                style: HomeStyle.text(14, color: muted),
              ),
            ),
          )
        else
          Container(
            height: 460,
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: HomeStyle.surface(context),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: line),
            ),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final size = Size(constraints.maxWidth, constraints.maxHeight);
                if (_viewport != size) {
                  _viewport = size;
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted) _reset();
                  });
                }
                final centers = [
                  for (var i = 0; i < topics.length; i++)
                    height / (topics.length + 1) * (i + 1),
                ];
                return Listener(
                  key: const ValueKey('minutes-mind-map-canvas'),
                  behavior: HitTestBehavior.opaque,
                  onPointerDown: _pointerDown,
                  onPointerUp: _pointerEnd,
                  onPointerCancel: _pointerEnd,
                  child: SizedBox.expand(
                    child: InteractiveViewer(
                      transformationController: _transform,
                      constrained: false,
                      panEnabled: true,
                      scaleEnabled: true,
                      panAxis: PanAxis.free,
                      trackpadScrollCausesScale: true,
                      boundaryMargin: const EdgeInsets.all(400),
                      minScale: .15,
                      maxScale: 3,
                      child: SizedBox(
                        width: 780,
                        height: height,
                        child: Stack(
                          children: [
                            Positioned.fill(
                              child: CustomPaint(
                                painter: _MapLines(
                                  centers,
                                  height / 2,
                                  topics,
                                  _collapsed,
                                  line,
                                ),
                              ),
                            ),
                            Positioned(
                              left: 24,
                              top: height / 2 - 24,
                              width: 174,
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 10,
                                ),
                                decoration: BoxDecoration(
                                  color: HomeStyle.blue,
                                  borderRadius: BorderRadius.circular(24),
                                ),
                                child: Column(
                                  children: [
                                    Text(
                                      widget.record.title,
                                      maxLines: 2,
                                      textAlign: TextAlign.center,
                                      style: HomeStyle.text(
                                        13,
                                        bold: true,
                                        color: Colors.white,
                                      ),
                                    ),
                                    Text(
                                      '${meetingTime(widget.record.elapsed)} · ${topics.length} 个议题',
                                      style: HomeStyle.text(
                                        9,
                                        color: Colors.white70,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            for (final (i, topic) in topics.indexed) ...[
                              Positioned(
                                left: 290,
                                top: centers[i] - 24,
                                width: 185,
                                child: GestureDetector(
                                  onTap: () =>
                                      setState(() => _selected = topic),
                                  child: Container(
                                    padding: const EdgeInsets.fromLTRB(
                                      12,
                                      8,
                                      4,
                                      8,
                                    ),
                                    decoration: BoxDecoration(
                                      color: HomeStyle.surface(context),
                                      border: Border.all(
                                        color: _selected?.id == topic.id
                                            ? HomeStyle.blue
                                            : line,
                                      ),
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    child: Row(
                                      children: [
                                        Expanded(
                                          child: Text(
                                            topic.title,
                                            style: HomeStyle.text(13),
                                          ),
                                        ),
                                        IconButton(
                                          tooltip: _collapsed.contains(topic.id)
                                              ? '展开议题'
                                              : '折叠议题',
                                          constraints: const BoxConstraints(
                                            minWidth: 36,
                                            minHeight: 36,
                                          ),
                                          padding: EdgeInsets.zero,
                                          onPressed: () => setState(() {
                                            if (!_collapsed.add(topic.id)) {
                                              _collapsed.remove(topic.id);
                                            }
                                          }),
                                          icon: Icon(
                                            _collapsed.contains(topic.id)
                                                ? Icons.add
                                                : Icons.remove,
                                            size: 16,
                                            color: HomeStyle.blue,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                              if (!_collapsed.contains(topic.id))
                                for (final (j, point) in topic.points.indexed)
                                  Positioned(
                                    left: 555,
                                    top:
                                        centers[i] +
                                        (j - (topic.points.length - 1) / 2) *
                                            42 -
                                        14,
                                    width: 205,
                                    child: InkWell(
                                      onTap: () =>
                                          setState(() => _selected = topic),
                                      borderRadius: BorderRadius.circular(10),
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 10,
                                          vertical: 6,
                                        ),
                                        decoration: BoxDecoration(
                                          color: HomeStyle.tint(context),
                                          borderRadius: BorderRadius.circular(
                                            10,
                                          ),
                                        ),
                                        child: Text(
                                          point,
                                          maxLines: 2,
                                          style: HomeStyle.text(
                                            11,
                                            color: muted,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        Row(
          children: [
            Expanded(
              child: Text(
                '拖动查看 · 双指缩放',
                style: HomeStyle.text(11, color: muted),
              ),
            ),
            TextButton(
              onPressed: topics.isEmpty ? null : _reset,
              child: const Text('重置视图', style: TextStyle(fontSize: 12)),
            ),
          ],
        ),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: HomeStyle.tint(context),
            border: Border.all(color: line),
            borderRadius: BorderRadius.circular(12),
          ),
          child: _selected == null
              ? Text('点击节点查看议题摘要与原始依据', style: HomeStyle.text(12, color: muted))
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _selected!.title,
                      style: HomeStyle.text(14, bold: true),
                    ),
                    const SizedBox(height: 8),
                    Text(_selected!.text, style: HomeStyle.text(13)),
                    TextButton(
                      onPressed: () => widget.onSource(_selected!),
                      child: const Text('查看原始依据 ›'),
                    ),
                  ],
                ),
        ),
      ],
    );
  }
}

class _MapLines extends CustomPainter {
  _MapLines(this.centers, this.root, this.topics, this.collapsed, this.color);
  final List<double> centers;
  final double root;
  final List<MinutesEntry> topics;
  final Set<String> collapsed;
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;
    for (var i = 0; i < centers.length; i++) {
      canvas.drawPath(
        Path()
          ..moveTo(198, root)
          ..lineTo(242, root)
          ..lineTo(242, centers[i])
          ..lineTo(290, centers[i]),
        paint,
      );
      if (collapsed.contains(topics[i].id)) continue;
      for (var j = 0; j < topics[i].points.length; j++) {
        final y = centers[i] + (j - (topics[i].points.length - 1) / 2) * 42;
        canvas.drawPath(
          Path()
            ..moveTo(475, centers[i])
            ..lineTo(515, centers[i])
            ..lineTo(515, y)
            ..lineTo(555, y),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _MapLines old) => true;
}
