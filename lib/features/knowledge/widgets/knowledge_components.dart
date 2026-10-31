import '../../../app/l10n/app_strings.dart';
import 'package:flutter/material.dart';
import '../../home/views/home_style.dart';
import '../models/knowledge_models.dart';

class KnowledgeSurface extends StatelessWidget {
  const KnowledgeSurface({
    super.key,
    required this.child,
    this.padding = 16,
    this.onTap,
  });
  final Widget child;
  final double padding;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      color: HomeStyle.surface(context),
      borderRadius: BorderRadius.circular(16),
      border: Border.all(
        color: HomeStyle.secondary(context).withValues(alpha: .10),
      ),
      boxShadow: const [
        BoxShadow(
          color: Color(0x08577CB8),
          blurRadius: 10,
          offset: Offset(0, 4),
        ),
      ],
    ),
    child: Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(padding: EdgeInsets.all(padding), child: child),
      ),
    ),
  );
}

class KnowledgeBadge extends StatelessWidget {
  const KnowledgeBadge(
    this.label, {
    super.key,
    this.icon,
    this.color = HomeStyle.blue,
  });
  final String label;
  final IconData? icon;
  final Color color;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
    decoration: BoxDecoration(
      color: color.withValues(alpha: .075),
      borderRadius: BorderRadius.circular(6),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null) ...[
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 4),
        ],
        Flexible(
          child: Text(
            label,
            style: HomeStyle.text(11, color: color, bold: true),
          ),
        ),
      ],
    ),
  );
}

class KnowledgeDocumentCard extends StatefulWidget {
  const KnowledgeDocumentCard({
    super.key,
    required this.document,
    required this.projectName,
    required this.retrievalLabel,
    this.onTap,
    this.trailing,
    this.onRename,
  });
  final KnowledgeDocument document;
  final String projectName, retrievalLabel;
  final VoidCallback? onTap;
  final Widget? trailing;
  final Future<bool> Function(String)? onRename;
  @override
  State<KnowledgeDocumentCard> createState() => _KnowledgeDocumentCardState();
}

