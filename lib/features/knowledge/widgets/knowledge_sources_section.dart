import '../../../app/l10n/app_strings.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../../home/views/home_style.dart';
import '../../progress/models/progress_models.dart' show voiceTime;
import '../../progress/viewmodels/progress_view_model.dart';
import '../../progress/viewmodels/voice_evidence_controller.dart';
import '../../progress/widgets/voice_evidence_player.dart';
import '../models/knowledge_models.dart';
import '../repositories/knowledge_source_checks.dart';
import '../viewmodels/knowledge_view_model.dart';
import 'knowledge_components.dart';

class KnowledgeSourcesSection extends StatefulWidget {
  const KnowledgeSourcesSection({
    super.key,
    required this.document,
    required this.version,
  });
  final KnowledgeDocument document;
  final KnowledgeVersion version;
  @override
  State<KnowledgeSourcesSection> createState() =>
      _KnowledgeSourcesSectionState();
}

class _KnowledgeSourcesSectionState extends State<KnowledgeSourcesSection>
    with WidgetsBindingObserver {
  Object? _knowledgeRevision, _progressData;
  String? _versionId;
  Stream<List<KnowledgeSourceCheck>>? _stream;

  VoiceEvidenceController? _audio;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _audio = context.read<VoiceEvidenceController>();
    _refreshIfChanged();
  }

  @override
  void didUpdateWidget(covariant KnowledgeSourcesSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    _refreshIfChanged();
  }

  void _refreshIfChanged() {
    final kb = context.read<KnowledgeViewModel>();
    final progress = context.read<ProgressViewModel>();
    final identity = '${widget.document.id}:${widget.version.id}';
    if (_knowledgeRevision != kb.sourceRevision ||
        !identical(_progressData, progress.data) ||
        _versionId != identity) {
      _knowledgeRevision = kb.sourceRevision;
      _progressData = progress.data;
      _versionId = identity;
      unawaited(_audio?.suspend());
      _stream = KnowledgeSourceChecks(
        kb,
        progress,
      ).watch(widget.document.id, widget.version.id);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) unawaited(_audio?.suspend());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_audio?.suspend());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    context.watch<KnowledgeViewModel>();
    context.watch<ProgressViewModel>();
    _refreshIfChanged();
    final reduced = MediaQuery.disableAnimationsOf(context);
    return Column(
      key: const ValueKey('knowledge-sources'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(
              Icons.auto_awesome_mosaic_outlined,
              size: 16,
              color: HomeStyle.blue,
            ),
            const SizedBox(width: 7),
            Expanded(
              child: Text(
                '来源与版本核对'.tr(context),
                style: HomeStyle.text(14, bold: true),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        StreamBuilder<List<KnowledgeSourceCheck>>(
          key: ValueKey('${widget.document.id}:${widget.version.id}'),
          stream: _stream,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return KnowledgeSurface(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('来源暂时读取失败'.tr(context), style: HomeStyle.text(13)),
                    TextButton(
                      onPressed: () => setState(() {
                        _knowledgeRevision = null;
                        _refreshIfChanged();
                      }),
                      child: Text('重新核对'.tr(context)),
                    ),
                  ],
                ),
              );
            }
            final waiting =
                !snapshot.hasData &&
                (snapshot.connectionState == ConnectionState.waiting ||
                    snapshot.connectionState == ConnectionState.none);
            final rows = waiting
                ? <KnowledgeSourceCheck>[]
                : (snapshot.data ?? <KnowledgeSourceCheck>[])
                      .where(
                        (row) =>
                            row.matchPercent == null || row.matchPercent! >= 60,
                      )
                      .toList();
            return Column(
              children: [
                if (snapshot.connectionState == ConnectionState.done &&
                    rows.isEmpty)
                  KnowledgeSurface(
                    key: const ValueKey('knowledge-sources-empty'),
                    child: Text(
                      '暂无匹配来源'.tr(context),
                      style: HomeStyle.text(
                        13,
                        color: HomeStyle.secondary(context),
                      ),
                    ),
                  ),
                for (final row in rows)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: TweenAnimationBuilder<double>(
                      key: ValueKey('${widget.version.id}:${row.key}'),
                      tween: Tween(begin: reduced ? 1 : 0, end: 1),
                      duration: reduced
                          ? Duration.zero
                          : const Duration(milliseconds: 240),
                      builder: (context, value, child) => Opacity(
                        opacity: value,
                        child: Transform.translate(
                          offset: Offset(0, 6 * (1 - value)),
                          child: child,
                        ),
                      ),
                      child: _sourceCard(row),
                    ),
                  ),
                if (snapshot.connectionState != ConnectionState.done)
                  for (var i = rows.isEmpty ? 0 : 1; i < 2; i++)
                    KnowledgeSourceSkeleton(reduced: reduced),
              ],
            );
          },
        ),
      ],
    );
  }

  Widget _sourceCard(KnowledgeSourceCheck row) {
    final voice = row.link?.kind == KnowledgeSourceKind.voice;
    final tag = !row.available
        ? '待核对'.tr(context)
        : row.matchPercent != null
        ? '${row.matchPercent}% 匹配'
        : '匹配度不可用'.tr(context);
    final summary = !row.available
        ? '${row.status} · ${row.subtitle}'
        : row.text.isNotEmpty
        ? row.text
        : row.subtitle;
    return KnowledgeReferenceCard(
      key: ValueKey('knowledge-source-card-${row.key}'),
      titleText: row.title,
      summary: summary,
      badgeText: tag,
      icon: voice ? Icons.mic_none : Icons.description_outlined,
      accent: row.available ? HomeStyle.blue : HomeStyle.secondary(context),
      onTap: () => _openSource(row),
    );
  }

  Future<void> _openSource(KnowledgeSourceCheck original) async {
    final kb = context.read<KnowledgeViewModel>();
    final progress = context.read<ProgressViewModel>();
    final row = original.link == null
        ? original
        : KnowledgeSourceChecks(kb, progress).resolve(original.link!);
    if (row.document != null && row.version != null && row.available) {
      await context.push(
        Uri(
          path: '/knowledge/documents/${row.document!.id}',
          queryParameters: {'version': row.version!.id},
        ).toString(),
      );
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (sheet) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: .65,
        minChildSize: .35,
        maxChildSize: .9,
        builder: (context, scroll) {
          final liveKb = context.watch<KnowledgeViewModel>();
          final liveProgress = context.watch<ProgressViewModel>();
          final row = original.link == null
              ? original
              : KnowledgeSourceChecks(
                  liveKb,
                  liveProgress,
                ).resolve(original.link!);
          return SingleChildScrollView(
            controller: scroll,
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(row.title, style: HomeStyle.text(18, bold: true)),
                const SizedBox(height: 12),
                Text(
                  row.subtitle,
                  style: HomeStyle.text(
                    13,
                    color: HomeStyle.secondary(context),
                  ),
                ),
                const SizedBox(height: 12),
                KnowledgeBadge(
                  row.status,
                  color: row.available
                      ? HomeStyle.teal
                      : HomeStyle.secondary(context),
                ),
                if (row.voice case final voice?) ...[
                  const SizedBox(height: 16),
                  VoiceEvidencePlayer(
                    evidence: voice,
                    onDetails: () => knowledgeFeedback(
                      context,
                      '会话 ${voice.sessionId} · ${voiceTime(voice.start)}–${voiceTime(voice.end)}',
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text('语音转写', style: HomeStyle.text(14, bold: true)),
                  const SizedBox(height: 8),
                  SelectableText(voice.transcript, style: HomeStyle.text(14)),
                  const SizedBox(height: 10),
                  Text(
                    '说话人：${voice.speakerConfirmed ? '已核对' : '待核对'} · ${knowledgeDate(voice.recordedAt)}',
                    style: HomeStyle.text(
                      12,
                      color: HomeStyle.secondary(context),
                    ),
                  ),
                ],
                if (row.own) ...[
                  const SizedBox(height: 16),
                  SelectableText(
                    '资料编号：${row.document!.id}\n版本编号：${row.version!.id}\n'
                    '录入时间：${knowledgeDate(row.document!.createdAt)}\n'
                    '有效起点：${knowledgeDate(row.version!.createdAt)}\n'
                    '有效截止：${row.version!.validUntil == null ? '未设置' : knowledgeDate(row.version!.validUntil!)}\n\n'
                    '内容摘要（SHA-256）\n${row.version!.hash}',
                    style: HomeStyle.text(
                      12,
                      color: HomeStyle.secondary(context),
                    ),
                  ),
                ],
                if (row.link case final link?) ...[
                  const SizedBox(height: 20),
                  TextButton(
                    onPressed: () async {
                      final ok = await kb.updateSource(
                        widget.document.id,
                        widget.version.id,
                        link,
                        remove: true,
                      );
                      if (sheet.mounted && ok) Navigator.pop(sheet);
                      if (mounted && !ok) {
                        knowledgeFeedback(
                          this.context,
                          kb.actionError ?? '取消关联未完成',
                        );
                      }
                    },
                    child: const Text('取消来源关联'),
                  ),
                ],
              ],
            ),
          );
        },
      ),
    );
    await _audio?.suspend();
  }
}

