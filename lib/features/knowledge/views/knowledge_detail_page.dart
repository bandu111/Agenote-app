import '../widgets/document_actions_section.dart';
import '../../../shared/widgets/content_skeleton.dart';
import '../../../app/l10n/app_strings.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../../home/views/home_style.dart';
import '../models/knowledge_models.dart';
import '../viewmodels/knowledge_view_model.dart';
import '../widgets/knowledge_components.dart';
import '../widgets/knowledge_sources_section.dart';
import '../widgets/knowledge_original_overview.dart';
import 'knowledge_pdf_preview_page.dart';
import '../../progress/models/progress_models.dart';
import '../../progress/widgets/voice_evidence_player.dart';
import '../../meeting/minutes/meeting_minutes_page.dart';

class KnowledgeDetailPage extends StatefulWidget {
  const KnowledgeDetailPage({
    super.key,
    required this.id,
    this.versionId,
    this.start,
    this.end,
    this.hash,
    this.relationLabel,
    this.relationQuery,
    this.relationQuote,
  });
  final String id;
  final String? versionId, hash;
  final String? relationLabel, relationQuery, relationQuote;
  final int? start, end;
  @override
  State<KnowledgeDetailPage> createState() => _KnowledgeDetailPageState();
}

class _KnowledgeDetailPageState extends State<KnowledgeDetailPage> {
  bool _opening = false;
  void _back() {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go('/knowledge');
    }
  }

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<KnowledgeViewModel>();
    final d = vm.document(widget.id);
    if (vm.loading && d == null) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('资料详情'),
          leading: BackButton(onPressed: _back),
        ),
        body: const ContentSkeleton(
          layout: SkeletonLayout.document,
          label: '正在加载资料',
        ),
      );
    }
    if (d == null) {
      return Scaffold(
        appBar: AppBar(
          title: Text('资料详情'.tr(context)),
          leading: BackButton(onPressed: _back),
        ),
        body: Center(child: Text(vm.error ?? '资料已移除或暂不可用')),
      );
    }
    final matches = d.versions.where(
      (v) => v.id == (widget.versionId ?? d.selectedVersionId),
    );
    final v = matches.isEmpty ? d.selected : matches.first;
    if (d.source.startsWith('meeting:')) {
      if (widget.relationLabel != null) {
        if (widget.hash != v.hash ||
            widget.versionId != v.id ||
            !v.integrityOk ||
            d.effective?.id != v.id) {
          return Scaffold(
            appBar: AppBar(
              title: const Text('会议纪要'),
              leading: BackButton(onPressed: _back),
            ),
            body: const Center(child: Text('关联资料版本已更新，请返回后重新加载')),
          );
        }
        final quote = widget.relationQuote ?? '';
        String plain(String value) => value.replaceAll(RegExp(r'\s+'), '');
        final verifiedQuote =
            quote.isNotEmpty && plain(v.content).contains(plain(quote))
            ? quote
            : '';
        return MeetingMinutesPage(
          id: d.source.substring(8),
          documentId: d.id,
          relationLabel: widget.relationLabel,
          relationQuery: widget.relationQuery,
          relationQuote: verifiedQuote,
        );
      }
      String? focus;
      if (widget.start != null && widget.end != null) {
        final valid =
            widget.hash == v.hash &&
            v.integrityOk &&
            d.effective?.id == v.id &&
            widget.start! >= 0 &&
            widget.end! > widget.start! &&
            widget.end! <= v.content.length;
        if (!valid) {
          return Scaffold(
            appBar: AppBar(
              title: const Text('会议纪要'),
              leading: BackButton(onPressed: _back),
            ),
            body: const Center(child: Text('这条引用已失效，请重新检索')),
          );
        }
        final selected = v.content.substring(widget.start!, widget.end!);
        focus = RegExp(r'〔来源：([^〕,]+)').firstMatch(selected)?.group(1)?.trim();
        focus ??= RegExp(
          r'^### (\S+) ·',
          multiLine: true,
        ).allMatches(v.content.substring(0, widget.end!)).lastOrNull?.group(1);
      }
      return MeetingMinutesPage(
        id: d.source.substring(8),
        documentId: d.id,
        focusUtterance: focus,
      );
    }
    final reference = widget.start == null || widget.end == null
        ? null
        : KnowledgeHit(
            documentId: d.id,
            versionId: widget.versionId ?? v.id,
            number: v.number,
            projectId: d.projectId,
            source: d.source,
            hash: widget.hash ?? '',
            text:
                widget.start! >= 0 &&
                    widget.end! <= v.content.length &&
                    widget.end! > widget.start!
                ? v.content.substring(widget.start!, widget.end!)
                : '',
            start: widget.start!,
            end: widget.end!,
          );
    final validReference =
        reference != null && vm.resolveHit(reference) != null;
    return Scaffold(
      backgroundColor: HomeStyle.canvas(context),
      appBar: AppBar(
        title: Text('资料详情'.tr(context)),
        leading: BackButton(onPressed: _back),
      ),
      body: SafeArea(
        top: false,
        child: SingleChildScrollView(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final (index, audio) in d.audioRefs.indexed) ...[
                      Text(
                        d.audioRefs.length > 1
                            ? '原始录音 · 分卷 ${index + 1}'
                            : '原始录音',
                        style: HomeStyle.text(14, bold: true),
                      ),
                      const SizedBox(height: 8),
                      VoiceEvidencePlayer(
                        evidence: VoiceEvidence(
                          id: 'knowledge-audio-${audio['id']}',
                          commitmentId: '',
                          sessionId: d.source.startsWith('meeting:')
                              ? d.source.substring(8)
                              : '',
                          uri: Uri(scheme: 'yanshu-audio', path: audio['id']),
                          start: Duration.zero,
                          end: Duration(
                            milliseconds: audio['duration'] is num
                                ? (audio['duration'] as num).toInt().clamp(
                                    0,
                                    86400000,
                                  )
                                : 0,
                          ),
                          transcript: v.content,
                          recordedAt: d.createdAt,
                          timeZone: 'Asia/Shanghai',
                          source: EvidenceSource.provided,
                          access: EvidenceAccess.authorized,
                        ),
                      ),
                      const SizedBox(height: 14),
                    ],
                    if (d.source.startsWith('meeting:'))
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: TextButton.icon(
                          onPressed: () => context.push(
                            '/meeting?id=${Uri.encodeComponent(d.source.substring(8))}',
                          ),
                          icon: const Icon(Icons.mic_none),
                          label: const Text('打开会议记录与录音'),
                        ),
                      ),
                    if (reference != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 14),
                        child: KnowledgeSurface(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                validReference ? '已定位原文引用' : '这条引用已失效，请重新检索',
                                style: HomeStyle.text(
                                  14,
                                  bold: true,
                                  color: validReference
                                      ? HomeStyle.blue
                                      : HomeStyle.secondary(context),
                                ),
                              ),
                              if (validReference) ...[
                                const SizedBox(height: 6),
                                Text(
                                  'v${reference.number} · ${reference.span}',
                                  style: HomeStyle.text(
                                    12,
                                    color: HomeStyle.secondary(context),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    KnowledgeOriginalOverview(
                      document: d,
                      version: v,
                      opening: _opening,
                      onOpen: () async {
                        if (_opening) return;
                        {
                          setState(() => _opening = true);
                          await Navigator.of(
                            context,
                            rootNavigator: true,
                          ).push<void>(
                            MaterialPageRoute(
                              fullscreenDialog: true,
                              builder: (_) => KnowledgePdfPreviewPage(
                                document: d,
                                version: v,
                              ),
                            ),
                          );
                          if (mounted) setState(() => _opening = false);
                        }
                      },
                    ),
                    const SizedBox(height: 14),
                    DocumentActionsSection(
                      key: ValueKey('${d.id}:${v.id}'),
                      documentId: d.id,
                      versionId: v.id,
                    ),
                    KnowledgeSourcesSection(document: d, version: v),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

Future<void> showKnowledgeValidity(
  BuildContext context,
  KnowledgeDocument d,
  KnowledgeVersion v,
) => showDialog<void>(
  context: context,
  useRootNavigator: true,
  builder: (_) => _ValidityDialog(document: d, version: v),
);

class _ValidityDialog extends StatefulWidget {
  const _ValidityDialog({required this.document, required this.version});
  final KnowledgeDocument document;
  final KnowledgeVersion version;
  @override
  State<_ValidityDialog> createState() => _ValidityDialogState();
}

class _ValidityDialogState extends State<_ValidityDialog> {
  late KnowledgeValidity _state = widget.version.state;
  final _note = TextEditingController();
  bool _checked = false, _busy = false, _clearExpiry = false;
  late DateTime? _until = widget.version.validUntil;
  String? _error;
  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('核对 v${widget.version.number}'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          DropdownButtonFormField<KnowledgeValidity>(
            key: const ValueKey('knowledge-validity-state'),
            initialValue: _state,
            isExpanded: true,
            items: KnowledgeValidity.values
                .map(
                  (s) => DropdownMenuItem(
                    value: s,
                    child: Text(s.label.tr(context)),
                  ),
                )
                .toList(),
            onChanged: (s) {
              if (s != null) setState(() => _state = s);
            },
          ),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('knowledge-validity-note'),
            controller: _note,
            minLines: 2,
            maxLines: 4,
            decoration: const InputDecoration(labelText: '核对依据 / 变更原因'),
          ),
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              TextButton(
                onPressed: _busy
                    ? null
                    : () async {
                        final picked = await showDatePicker(
                          context: context,
                          initialDate: _until ?? DateTime.now(),
                          firstDate: DateTime(2020),
                          lastDate: DateTime(2100),
                        );
                        if (!mounted || picked == null) return;
                        setState(() {
                          _until = DateTime(
                            picked.year,
                            picked.month,
                            picked.day,
                            23,
                            59,
                            59,
                          );
                          _clearExpiry = false;
                        });
                      },
                child: Text(
                  _until == null ? '设置有效截止日期' : '有效至 ${knowledgeDate(_until!)}',
                ),
              ),
              if (_until != null)
                TextButton(
                  onPressed: () => setState(() {
                    _until = null;
                    _clearExpiry = true;
                  }),
                  child: const Text('清除期限'),
                ),
            ],
          ),
          if (_state == KnowledgeValidity.current)
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: _checked,
              onChanged: (v) => setState(() => _checked = v ?? false),
              title: Text('已核对来源和冲突，使用此版本', style: HomeStyle.text(13)),
            ),
          Text(
            '设为当前版本后，原可用版本标记为过期；此操作只管理资料版本，不代表正式业务批准。',
            style: HomeStyle.text(12, color: HomeStyle.secondary(context)),
          ),
          if (_error != null)
            Text(
              _error!,
              style: HomeStyle.text(
                13,
                color: Theme.of(context).colorScheme.error,
              ),
            ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text('取消'.tr(context)),
      ),
      TextButton(
        key: const ValueKey('knowledge-validity-save'),
        onPressed: _busy
            ? null
            : () async {
                if (_note.text.trim().isEmpty ||
                    _state == KnowledgeValidity.current && !_checked) {
                  setState(() => _error = '请填写原因，并确认已核对当前版本');
                  return;
                }
                final vm = context.read<KnowledgeViewModel>();
                setState(() => _busy = true);
                final ok = await vm.setValidity(
                  widget.document.id,
                  widget.version.id,
                  _state,
                  _note.text,
                  validUntil: _until,
                  clearExpiry: _clearExpiry,
                );
                if (!context.mounted) return;
                if (ok) {
                  Navigator.pop(context);
                } else {
                  setState(() {
                    _busy = false;
                    _error = vm.actionError;
                  });
                }
              },
        child: Text('保存'.tr(context)),
      ),
    ],
  );
}