class _KnowledgeDocumentCardState extends State<KnowledgeDocumentCard> {
  final _name = TextEditingController();
  final _focus = FocusNode();
  bool _editing = false, _saving = false;
  KnowledgeDocument get document => widget.document;
  String get projectName => widget.projectName;
  String get retrievalLabel => widget.retrievalLabel;
  VoidCallback? get onTap => widget.onTap;
  Widget? get trailing => widget.trailing;
  @override
  void dispose() {
    _name.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _edit() {
    _name.text = document.selected.title;
    _name.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _name.text.length,
    );
    setState(() => _editing = true);
    _focus.requestFocus();
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    final ok = await widget.onRename?.call(_name.text) ?? false;
    if (!mounted) return;
    setState(() {
      _saving = false;
      if (ok) _editing = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final v = document.selected;
    return KnowledgeSurface(
      onTap: _editing ? null : onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              KnowledgeBadge(
                document.displayType,
                icon: switch (document.kind) {
                  KnowledgeKind.audio => Icons.mic_none_outlined,
                  KnowledgeKind.link => Icons.link,
                  KnowledgeKind.note => Icons.edit_note,
                  _ => Icons.description_outlined,
                },
              ),
              const Spacer(),
              if (document.archived)
                const Icon(Icons.bookmark, size: 14, color: HomeStyle.blue),
              if (widget.onRename != null)
                IconButton(
                  key: ValueKey('knowledge-document-edit-${document.id}'),
                  tooltip: '修改文档名称',
                  constraints: const BoxConstraints(minWidth: 40, minHeight: 44),
                  padding: const EdgeInsets.only(left: 16, right: 4),
                  alignment: Alignment.centerRight,
                  visualDensity: VisualDensity.compact,
                  onPressed: _saving ? null : _edit,
                  icon: Icon(
                    Icons.edit_note_outlined,
                    size: 20,
                    color: HomeStyle.secondary(context),
                  ),
                ),
              Flexible(
                child: Text(
                  knowledgeDate(v.createdAt),
                  style: HomeStyle.text(
                    11,
                    color: HomeStyle.secondary(context),
                  ),
                ),
              ),
              ?trailing,
            ],
          ),
          const SizedBox(height: 10),
          if (_editing)
            Row(
              children: [
                Expanded(
                  child: TextField(
                    key: ValueKey('knowledge-document-name-${document.id}'),
                    controller: _name,
                    focusNode: _focus,
                    enabled: !_saving,
                    maxLength: 100,
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => _save(),
                    style: HomeStyle.text(15, bold: true),
                    decoration: const InputDecoration(
                      isDense: true,
                      counterText: '',
                      contentPadding: EdgeInsets.symmetric(vertical: 6),
                      enabledBorder: UnderlineInputBorder(
                        borderSide: BorderSide(color: HomeStyle.blue),
                      ),
                      focusedBorder: UnderlineInputBorder(
                        borderSide: BorderSide(color: HomeStyle.blue, width: 2),
                      ),
                    ),
                  ),
                ),
                IconButton(
                  tooltip: '保存名称',
                  onPressed: _saving ? null : _save,
                  icon: const Icon(
                    Icons.check,
                    size: 20,
                    color: HomeStyle.blue,
                  ),
                ),
                IconButton(
                  tooltip: '取消修改',
                  onPressed: _saving
                      ? null
                      : () => setState(() => _editing = false),
                  icon: Icon(
                    Icons.close,
                    size: 18,
                    color: HomeStyle.secondary(context),
                  ),
                ),
              ],
            )
          else
            Text(
              v.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: HomeStyle.text(15, bold: true),
            ),
          const SizedBox(height: 6),
          Text(
            knowledgePreview(v.content).isEmpty
                ? '仅保存链接，未读取网页正文'
                : knowledgePreview(v.content),
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: HomeStyle.text(13, color: HomeStyle.secondary(context)),
          ),
          const SizedBox(height: 11),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              ...document.tags.map(
                (t) => KnowledgeBadge(
                  t,
                  icon: Icons.tag,
                  color: HomeStyle.secondary(context),
                ),
              ),
              KnowledgeBadge(
                'v${v.number} · ${v.state.label.tr(context)}',
                color: v.state == KnowledgeValidity.current
                    ? HomeStyle.teal
                    : HomeStyle.secondary(context),
              ),
              if (document.demo)
                KnowledgeBadge('演示资料', color: HomeStyle.secondary(context)),
            ],
          ),
          const SizedBox(height: 9),
          Text(
            '$projectName · $retrievalLabel',
            style: HomeStyle.text(11, color: HomeStyle.secondary(context)),
          ),
        ],
      ),
    );
  }
}

/// Compact reference presentation, shared by source checks and goal references.
class KnowledgeReferenceCard extends StatelessWidget {
  const KnowledgeReferenceCard({
    super.key,
    required this.titleText,
    required this.summary,
    required this.badgeText,
    this.icon = Icons.description_outlined,
    this.accent,
    this.onTap,
  });
  final String titleText, summary, badgeText;
  final IconData icon;
  final Color? accent;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) {
    final title = Text(
      titleText,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: HomeStyle.text(14, bold: true),
    );
    final badge = Tooltip(
      message: '词面相关度：查询词覆盖与重合程度，不表示内容正确或已经批准。'.tr(context),
      child: KnowledgeBadge(badgeText, color: accent ?? HomeStyle.blue),
    );
    return Container(
      decoration: BoxDecoration(
        color: HomeStyle.surface(context),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: HomeStyle.secondary(context).withValues(alpha: .09),
          width: 1.5,
        ),
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(18),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: HomeStyle.tintColor(
                      context,
                      const Color(0xFFEAF1FF),
                    ),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(icon, size: 17, color: accent ?? HomeStyle.blue),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final large =
                          constraints.maxWidth < 210 ||
                          MediaQuery.textScalerOf(context).scale(14) > 20;
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (large) ...[
                            title,
                            const SizedBox(height: 5),
                            badge,
                          ] else
                            Row(
                              children: [
                                Expanded(child: title),
                                const SizedBox(width: 8),
                                badge,
                              ],
                            ),
                          const SizedBox(height: 4),
                          Text(
                            summary,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: HomeStyle.text(
                              12,
                              color: HomeStyle.secondary(context),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

Future<bool> confirmKnowledge(
  BuildContext context,
  String title,
  String message, {
  String action = '确认',
}) async =>
    await showDialog<bool>(
      context: context,
      useRootNavigator: true,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text('取消'.tr(context)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(action.tr(context)),
          ),
        ],
      ),
    ) ??
    false;

void knowledgeFeedback(BuildContext context, String message) {
  if (context.mounted) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }
}
