import '../../../shared/widgets/content_skeleton.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../../../app/l10n/app_strings.dart';
import '../../home/views/home_style.dart';
import '../../knowledge/viewmodels/knowledge_view_model.dart';
import '../../knowledge/widgets/knowledge_components.dart';
import '../../knowledge/models/knowledge_models.dart';
import '../../knowledge/repositories/knowledge_source_checks.dart';
import '../../knowledge/repositories/dio_knowledge_repository.dart';
import '../models/progress_models.dart';
import '../repositories/goal_knowledge_matcher.dart';
import 'progress_components.dart';
import 'voice_evidence_player.dart';

/// 已建立的来源关系与搜索推荐分开，版本不符不显示为有效附件。
class BoundKnowledgeSection extends StatelessWidget {
  const BoundKnowledgeSection({
    super.key,
    required this.references,
    this.relationLabel = '',
    this.relationQuery = '',
    this.relationQuote = '',
  });
  final List<Map<String, dynamic>> references;
  final String relationLabel, relationQuery, relationQuote;
  @override
  Widget build(BuildContext context) {
    final kb = context.watch<KnowledgeViewModel>();
    final valid = <(KnowledgeDocument, KnowledgeVersion)>[];
    for (final ref in references) {
      final doc = kb.document(ref['documentId'] as String? ?? '');
      final version = doc?.versions
          .where(
            (v) =>
                v.id == ref['versionId'] &&
                v.hash == ref['hash'] &&
                v.state == KnowledgeValidity.current,
          )
          .firstOrNull;
      if (doc != null &&
          version != null &&
          !valid.any((row) => row.$1.id == doc.id)) {
        valid.add((doc, version));
      }
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionHeader(
          title: '知识库',
          icon: Icons.menu_book_outlined,
          count: valid.length,
        ),
        const SizedBox(height: 10),
        if (kb.loading && valid.isEmpty)
          const ContentSkeleton(rows: 1, scrollable: false, label: '正在加载关联资料')
        else if (kb.error != null)
          const ProgressEmpty('资料暂时读取失败')
        else if (valid.isEmpty)
          const ProgressEmpty('暂无关联资料'),
        for (final (doc, version) in valid)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: KnowledgeReferenceCard(
              titleText: version.title,
              summary: knowledgePreview(version.content),
              badgeText: '来源关联',
              onTap: () => context.push(
                Uri(
                  path: '/knowledge/documents/${doc.id}',
                  queryParameters: {
                    'version': version.id,
                    'hash': version.hash,
                    if (relationLabel.isNotEmpty) 'relation': relationLabel,
                    if (relationQuery.isNotEmpty)
                      'relationQuery': relationQuery,
                    if (relationQuote.isNotEmpty) 'quote': relationQuote,
                  },
                ).toString(),
              ),
            ),
          ),
      ],
    );
  }
}

/// 文档产生的履约候选沿用资料引用卡，不显示虚假的语音播放器。
class DocumentEvidenceReference extends StatelessWidget {
  const DocumentEvidenceReference({
    super.key,
    required this.evidence,
    this.relationLabel,
    this.relationQuery,
  });
  final VoiceEvidence evidence;
  final String? relationLabel, relationQuery;
  @override
  Widget build(BuildContext context) {
    final document = context.watch<KnowledgeViewModel>().document(
      evidence.documentId ?? '',
    );
    final version = document?.versions
        .where((v) => v.id == evidence.versionId)
        .firstOrNull;
    return KnowledgeReferenceCard(
      titleText: version?.title ?? '原文依据'.tr(context),
      summary: evidence.transcript,
      badgeText: (version == null ? '待核对' : '原文依据').tr(context),
      onTap: version == null
          ? null
          : () => context.push(
              Uri(
                path: '/knowledge/documents/${document!.id}',
                queryParameters: {
                  'version': version.id,
                  'hash': version.hash,
                  'relation': ?relationLabel,
                  'relationQuery': ?relationQuery,
                  if (relationLabel != null) 'quote': evidence.transcript,
                },
              ).toString(),
            ),
    );
  }
}

class GoalCommitmentsSection extends StatefulWidget {
  const GoalCommitmentsSection({super.key, required this.items});
  final List<Commitment> items;
  @override
  State<GoalCommitmentsSection> createState() => _GoalCommitmentsSectionState();
}

