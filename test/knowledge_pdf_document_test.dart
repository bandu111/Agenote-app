import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:yanshu/features/knowledge/models/knowledge_models.dart';
import 'package:yanshu/features/knowledge/repositories/knowledge_importer.dart';
import 'package:yanshu/features/knowledge/repositories/knowledge_pdf_document.dart';
import 'package:yanshu/features/knowledge/repositories/knowledge_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'Chinese markdown generates a real multi-page PDF with an embedded local font',
    () async {
      final font = await File(
        'assets/fonts/NotoSansSC-Regular.ttf',
      ).readAsBytes();
      final bytes = await KnowledgePdfDocument.compile(
        title: '项目交付与验收',
        content:
            '# 会议原文\n${List.filled(100, 'Android / iOS 双端交付，核对项目范围与验收条件。').join('\n')}\n'
            '${List.filled(1800, '长行').join()}',
        fontData: ByteData.sublistView(font),
      );
      final pdf = latin1.decode(bytes);
      expect(pdf.startsWith('%PDF-'), isTrue);
      expect(pdf.trimRight().endsWith('%%EOF'), isTrue);
      expect(RegExp(r'/Type\s*/Page\b').allMatches(pdf).length, greaterThan(1));
      expect(RegExp(r'/Subtype\s*/Type0').hasMatch(pdf), isTrue);
      final imported = decodeKnowledgeImport('原文.pdf', bytes);
      final json = knowledgeExamples().documents.first.toJson();
      final document = KnowledgeDocument.fromJson({
        ...json,
        'kind': 'pdf',
        'filename': imported.filename,
        'fileData': imported.fileData,
        'fileHash': imported.fileHash,
      });
      expect(
        await KnowledgePdfDocument.load(document, document.selected),
        bytes,
      );
    },
  );

  test(
    'preview rejects a text version whose content no longer matches its hash',
    () async {
      final d = knowledgeExamples().documents.first;
      final v = KnowledgeVersion.fromJson({
        ...d.selected.toJson(),
        'hash': 'invalid',
      });
      await expectLater(KnowledgePdfDocument.load(d, v), throwsFormatException);
    },
  );
}
