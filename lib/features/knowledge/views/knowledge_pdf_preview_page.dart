import '../../../shared/widgets/content_skeleton.dart';
import '../../../app/l10n/app_strings.dart';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:printing/printing.dart';
import 'package:provider/provider.dart';
import '../viewmodels/knowledge_view_model.dart';
import '../repositories/dio_knowledge_repository.dart';
import '../../home/views/home_style.dart';
import '../models/knowledge_models.dart';
import '../repositories/knowledge_pdf_document.dart';

typedef _PreviewDocument = ({Uint8List bytes, Size? firstPageSize});

double knowledgePreviewDpi(
  Size pageSize,
  double screenWidth,
  double pixelRatio,
) {
  const maxPixels = 2000000.0;
  final targetWidth =
      math.max(1.0, math.min(screenWidth, 1000.0) - 32.0) * pixelRatio;
  final screenScale = targetWidth / pageSize.width;
  // 面积随比例平方增长；用首页约束像素预算，整份文档复用同一 DPI。
  final budgetScale = math.sqrt(maxPixels / (pageSize.width * pageSize.height));
  return 72.0 * math.min(screenScale, budgetScale);
}

class KnowledgePdfPreviewPage extends StatefulWidget {
  const KnowledgePdfPreviewPage({
    super.key,
    required this.document,
    required this.version,
  });
  final KnowledgeDocument document;
  final KnowledgeVersion version;
  @override
  State<KnowledgePdfPreviewPage> createState() =>
      _KnowledgePdfPreviewPageState();
}

class _KnowledgePdfPreviewPageState extends State<KnowledgePdfPreviewPage> {
  static const _pdfInfo = MethodChannel('yanshu/pdf_info');
  late Future<_PreviewDocument> _document;
  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    final repository = widget.document.kind.isBinary
        ? context.read<KnowledgeViewModel>().repository
        : null;
    final bytes = repository is DioKnowledgeRepository
        ? repository.preview(widget.document, widget.version)
        : KnowledgePdfDocument.load(widget.document, widget.version);
    // 保存本次打开的 Future，页面重建不会重复读取首页。
    _document = bytes.then(_prepareDocument);
  }

  Future<_PreviewDocument> _prepareDocument(Uint8List bytes) async {
    if (!Platform.isAndroid) {
      return (bytes: bytes, firstPageSize: null);
    }

    final directory = await Directory.systemTemp.createTemp('yanshu-pdf-');
    try {
      final file = File('${directory.path}/preview.pdf');
      await file.writeAsBytes(bytes);
      final dimensions = await _pdfInfo.invokeListMethod<int>('firstPageSize', {
        'path': file.path,
      });
      if (dimensions == null ||
          dimensions.length != 2 ||
          dimensions.any((value) => value <= 0)) {
        throw const FormatException('PDF 首页尺寸无效');
      }
      return (
        bytes: bytes,
        firstPageSize: Size(dimensions[0].toDouble(), dimensions[1].toDouble()),
      );
    } finally {
      await directory.delete(recursive: true);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    key: const ValueKey('knowledge-pdf-preview'),
    backgroundColor: HomeStyle.surface(context),
    appBar: AppBar(
      backgroundColor: HomeStyle.surface(context),
      leading: BackButton(onPressed: () => Navigator.of(context).pop()),
      title: Text(
        widget.version.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: HomeStyle.text(16, bold: true),
      ),
    ),
    body: SafeArea(
      top: false,
      child: FutureBuilder<_PreviewDocument>(
        future: _document,
        builder: (context, snapshot) {
          if (snapshot.hasError) return _error(context);
          if (!snapshot.hasData) {
            return const ContentSkeleton(
              layout: SkeletonLayout.document,
              rows: 1,
              label: '正在加载文档预览',
            );
          }
          final document = snapshot.data!;
          return LayoutBuilder(
            builder: (context, constraints) => PdfPreview(
              build: (_) async => document.bytes,
              dpi: document.firstPageSize == null
                  ? null
                  : knowledgePreviewDpi(
                      document.firstPageSize!,
                      constraints.maxWidth,
                      MediaQuery.devicePixelRatioOf(context),
                    ),
              pdfFileName: '${widget.version.title}.pdf',
              allowPrinting: false,
              allowSharing: false,
              useActions: false,
              canChangePageFormat: false,
              canChangeOrientation: false,
              canDebug: false,
              dynamicLayout: false,
              maxPageWidth: 1000,
              scrollViewDecoration: BoxDecoration(
                color: HomeStyle.canvas(context),
              ),
              loadingWidget: const ContentSkeleton(
                layout: SkeletonLayout.document,
                rows: 1,
                label: '正在渲染文档',
              ),
              onError: (context, _) => _error(context),
            ),
          );
        },
      ),
    ),
  );

  Widget _error(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.description_outlined,
            color: HomeStyle.secondary(context),
            size: 36,
          ),
          const SizedBox(height: 12),
          Text(
            '文档预览失败，请检查原文件或重试。',
            textAlign: TextAlign.center,
            style: HomeStyle.text(14),
          ),
          TextButton(
            onPressed: () => setState(_load),
            child: Text('重试'.tr(context)),
          ),
        ],
      ),
    ),
  );
}
