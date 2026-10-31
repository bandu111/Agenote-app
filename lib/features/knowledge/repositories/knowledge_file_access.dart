import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import '../models/knowledge_models.dart';
import 'knowledge_importer.dart';

Uint8List decodeKnowledgeFile(String data, String hash) {
  if (data.length > ((maxKnowledgeFileBytes + 2) ~/ 3) * 4) {
    throw const FormatException('原文件超过 20 MB');
  }
  final bytes = base64Decode(data);
  if (bytes.isEmpty ||
      bytes.length > maxKnowledgeFileBytes ||
      sha256.convert(bytes).toString() != hash) {
    throw const FormatException('原文件校验失败，请重新导入');
  }
  return bytes;
}

/// Exports only a checked app-owned copy. Never writes back to the user's source file.
class KnowledgeFileAccess {
  const KnowledgeFileAccess({this.directory});
  final Directory? directory;

  Future<Directory> _documentFolder(String id) async {
    final root = directory ?? await getTemporaryDirectory();
    return Directory(
      '${root.path}${Platform.pathSeparator}knowledge-open'
      '${Platform.pathSeparator}${knowledgeHash(id)}',
    );
  }

  Future<File> export(KnowledgeDocument document) async {
    final bytes = decodeKnowledgeFile(
      document.fileData ?? '',
      document.fileHash ?? '',
    );
    if (!knowledgeFileExtensions.contains(document.extension)) {
      throw const FormatException('文件类型不支持打开');
    }
    final folder = await _documentFolder(document.id);
    await folder.create(recursive: true);
    // Do not use untrusted filename/path segments from imported metadata.
    final file = File(
      '${folder.path}${Platform.pathSeparator}original.${document.extension}',
    );
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }

  Future<String?> open(KnowledgeDocument document) async {
    try {
      final file = await export(document);
      final result = await OpenFilex.open(
        file.path,
        type: switch (document.extension) {
          'odt' => 'application/vnd.oasis.opendocument.text',
          'ods' => 'application/vnd.oasis.opendocument.spreadsheet',
          _ => null,
        },
      );
      return switch (result.type) {
        ResultType.done => null,
        ResultType.noAppToOpen => '手机上暂未安装可打开此格式的阅读应用',
        ResultType.permissionDenied => '未获得打开原文件的权限，请重试',
        ResultType.fileNotFound => '原文件副本不存在，请重新导入',
        _ => '原文件暂时无法打开，请重试',
      };
    } on FormatException catch (e) {
      return e.message;
    } catch (_) {
      return '原文件打开失败，请重试';
    }
  }

  Future<void> purge(String id) async {
    final folder = await _documentFolder(id);
    if (await folder.exists()) await folder.delete(recursive: true);
  }
}
