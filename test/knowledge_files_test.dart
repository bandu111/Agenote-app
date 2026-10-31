import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:yanshu/features/knowledge/models/knowledge_models.dart';
import 'package:yanshu/features/knowledge/repositories/knowledge_file_access.dart';
import 'package:yanshu/features/knowledge/repositories/knowledge_importer.dart';
import 'package:yanshu/features/knowledge/repositories/knowledge_repository.dart';
import 'package:yanshu/features/knowledge/repositories/knowledge_source_checks.dart';
import 'knowledge_view_model_test.dart';

void main() {
  test(
    'format admission preserves binary original bytes and never treats them as text',
    () {
      final signatures = {
        'pdf': utf8.encode('%PDF-1.4\n%%EOF'),
        for (final ext in ['doc', 'xls', 'ppt'])
          ext: [0xd0, 0xcf, 0x11, 0xe0, 0xa1, 0xb1, 0x1a, 0xe1],
        for (final ext in ['docx', 'xlsx', 'pptx', 'odt', 'ods'])
          ext: [0x50, 0x4b, 0x03, 0x04],
        'rtf': utf8.encode(r'{\rtf1 text}'),
      };
      for (final item in signatures.entries) {
        final file = decodeKnowledgeImport('report.${item.key}', item.value);
        expect(file.kind.isBinary, isTrue);
        expect(file.content, isEmpty);
        expect(decodeKnowledgeFile(file.fileData!, file.fileHash!), item.value);
      }
      for (final ext in ['pdf', 'doc', 'xlsx', 'exe']) {
        expect(
          () =>
              decodeKnowledgeImport('invalid.$ext', utf8.encode('plain text')),
          throwsFormatException,
        );
      }
      expect(
        decodeKnowledgeImport(
          'table.csv',
          utf8.encode('日期,进度\n今天,68%'),
        ).content,
        contains('68%'),
      );
    },
  );

  test(
    'binary files persist with no extracted body and deduplicate by file bytes',
    () async {
      final store = MemoryKnowledgeStore(), vm = await knowledgeModel();
      addTearDown(vm.dispose);
      final file = decodeKnowledgeImport(
        'original.pdf',
        utf8.encode('%PDF-1.4\n%%EOF'),
      );
      Future<String?> save(KnowledgeImport f) => vm.addDocument(
        title: f.filename,
        content: f.content,
        folderId: 'inbox',
        projectId: 'delivery',
        kind: f.kind,
        allowed: true,
        filename: f.filename,
        fileData: f.fileData,
        fileHash: f.fileHash,
      );
      final id = await save(file);
      expect(id, isNotNull);
      expect(await save(file), isNull);
      final other = decodeKnowledgeImport(
        'other.pdf',
        utf8.encode('%PDF-1.5\n%%EOF'),
      );
      expect(await save(other), isNotNull);
      expect(vm.retrievable(vm.document(id!)!), isFalse);
      await KnowledgeRepository(store, seedExamples: true).save(vm.data);
      final fresh = await knowledgeModel(store: store);
      addTearDown(fresh.dispose);
      expect(fresh.document(id)!.fileHash, file.fileHash);
      expect(
        () => decodeKnowledgeFile(file.fileData!, 'bad hash'),
        throwsFormatException,
      );
      await fresh.delete(id);
      expect(store.value, isNot(contains(file.fileData!)));
    },
  );

  test(
    'opening exports checked bytes inside a hashed app cache folder and purges its copies',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'yanshu-original-test-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final vm = await knowledgeModel();
      addTearDown(vm.dispose);
      final file = decodeKnowledgeImport(
        'original.pdf',
        utf8.encode('%PDF-1.4\n%%EOF'),
      );
      final id = await vm.addDocument(
        title: 'Original',
        content: '',
        folderId: 'inbox',
        projectId: 'delivery',
        kind: file.kind,
        allowed: false,
        filename: file.filename,
        fileData: file.fileData,
        fileHash: file.fileHash,
      );
      final doc = KnowledgeDocument.fromJson({
        ...vm.document(id!)!.toJson(),
        'id': '../../outside',
        'filename': '../../report.pdf',
      });
      final access = KnowledgeFileAccess(directory: directory);
      final exported = await access.export(doc);
      expect(exported.path.startsWith(directory.path), isTrue);
      expect(exported.path, contains(knowledgeHash(doc.id)));
      expect(await exported.readAsBytes(), base64Decode(file.fileData!));
      await access.purge(doc.id);
      expect(await exported.exists(), isFalse);
      expect(await directory.exists(), isTrue);
    },
  );

  test(
    'match percentages are bounded local text similarity and omit scores without text',
    () {
      expect(
        sourceMatchPercent('Android / iOS 双端交付', 'Android / iOS 双端交付'),
        100,
      );
      expect(sourceMatchPercent('abc def', 'xyz uvw'), 0);
      final score = sourceMatchPercent('交付范围与验收条件', '交付范围');
      expect(score, greaterThan(0));
      expect(score, lessThan(100));
      expect(sourceMatchPercent('', 'document'), isNull);
      expect(sourceMatchPercent('document', ''), isNull);
    },
  );
}