class KnowledgeSourceSkeleton extends StatefulWidget {
  const KnowledgeSourceSkeleton({
    super.key,
    required this.reduced,
    this.label = "正在核对来源",
  });
  final String label;
  final bool reduced;
  @override
  State<KnowledgeSourceSkeleton> createState() =>
      KnowledgeSourceSkeletonState();
}

class KnowledgeSourceSkeletonState extends State<KnowledgeSourceSkeleton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _sweep = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  );
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (widget.reduced || !TickerMode.valuesOf(context).enabled) {
      _sweep.stop();
    } else {
      _sweep.repeat();
    }
  }

  @override
  void didUpdateWidget(covariant KnowledgeSourceSkeleton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.reduced) {
      _sweep.stop();
    } else if (TickerMode.valuesOf(context).enabled && !_sweep.isAnimating) {
      _sweep.repeat();
    }
  }

  @override
  void dispose() {
    _sweep.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Semantics(
    label: widget.label.tr(context),
    child: Container(
      height: 76,
      margin: const EdgeInsets.only(bottom: 12),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: HomeStyle.surface(context),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: HomeStyle.secondary(context).withValues(alpha: .09),
          width: 1.5,
        ),
      ),
      child: widget.reduced
          ? const SizedBox.expand()
          : AnimatedBuilder(
              animation: _sweep,
              builder: (context, _) => FractionalTranslation(
                translation: Offset(-1.5 + 3 * _sweep.value, 0),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        Color(0x00EAF1FF),
                        HomeStyle.tintColor(context, const Color(0xFFEAF1FF)),
                        Color(0x00EAF1FF),
                      ],
                      stops: [0, .5, 1],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                  ),
                  child: SizedBox.expand(),
                ),
              ),
            ),
    ),
  );
}
