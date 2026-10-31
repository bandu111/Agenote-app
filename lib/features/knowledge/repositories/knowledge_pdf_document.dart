import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import '../models/knowledge_models.dart';
import 'knowledge_file_access.dart';

/// MD/TXT are laid out as a real, offline PDF; imported PDFs keep their original bytes.
class KnowledgePdfDocument {
  static ByteData? _fontData;
  static Future<ByteData> prepareFont() async => _fontData ??= await rootBundle
      .load('assets/fonts/NotoSansSC-Regular.ttf');

  static Future<Uint8List> load(
    KnowledgeDocument document,
    KnowledgeVersion version,
  ) async {
    if (document.kind == KnowledgeKind.pdf) {
      return decodeKnowledgeFile(
        document.fileData ?? '',
        document.fileHash ?? '',
      );
    }
    if (document.kind.isBinary) throw const FormatException('请使用原文件阅读应用打开此格式');
    if (!version.integrityOk) throw const FormatException('正文校验失败，请重新核对来源');
    final fontData = await prepareFont();
    return compile(
      title: version.title,
      content: version.content,
      fontData: fontData,
    );
  }

  static Future<Uint8List> compile({
    required String title,
    required String content,
    required ByteData fontData,
  }) => compute(_compileKnowledgePdf, (title, content, fontData));

  static Future<Uint8List> _compile({
    required String title,
    required String content,
    required ByteData fontData,
  }) async {
    final font = pw.Font.ttf(fontData);
    final pdf = pw.Document(title: title, creator: '言枢 YanShu');
    final blocks = <pw.Widget>[
      pw.Text(
        title,
        style: pw.TextStyle(
          fontSize: 20,
          fontWeight: pw.FontWeight.bold,
          color: PdfColor.fromHex('#101846'),
        ),
      ),
      pw.SizedBox(height: 10),
      pw.Divider(color: PdfColor.fromHex('#EAECEF')),
      pw.SizedBox(height: 12),
    ];
    final text = content.replaceFirst(
      RegExp(r'^---\s*\r?\n[\s\S]*?\r?\n---\s*\r?\n'),
      '',
    );
    for (final line in text.split('\n')) {
      final value = line.trimRight();
      if (value.trim().isEmpty) {
        blocks.add(pw.SizedBox(height: 6));
        continue;
      }
      final heading = RegExp(r'^(#{1,6})\s+(.+)$').firstMatch(value);
      final display = heading?.group(2) ?? value;
      // Bound each text block's height so very long lines wrap across PDF pages safely.
      for (var offset = 0; offset < display.length;) {
        var end = (offset + 600).clamp(0, display.length);
        if (end < display.length &&
            display.codeUnitAt(end - 1) >= 0xd800 &&
            display.codeUnitAt(end - 1) <= 0xdbff) {
          end--;
        }
        blocks.add(
          pw.Padding(
            padding: const pw.EdgeInsets.only(bottom: 5),
            child: pw.Text(
              display.substring(offset, end),
              style: pw.TextStyle(
                fontSize: heading == null
                    ? 10.5
                    : heading.group(1)!.length == 1
                    ? 15
                    : 12,
                fontWeight: heading == null
                    ? pw.FontWeight.normal
                    : pw.FontWeight.bold,
                color: PdfColor.fromHex(
                  heading == null ? '#4A5568' : '#101846',
                ),
                lineSpacing: 1.4,
              ),
            ),
          ),
        );
        offset = end;
      }
    }
    pdf.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(24),
        maxPages: 500,
        theme: pw.ThemeData.withFont(base: font, bold: font),
        build: (_) => blocks,
      ),
    );
    return pdf.save();
  }
}

Future<Uint8List> _compileKnowledgePdf((String, String, ByteData) input) =>
    KnowledgePdfDocument._compile(
      title: input.$1,
      content: input.$2,
      fontData: input.$3,
    );