class _GoalCommitmentsSectionState extends State<GoalCommitmentsSection> {
  bool _all = false;
  @override
  Widget build(BuildContext context) => ProgressCard(
    child: Column(
      children: [
        _SectionHeader(
          title: '关联承诺',
          icon: Icons.handshake_outlined,
          count: widget.items.length,
          action: widget.items.length <= 2
              ? null
              : TextButton(
                  onPressed: () => setState(() => _all = !_all),
                  child: Text(
                    (_all ? '收起承诺' : '全部承诺').tr(context),
                    style: HomeStyle.text(
                      11,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                ),
        ),
        if (widget.items.isEmpty)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              '暂无关联承诺'.tr(context),
              style: HomeStyle.text(13, color: HomeStyle.secondary(context)),
            ),
          ),
        for (final item in _all ? widget.items : widget.items.take(2)) ...[
          const SizedBox(height: 8),
          _CommitmentCard(item: item),
        ],
      ],
    ),
  );
}

class _CommitmentCard extends StatelessWidget {
  const _CommitmentCard({required this.item});
  final Commitment item;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final accent = item.side == CommitmentSide.ours
        ? colors.primary
        : const Color(0xFF7568DB);
    final status = item.statusAt(DateTime.now());
    final statusColor = status == CommitmentStatus.active
        ? colors.primary
        : HomeStyle.secondary(context);
    final role = Row(
      children: [
        Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(color: accent, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            item.side.itemLabel.tr(context),
            style: HomeStyle.text(11, color: accent),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
    final badge = ProgressTag(
      status.label.tr(context),
      color: statusColor,
      icon: status == CommitmentStatus.active
          ? Icons.timelapse
          : Icons.schedule,
    );
    return Container(
      key: ValueKey('goal-commitment-${item.id}'),
      decoration: BoxDecoration(
        color: HomeStyle.surface(context),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: colors.primary.withValues(alpha: .1)),
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(14),
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              LayoutBuilder(
                builder: (context, constraints) =>
                    MediaQuery.textScalerOf(context).scale(12) > 18 ||
                        constraints.maxWidth < 270
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [role, const SizedBox(height: 6), badge],
                      )
                    : Row(
                        children: [
                          Expanded(child: role),
                          const SizedBox(width: 6),
                          badge,
                        ],
                      ),
              ),
              const SizedBox(height: 8),
              Text(
                item.title,
                style: HomeStyle.text(14, bold: true),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 7),
              Row(
                children: [
                  Icon(
                    Icons.calendar_today_outlined,
                    size: 12,
                    color: HomeStyle.secondary(context),
                  ),
                  const SizedBox(width: 5),
                  Expanded(
                    child: Text(
                      progressDate(item.deadline),
                      style: HomeStyle.text(
                        11,
                        color: HomeStyle.secondary(context),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              if (item.evidence.isDocument)
                DocumentEvidenceReference(evidence: item.evidence)
              else
                VoiceEvidencePlayer(compact: true, evidence: item.evidence),
            ],
          ),
        ),
      ),
    );
  }
}

class GoalKnowledgeSection extends StatefulWidget {
  const GoalKnowledgeSection({
    super.key,
    required this.goal,
    this.relationLabel,
    this.relationQuery,
  });
  final ProgressGoal goal;
  final String? relationLabel, relationQuery;
  @override
  State<GoalKnowledgeSection> createState() => _GoalKnowledgeSectionState();
}

class _GoalKnowledgeSectionState extends State<GoalKnowledgeSection> {
  ProgressGoal get goal => widget.goal;
  Object? _scope;
  Future<List<KnowledgeHit>>? _future;
  String get _query =>
      widget.relationQuery ??
      [
        goal.title,
        goal.condition,
        goal.acceptance,
        ...goal.milestones.map((m) => m.title),
      ].join(' ');
  @override
  Widget build(BuildContext context) {
    final kb = context.watch<KnowledgeViewModel>();
    if (kb.repository is DioKnowledgeRepository &&
        !kb.loading &&
        kb.error == null) {
      final scope = (kb.sourceRevision, goal.id, _query, goal.projectId);
      if (_scope != scope) {
        _scope = scope;
        _future = kb.findReferences(
          _query,
          projectId: goal.projectId == 'personal-meetings'
              ? null
              : goal.projectId,
        );
      }
      return FutureBuilder<List<KnowledgeHit>>(
        key: ValueKey(scope),
        future: _future,
        builder: (context, snapshot) {
          final hits = snapshot.connectionState == ConnectionState.done
              ? snapshot.data ?? []
              : <KnowledgeHit>[];
          final seen = <String>{};
          final documents = <KnowledgeDocument>[];
          for (final h in hits) {
            final d = kb.document(h.documentId);
            if (d != null && seen.add(d.id) && kb.retrievable(d)) {
              documents.add(d.copyWith(selectedVersionId: h.versionId));
            }
          }
          return _content(
            context,
            kb,
            documents,
            pending: snapshot.connectionState != ConnectionState.done,
            failed: snapshot.hasError,
            excerpts: {
              for (final d in documents)
                d.id: hits
                    .firstWhere(
                      (h) =>
                          h.documentId == d.id &&
                          h.versionId == d.selectedVersionId,
                    )
                    .text,
            },
            percentages: {
              for (final d in documents)
                d.id: hits
                    .firstWhere(
                      (h) =>
                          h.documentId == d.id &&
                          h.versionId == d.selectedVersionId,
                    )
                    .matchPercent,
            },
            references: {
              for (final d in documents)
                d.id: hits.firstWhere(
                  (h) =>
                      h.documentId == d.id &&
                      h.versionId == d.selectedVersionId,
                ),
            },
          );
        },
      );
    }
    final documents = matchGoalDocuments(goal, kb.data);
    return _content(context, kb, documents);
  }

  Widget _content(
    BuildContext context,
    KnowledgeViewModel kb,
    List<KnowledgeDocument> documents, {
    bool pending = false,
    bool failed = false,
    Map<String, String> excerpts = const {},
    Map<String, int?> percentages = const {},
    Map<String, KnowledgeHit> references = const {},
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionHeader(
          title: '知识库',
          icon: Icons.menu_book_outlined,
          count: documents.length,
          action: TextButton(
            onPressed: () => context.go('/knowledge'),
            child: Text(
              '打开知识库'.tr(context),
              style: HomeStyle.text(
                11,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
          ),
        ),
        const SizedBox(height: 10),
        if ((kb.loading || pending) && documents.isEmpty)
          const ContentSkeleton(rows: 1, scrollable: false, label: '正在检索关联资料')
        else if (kb.error != null || failed)
          KnowledgeSurface(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('资料暂时读取失败'.tr(context), style: HomeStyle.text(13)),
                TextButton(
                  onPressed: () {
                    _scope = null;
                    kb.load();
                  },
                  child: Text('重试'.tr(context)),
                ),
              ],
            ),
          )
        else if (documents.isEmpty)
          ProgressEmpty('暂无匹配资料'.tr(context))
        else
          for (final document in documents)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: KnowledgeReferenceCard(
                key: ValueKey('goal-knowledge-${document.id}'),
                titleText: document.selected.title,
                summary:
                    knowledgePreview(
                      excerpts[document.id] ?? document.selected.content,
                    ).isEmpty
                    ? (document.filename ?? document.displayType)
                    : knowledgePreview(
                        excerpts[document.id] ?? document.selected.content,
                      ),
                badgeText: _matchLabel(
                  context,
                  percentages.containsKey(document.id)
                      ? percentages[document.id]
                      : sourceMatchPercent(
                          _query,
                          excerpts[document.id] ??
                              [
                                document.selected.title,
                                document.filename ?? '',
                                ...document.tags,
                                document.selected.content,
                              ].join(' '),
                        ),
                ),
                onTap: () => context.push(
                  Uri(
                    path: '/knowledge/documents/${document.id}',
                    queryParameters: {
                      'version': document.selectedVersionId,
                      'hash': document.selected.hash,
                      'relation':
                          widget.relationLabel ?? '目标关联 · ${goal.title}',
                      'relationQuery': _query,
                      if (references[document.id] case final hit?) ...{
                        'start': '${hit.start}',
                        'end': '${hit.end}',
                        'quote': hit.text,
                      },
                    },
                  ).toString(),
                ),
              ),
            ),
      ],
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    required this.title,
    required this.icon,
    required this.count,
    this.action,
  });
  final String title;
  final IconData icon;
  final int count;
  final Widget? action;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final label = Row(
      children: [
        Icon(icon, size: 18, color: colors.primary),
        const SizedBox(width: 7),
        Expanded(
          child: Text(title.tr(context), style: HomeStyle.text(14, bold: true)),
        ),
        const SizedBox(width: 6),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: colors.primary.withValues(alpha: .065),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            '$count',
            style: HomeStyle.text(11, color: colors.primary),
          ),
        ),
      ],
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        if (action == null) return label;
        if (MediaQuery.textScalerOf(context).scale(12) > 18) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              label,
              Align(alignment: Alignment.centerRight, child: action),
            ],
          );
        }
        return Row(
          children: [
            Expanded(child: label),
            const SizedBox(width: 8),
            action!,
          ],
        );
      },
    );
  }
}

String _matchLabel(BuildContext context, int? percent) =>
    percent == null ? '匹配度不可用'.tr(context) : '$percent% ${'匹配'.tr(context)}';
