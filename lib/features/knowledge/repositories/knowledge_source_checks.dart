import '../../../core/network/relevance.dart';
import '../../progress/models/progress_models.dart';
import '../../progress/viewmodels/progress_view_model.dart';
import '../models/knowledge_models.dart';
import '../viewmodels/knowledge_view_model.dart';
import 'dio_knowledge_repository.dart';

String voiceSourceHash(VoiceEvidence e) => knowledgeHash(
  '${e.id}|${e.sessionId}|${e.start.inMilliseconds}|${e.end.inMilliseconds}|${e.transcript}',
);

/// 与云端检索使用相同版本的词面相关度。
int? sourceMatchPercent(String source, String target) =>
    textRelevancePercent(source, target);

class KnowledgeSourceCheck {
  const KnowledgeSourceCheck({
    required this.title,
    required this.subtitle,
    required this.status,
    this.text = '',
    this.document,
    this.version,
    this.voice,
    this.link,
    this.available = false,
    this.own = false,
    this.matchPercent,
  });
  final String title, subtitle, status, text;
  final KnowledgeDocument? document;
  final KnowledgeVersion? version;
  final VoiceEvidence? voice;
  final KnowledgeSourceLink? link;
  final bool available, own;
  final int? matchPercent;
  String get key => link?.key ?? '${document?.id}:${version?.id}';
}

/// 逐项核对引用与检索结果，不把当前资料与自身比较为 100% 匹配。
class KnowledgeSourceChecks {
  const KnowledgeSourceChecks(this.knowledge, this.progress);
  final KnowledgeViewModel knowledge;
  final ProgressViewModel progress;

  Stream<List<KnowledgeSourceCheck>> watch(
    String documentId,
    String versionId,
  ) async* {
    final d = knowledge.document(documentId);
    if (d == null) throw StateError('资料已移除');
    final v = d.versions.firstWhere((v) => v.id == versionId);
    final results = <KnowledgeSourceCheck>[];
    final scope = knowledge.sourceRevision;
    yield List.unmodifiable(results);
    for (final link in v.sources) {
      if (knowledge.sourceRevision != scope) return;
      if (link.kind == KnowledgeSourceKind.document &&
          link.targetId == documentId) {
        continue;
      }
      final check = await Future(
        () => resolve(link, against: '${v.title} ${v.content}'),
      );
      results.add(check);
      yield List.unmodifiable(results);
    }
    final repository = knowledge.repository;
    if (repository is DioKnowledgeRepository) {
      final owner = repository.accountId;
      final hits = await repository
          .search('${v.title} ${v.content}')
          .timeout(const Duration(seconds: 30));
      final seen = {
        documentId,
        ...v.sources
            .where((s) => s.kind == KnowledgeSourceKind.document)
            .map((s) => s.targetId),
      };
      for (final hit in hits) {
        if (owner != repository.accountId ||
            knowledge.sourceRevision != scope) {
          return;
        }
        if (!seen.add(hit['documentId']) ||
            !await repository
                .resolve(hit)
                .timeout(const Duration(seconds: 30))) {
          continue;
        }
        final source = knowledge.document(hit['documentId']);
        final version = source?.versions
            .where((s) => s.id == hit['versionId'])
            .firstOrNull;
        if (source == null ||
            version == null ||
            owner != repository.accountId ||
            knowledge.sourceRevision != scope) {
          continue;
        }
        results.add(
          KnowledgeSourceCheck(
            title: hit['title'],
            subtitle: source.filename ?? source.source,
            status: '版本与原文校验通过',
            text: knowledgePreview(hit['text']),
            document: source,
            version: version,
            available: true,
            matchPercent: hit['matchPercent'] is int
                ? hit['matchPercent'] as int
                : sourceMatchPercent(
                    '${v.title} ${v.content}',
                    '${hit['title']}\n${hit['text']}',
                  ),
          ),
        );
        yield List.unmodifiable(results);
      }
    }
  }

  KnowledgeSourceCheck resolve(
    KnowledgeSourceLink link, {
    String against = '',
  }) {
    if (link.kind == KnowledgeSourceKind.voice) {
      final c = progress.commitment(link.targetId);
      if (c == null) {
        return KnowledgeSourceCheck(
          title: '语音来源不可用',
          subtitle: '原会话或语音已移除',
          status: '来源失效',
          link: link,
        );
      }
      final e = c.evidence;
      final allowed = e.access == EvidenceAccess.authorized;
      final same =
          allowed && e.id == link.versionId && voiceSourceHash(e) == link.hash;
      return KnowledgeSourceCheck(
        title: c.title,
        subtitle:
            '会话 ${e.sessionId} · ${voiceTime(e.start)}–${voiceTime(e.end)}',
        status: !allowed
            ? '语音来源未授权'
            : !same
            ? '语音或转写已变更'
            : e.source == EvidenceSource.missingDemo
            ? '演示来源 · 示例音频未提供'
            : '转写与时间段校验通过',
        text: allowed && same ? e.transcript : '',
        matchPercent: allowed && same
            ? sourceMatchPercent(against, e.transcript)
            : null,
        voice: allowed && same ? e : null,
        link: link,
        available: allowed && same,
      );
    }
    final d = knowledge.document(link.targetId);
    final versions = d?.versions.where((v) => v.id == link.versionId);
    if (d == null || versions == null || versions.isEmpty) {
      return KnowledgeSourceCheck(
        title: '文档来源不可用',
        subtitle: '原文档或绑定版本已移除',
        status: '来源失效',
        link: link,
      );
    }
    final v = versions.first;
    final same = v.hash == link.hash && v.integrityOk;
    final allowed = knowledge.retrievable(d) && d.effective?.id == v.id;
    return KnowledgeSourceCheck(
      title: v.title,
      subtitle: d.filename ?? d.source,
      status: !same
          ? '原文内容校验异常'
          : !allowed
          ? '版本已变化或资料不可用 · 请重新核对'
          : '版本与原文校验通过',
      text: same && allowed ? knowledgePreview(v.content) : '',
      matchPercent: same && allowed
          ? sourceMatchPercent(against, v.content)
          : null,
      document: d,
      version: v,
      link: link,
      available: same && allowed,
    );
  }
}
