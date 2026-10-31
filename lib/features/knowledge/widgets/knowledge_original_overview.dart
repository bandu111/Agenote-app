import '../../../app/l10n/app_strings.dart';
import 'package:flutter/material.dart';
import '../../home/views/home_style.dart';
import '../models/knowledge_models.dart';

IconData knowledgeFileIcon(KnowledgeKind kind) => switch (kind) {
  KnowledgeKind.audio => Icons.mic_none_outlined,
  KnowledgeKind.pdf => Icons.picture_as_pdf_outlined,
  KnowledgeKind.spreadsheet => Icons.table_chart_outlined,
  KnowledgeKind.presentation => Icons.slideshow_outlined,
  _ => Icons.description_outlined,
};

class KnowledgeOriginalOverview extends StatelessWidget {
  const KnowledgeOriginalOverview({
    super.key,
    required this.document,
    required this.version,
    required this.onOpen,
    this.opening = false,
  });
  final KnowledgeDocument document;
  final KnowledgeVersion version;
  final VoidCallback onOpen;
  final bool opening;

  @override
  Widget build(BuildContext context) {
    final summary = knowledgePreview(version.content);
    final fileRow = Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: HomeStyle.tintColor(context, const Color(0xFFF1F5FD)),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(
            knowledgeFileIcon(document.kind),
            size: 20,
            color: HomeStyle.blue,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                document.filename ?? version.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: HomeStyle.text(14, bold: true),
              ),
              const SizedBox(height: 4),
              Text(
                document.kind == KnowledgeKind.audio
                    ? '录音原文 · 音频通过上方播放器播放'
                    : '${document.displayType} · ${document.kind.isBinary ? '原文件已保存' : 'PDF 文档预览'}',
                style: HomeStyle.text(11, color: HomeStyle.secondary(context)),
              ),
            ],
          ),
        ),
      ],
    );
    final openButton = document.kind == KnowledgeKind.audio
        ? const SizedBox.shrink()
        : TextButton.icon(
            key: const ValueKey('knowledge-open-original'),
            onPressed: opening ? null : onOpen,
            icon: opening
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.visibility_outlined, size: 15),
            label: Text(
              opening ? '正在打开'.tr(context) : '打开文档'.tr(context),
              style: HomeStyle.text(11, bold: true, color: HomeStyle.blue),
            ),
            style: TextButton.styleFrom(
              backgroundColor: HomeStyle.tintColor(
                context,
                const Color(0xFFF1F5FD),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
          );
    return Container(
      key: const ValueKey('knowledge-original-overview'),
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: HomeStyle.surface(context),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: HomeStyle.secondary(context).withValues(alpha: .09),
          width: 1.5,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.article_outlined,
                size: 16,
                color: HomeStyle.secondary(context),
              ),
              const SizedBox(width: 6),
              Text(
                '原文概览'.tr(context),
                style: HomeStyle.text(
                  13,
                  bold: true,
                  color: HomeStyle.secondary(context),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: HomeStyle.secondary(context).withValues(alpha: .12),
                width: 1.2,
              ),
            ),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final narrow =
                    constraints.maxWidth < 260 ||
                    MediaQuery.textScalerOf(context).scale(14) > 20;
                return narrow
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          fileRow,
                          const SizedBox(height: 10),
                          Align(
                            alignment: Alignment.centerRight,
                            child: openButton,
                          ),
                        ],
                      )
                    : Row(
                        children: [
                          Expanded(child: fileRow),
                          const SizedBox(width: 12),
                          openButton,
                        ],
                      );
              },
            ),
          ),
          const SizedBox(height: 20),
          Divider(
            height: 1,
            thickness: 1.2,
            color: HomeStyle.secondary(context).withValues(alpha: .09),
          ),
          const SizedBox(height: 16),
          Text(
            summary.isEmpty
                ? (document.kind.isBinary ? '暂无文本摘要，点击「打开文档」查看原文件。' : '暂无原文内容。')
                : summary,
            key: const ValueKey('knowledge-original-summary'),
            maxLines: 5,
            overflow: TextOverflow.ellipsis,
            style: HomeStyle.text(14, color: HomeStyle.secondary(context)),
          ),
        ],
      ),
    );
  }
}
