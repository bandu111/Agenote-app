import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import '../../../app/l10n/app_strings.dart';
import '../../home/views/home_style.dart';
import '../models/progress_models.dart';
import 'progress_components.dart';

/// Goal evidence branches share a root; milestone order is kept from the model.
class GoalTopology extends StatelessWidget {
  const GoalTopology({super.key, required this.goal});
  final ProgressGoal goal;

  @override
  Widget build(BuildContext context) => ProgressCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              Icons.account_tree_outlined,
              size: 18,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '目标拓扑图'.tr(context),
                style: HomeStyle.text(15, bold: true),
              ),
            ),
            IconButton(
              key: const ValueKey('goal-topology-expand'),
              tooltip: '查看大图'.tr(context),
              icon: const Icon(Icons.open_in_full, size: 18),
              onPressed: () => Navigator.of(context, rootNavigator: true).push(
                MaterialPageRoute<void>(
                  fullscreenDialog: true,
                  builder: (context) => Scaffold(
                    appBar: AppBar(title: Text('目标拓扑图'.tr(context))),
                    body: SafeArea(
                      child: Column(
                        children: [
                          Expanded(
                            child: LayoutBuilder(
                              builder: (context, constraints) {
                                final graph = GoalTopologyLayout.create(
                                  context,
                                  goal,
                                );
                                return _GraphViewport(
                                  goal: goal,
                                  showReset: true,
                                  graph: graph,
                                  viewport: Size(
                                    constraints.maxWidth,
                                    constraints.maxHeight,
                                  ),
                                );
                              },
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.all(16),
                            child: Text(
                              '双指缩放与拖动'.tr(context),
                              style: HomeStyle.text(
                                12,
                                color: HomeStyle.secondary(context),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        if (goal.milestones.any((m) => m.statusBasis == 'meeting_reported'))
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              '含会议陈述的进度，尚未完成履约核验',
              style: HomeStyle.text(11, color: HomeStyle.secondary(context)),
            ),
          ),
        LayoutBuilder(
          builder: (context, constraints) {
            final graph = GoalTopologyLayout.create(context, goal);
            return _GraphViewport(
              goal: goal,
              graph: graph,
              viewport: Size(
                constraints.maxWidth,
                graph.size.height *
                    math.min(1, constraints.maxWidth / graph.size.width),
              ),
            );
          },
        ),
        const SizedBox(height: 12),
        if (goal.milestones.isEmpty) ...[
          Text(
            '暂无里程碑'.tr(context),
            style: HomeStyle.text(13, color: HomeStyle.secondary(context)),
          ),
          const SizedBox(height: 8),
        ],
        Text(
          '双指缩放与拖动'.tr(context),
          style: HomeStyle.text(11, color: HomeStyle.secondary(context)),
        ),
      ],
    ),
  );
}

class GoalTopologyNode {
  const GoalTopologyNode({
    required this.id,
    required this.title,
    required this.body,
    required this.icon,
    this.milestone,
    this.index,
    this.stage = MilestoneStage.open,
  });
  final String id, title, body;
  final IconData icon;
  final Milestone? milestone;
  final int? index;
  final MilestoneStage stage;
  String get statusLabel => milestoneStatusLabel(milestone!.status, stage);
}

/// 待完成节点按顺序解锁：第一个未完成的节点是当前阶段，其后的节点待解锁。
enum MilestoneStage { open, current, locked }

List<MilestoneStage> milestoneStages(List<Milestone> milestones) {
  final active = milestones.indexWhere(
    (m) => m.status == MilestoneStatus.active,
  );
  final current = active >= 0
      ? active
      : milestones.indexWhere((m) => m.status == MilestoneStatus.pending);
  return [
    for (var i = 0; i < milestones.length; i++)
      i == current
          ? MilestoneStage.current
          : current >= 0 &&
                i > current &&
                milestones[i].status == MilestoneStatus.pending
          ? MilestoneStage.locked
          : MilestoneStage.open,
  ];
}

class GoalTopologyLayout {
  GoalTopologyLayout(this.size, this.nodes, this.rects);
  final Size size;
  final List<GoalTopologyNode> nodes;
  final Map<String, Rect> rects;

  static GoalTopologyLayout create(BuildContext context, ProgressGoal goal) {
    final scaler = MediaQuery.textScalerOf(context);
    final factor = math.max(1.0, scaler.scale(12) / 12);
    final width =
        math.max(
          420.0,
          goal.milestones.length * 86 +
              math.max(0, goal.milestones.length - 1) * 14 +
              24,
        ) *
        factor;
    final nodeWidth = 86 * factor;
    final sideWidth = 144 * factor;
    final rootWidth = 214 * factor;
    final stages = milestoneStages(goal.milestones);
    final nodes = [
      GoalTopologyNode(
        id: 'delivery',
        title: '交付目标'.tr(context),
        body: goal.condition,
        icon: Icons.track_changes,
      ),
      GoalTopologyNode(
        id: 'acceptance',
        title: '验收要求'.tr(context),
        body: goal.acceptance,
        icon: Icons.description_outlined,
      ),
      GoalTopologyNode(
        id: 'phase',
        title: '当前阶段 / 截止时间'.tr(context),
        body:
            '${'阶段'.tr(context)}：${goal.phase}\n${'截止'.tr(context)}：${goal.deadline == null ? '待明确' : progressDate(goal.deadline!)}',
        icon: Icons.calendar_month_outlined,
      ),
      GoalTopologyNode(
        id: 'milestones',
        title: '里程碑'.tr(context),
        body: '${(goal.progress * 100).round()}%',
        icon: Icons.flag_outlined,
      ),
      for (var i = 0; i < goal.milestones.length; i++)
        GoalTopologyNode(
          id: 'milestone-$i',
          title: goal.milestones[i].title,
          body: '',
          icon: Icons.flag_outlined,
          milestone: goal.milestones[i],
          index: i + 1,
          stage: stages[i],
        ),
    ];
    double textHeight(
      String text,
      double font,
      double available, {
      bool bold = false,
    }) {
      final painter = TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(
            fontSize: font,
            height: 1.4,
            letterSpacing: 0,
            fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
            fontFamily: Theme.of(context).textTheme.bodyMedium?.fontFamily,
          ),
        ),
        textDirection: Directionality.of(context),
        textScaler: scaler,
      )..layout(maxWidth: available);
      final height = painter.height;
      painter.dispose();
      return height.ceilToDouble();
    }

    double cardHeight(GoalTopologyNode n, double w) =>
        24 +
        math.max(
          scaler.scale(16),
          textHeight(n.title, 13, w - 44, bold: true),
        ) +
        8 +
        textHeight(n.body, 13, w - 22);
    final rootHeight = cardHeight(nodes[0], rootWidth);
    final sideY = 12 + rootHeight + 22 * factor;
    final sideHeight = math.max(
      cardHeight(nodes[1], sideWidth),
      cardHeight(nodes[2], sideWidth),
    );
    final pillY = sideY + sideHeight + 22 * factor;
    final pillHeight = math.max(32.0, scaler.scale(12) * 1.4 + 16);
    final milestoneY = pillY + pillHeight + 28 * factor;
    final numberSize = math.max(20.0, scaler.scale(11) * 1.4);
    var milestoneHeight = 80.0;
    for (final n in nodes.skip(4)) {
      final badgeHeight =
          math.max(
            14.0,
            textHeight(n.statusLabel.tr(context), 11, nodeWidth - 42),
          ) +
          8;
      milestoneHeight = math.max(
        milestoneHeight,
        24 +
            numberSize +
            8 +
            textHeight(n.title, 12, nodeWidth - 22, bold: true) +
            8 +
            badgeHeight,
      );
    }
    final rowWidth =
        goal.milestones.length * nodeWidth +
        math.max(0, goal.milestones.length - 1) * 14 * factor;
    final rects = <String, Rect>{
      'delivery': Rect.fromLTWH(
        (width - rootWidth) / 2,
        12,
        rootWidth,
        rootHeight,
      ),
      'acceptance': Rect.fromLTWH(12 * factor, sideY, sideWidth, sideHeight),
      'phase': Rect.fromLTWH(
        width - sideWidth - 12 * factor,
        sideY,
        sideWidth,
        sideHeight,
      ),
      'milestones': Rect.fromLTWH(
        (width - 132 * factor) / 2,
        pillY,
        132 * factor,
        pillHeight,
      ),
      for (var i = 0; i < goal.milestones.length; i++)
        'milestone-$i': Rect.fromLTWH(
          (width - rowWidth) / 2 + i * (nodeWidth + 14 * factor),
          milestoneY,
          nodeWidth,
          milestoneHeight,
        ),
    };
    final bottom = goal.milestones.isEmpty
        ? pillY + pillHeight + 20
        : milestoneY + milestoneHeight + 12;
    return GoalTopologyLayout(Size(width, bottom), nodes, rects);
  }
}

String milestoneStatusLabel(
  MilestoneStatus status, [
  MilestoneStage stage = MilestoneStage.open,
]) => switch (status) {
  MilestoneStatus.completed => '已完成',
  MilestoneStatus.active => '进行中',
  MilestoneStatus.pending => switch (stage) {
    MilestoneStage.current => '当前阶段',
    MilestoneStage.locked => '待解锁',
    MilestoneStage.open => '待完成',
  },
};

Color milestoneStatusColor(BuildContext context, MilestoneStatus status) =>
    switch (status) {
      MilestoneStatus.completed => const Color(0xFF117A65),
      MilestoneStatus.active => const Color(0xFFB78103),
      MilestoneStatus.pending => HomeStyle.secondary(context),
    };

class _GraphViewport extends StatefulWidget {
  const _GraphViewport({
    required this.goal,
    required this.graph,
    required this.viewport,
    this.showReset = false,
  });
  final ProgressGoal goal;
  final GoalTopologyLayout graph;
  final Size viewport;
  final bool showReset;
  @override
  State<_GraphViewport> createState() => _GraphViewportState();
}

class _GraphViewportState extends State<_GraphViewport> {
  late final TransformationController _transform = TransformationController(
    _fit(),
  );
  double get _scale => math.min(
    widget.viewport.width / widget.graph.size.width,
    widget.viewport.height / widget.graph.size.height,
  );
  Matrix4 _fit() {
    final s = _scale;
    return Matrix4.diagonal3Values(s, s, 1)..setTranslationRaw(
      (widget.viewport.width - widget.graph.size.width * s) / 2,
      (widget.viewport.height - widget.graph.size.height * s) / 2,
      0,
    );
  }

  @override
  void didUpdateWidget(covariant _GraphViewport oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.viewport != widget.viewport ||
        oldWidget.graph.size != widget.graph.size ||
        oldWidget.goal.id != widget.goal.id) {
      _transform.value = _fit();
    }
  }

  @override
  void dispose() {
    _transform.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    width: widget.viewport.width,
    height: widget.viewport.height,
    child: Stack(
      fit: StackFit.expand,
      children: [
        InteractiveViewer(
          key: const ValueKey('goal-topology-canvas'),
          transformationController: _transform,
          constrained: false,
          minScale: _scale,
          maxScale: math.max(3, _scale * 4),
          boundaryMargin: EdgeInsets.all(widget.graph.size.longestSide),
          child: SizedBox(
            width: widget.graph.size.width,
            height: widget.graph.size.height,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned.fill(
                  child: CustomPaint(
                    painter: _GoalEdges(
                      widget.graph,
                      Theme.of(context).colorScheme.primary,
                    ),
                  ),
                ),
                for (final node in widget.graph.nodes)
                  Positioned.fromRect(
                    rect: widget.graph.rects[node.id]!,
                    child: _GraphNode(
                      key: ValueKey('goal-topology-node-${node.id}'),
                      node: node,
                    ),
                  ),
              ],
            ),
          ),
        ),
        if (widget.showReset)
          Positioned(
            top: 8,
            right: 8,
            child: IconButton.filledTonal(
              key: const ValueKey('goal-topology-reset'),
              tooltip: '适应画布'.tr(context),
              onPressed: () => _transform.value = _fit(),
              icon: const Icon(Icons.center_focus_strong_outlined, size: 20),
            ),
          ),
      ],
    ),
  );
}

class _GraphNode extends StatelessWidget {
  const _GraphNode({super.key, required this.node});
  final GoalTopologyNode node;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final milestone = node.milestone;
    final hub = node.id == 'milestones';
    final accent = milestone == null
        ? colors.primary
        : milestoneStatusColor(context, milestone.status);
    final background = milestone == null
        ? colors.primary.withValues(alpha: .035)
        : switch (milestone.status) {
            MilestoneStatus.completed => HomeStyle.tintColor(
              context,
              const Color(0xFFE8F8F5),
            ),
            MilestoneStatus.active => HomeStyle.tintColor(
              context,
              const Color(0xFFFFF9E6),
            ),
            MilestoneStatus.pending => HomeStyle.tintColor(
              context,
              const Color(0xFFF5F6F8),
            ),
          };
    Widget card = Semantics(
      label: [
        node.title,
        node.body,
        if (milestone != null) node.statusLabel.tr(context),
      ].where((v) => v.isNotEmpty).join('，'),
      excludeSemantics: true,
      child: Material(
        color: hub ? colors.primary : background,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(
            color: hub ? Colors.transparent : accent.withValues(alpha: .25),
            width: 1.5,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: hub
              ? const EdgeInsets.symmetric(horizontal: 10, vertical: 6)
              : const EdgeInsets.all(10),
          child: hub
              ? Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(node.icon, size: 15, color: colors.onPrimary),
                    const SizedBox(width: 5),
                    Flexible(
                      child: Text(
                        '${node.title} · ${node.body}',
                        style: TextStyle(
                          fontSize: 12,
                          height: 1.4,
                          letterSpacing: 0,
                          color: colors.onPrimary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                )
              : milestone == null
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(node.icon, size: 16, color: accent),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            node.title,
                            style: TextStyle(
                              fontSize: 13,
                              height: 1.4,
                              letterSpacing: 0,
                              fontWeight: FontWeight.w700,
                              color: accent,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      node.body,
                      style: TextStyle(
                        fontSize: 13,
                        height: 1.4,
                        letterSpacing: 0,
                        color: colors.onSurface,
                      ),
                    ),
                  ],
                )
              : Column(
                  children: [
                    Container(
                      width: math.max(
                        20,
                        MediaQuery.textScalerOf(context).scale(11) * 1.4,
                      ),
                      height: math.max(
                        20,
                        MediaQuery.textScalerOf(context).scale(11) * 1.4,
                      ),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: accent.withValues(alpha: .1),
                        shape: BoxShape.circle,
                      ),
                      child: Text(
                        '${node.index}',
                        style: TextStyle(
                          fontSize: 11,
                          height: 1.4,
                          letterSpacing: 0,
                          fontWeight: FontWeight.w700,
                          color: accent,
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      node.title,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.4,
                        letterSpacing: 0,
                        fontWeight: FontWeight.w700,
                        color: colors.onSurface,
                      ),
                    ),
                    const Spacer(),
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 2,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: accent.withValues(alpha: .08),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            milestone.status == MilestoneStatus.completed
                                ? Icons.check_circle
                                : milestone.status == MilestoneStatus.active
                                ? Icons.timelapse
                                : node.stage == MilestoneStage.locked
                                ? Icons.lock_outline
                                : node.stage == MilestoneStage.current
                                ? Icons.play_circle_outline
                                : Icons.schedule,
                            size: 12,
                            color: accent,
                          ),
                          const SizedBox(width: 4),
                          Flexible(
                            child: Text(
                              node.statusLabel.tr(context),
                              style: TextStyle(
                                fontSize: 11,
                                height: 1.4,
                                letterSpacing: 0,
                                fontWeight: FontWeight.w600,
                                color: accent,
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
    );
    if (milestone?.status == MilestoneStatus.active &&
        !MediaQuery.disableAnimationsOf(context)) {
      card = card
          .animate()
          .scaleXY(
            begin: .2,
            end: 1,
            duration: const Duration(milliseconds: 750),
            curve: Curves.elasticOut,
          )
          .shimmer(
            delay: const Duration(milliseconds: 400),
            duration: const Duration(milliseconds: 900),
            color: const Color(0xFFFFE599).withValues(alpha: .6),
          );
    }
    return card;
  }
}

class _GoalEdges extends CustomPainter {
  _GoalEdges(this.graph, this.color);
  final GoalTopologyLayout graph;
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final pen = Paint()
      ..color = color.withValues(alpha: .55)
      ..strokeWidth = 1.3
      ..style = PaintingStyle.stroke;
    final dot = Paint()..color = color;
    void link(List<Offset> points) {
      final path = Path()..moveTo(points.first.dx, points.first.dy);
      for (var i = 1; i < points.length - 1; i++) {
        final p = points[i], before = points[i - 1], after = points[i + 1];
        final r = math.min(
          7.0,
          math.min((p - before).distance, (after - p).distance) / 2,
        );
        final a = p - (p - before) / (p - before).distance * r;
        final b = p + (after - p) / (after - p).distance * r;
        path.lineTo(a.dx, a.dy);
        path.quadraticBezierTo(p.dx, p.dy, b.dx, b.dy);
      }
      path.lineTo(points.last.dx, points.last.dy);
      canvas.drawPath(path, pen);
      canvas.drawCircle(points.first, 2.3, dot);
      canvas.drawCircle(points.last, 2.3, dot);
    }

    final root = graph.rects['delivery']!, hub = graph.rects['milestones']!;
    for (final name in ['acceptance', 'phase']) {
      final side = graph.rects[name]!;
      final start = name == 'acceptance' ? root.centerLeft : root.centerRight;
      link([start, Offset(side.center.dx, start.dy), side.topCenter]);
    }
    link([root.bottomCenter, hub.topCenter]);
    final milestones = graph.nodes
        .where((n) => n.milestone != null)
        .map((n) => graph.rects[n.id]!)
        .toList();
    if (milestones.isEmpty) return;
    final busY = milestones.first.top - 16;
    link([hub.bottomCenter, Offset(hub.center.dx, busY)]);
    canvas.drawLine(
      Offset(milestones.first.center.dx, busY),
      Offset(milestones.last.center.dx, busY),
      pen,
    );
    for (var i = 0; i < milestones.length; i++) {
      final m = milestones[i];
      link([Offset(m.center.dx, busY), m.topCenter]);
      if (i + 1 < milestones.length) {
        final end = milestones[i + 1].left - 3,
            start = m.right + 3,
            y = m.center.dy;
        canvas.drawLine(Offset(start, y), Offset(end, y), pen);
        canvas.drawPath(
          Path()
            ..moveTo(end - 3, y - 3)
            ..lineTo(end, y)
            ..lineTo(end - 3, y + 3),
          pen,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _GoalEdges old) =>
      old.graph.rects != graph.rects || old.color != color;
}
