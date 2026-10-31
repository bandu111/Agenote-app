import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:crypto/crypto.dart';
import '../models/knowledge_models.dart';

const maxKnowledgeBytes = 2 * 1024 * 1024;
const maxKnowledgeFileBytes = 20 * 1024 * 1024;
const knowledgeFileExtensions = [
  'md',
  'txt',
  'csv',
  'tsv',
  'pdf',
  'doc',
  'docx',
  'xls',
  'xlsx',
  'ppt',
  'pptx',
  'rtf',
  'odt',
  'ods',
];

class KnowledgeImport {
  const KnowledgeImport(
    this.filename,
    this.content,
    this.kind, {
    this.fileData,
    this.fileHash,
  });
  final String filename, content;
  final KnowledgeKind kind;
  final String? fileData, fileHash;
}

abstract interface class KnowledgeImporter {
  Future<KnowledgeImport?> pick();
}

class DeviceKnowledgeImporter implements KnowledgeImporter {
  @override
  Future<KnowledgeImport?> pick() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: knowledgeFileExtensions,
      allowMultiple: false,
      withData: false,
    );
    if (result == null || result.files.isEmpty) return null;
    try {
      final picked = result.files.single;
      if (picked.size > maxKnowledgeFileBytes) {
        throw const FormatException('单份文件请控制在 20 MB 以内');
      }
      Uint8List bytes;
      if (picked.path != null) {
        final file = File(picked.path!);
        if (await file.length() > maxKnowledgeFileBytes) {
          throw const FormatException('单份文件请控制在 20 MB 以内');
        }
        bytes = await file.readAsBytes();
      } else if (picked.bytes != null) {
        bytes = picked.bytes!;
      } else {
        throw const FormatException('无法读取所选文件，请重选');
      }
      return decodeKnowledgeImport(picked.name, bytes);
    } finally {
      if (Platform.isAndroid || Platform.isIOS) {
        try {
          await FilePicker.platform.clearTemporaryFiles();
        } catch (_) {
          /* OS picker cache cleanup is best-effort, not file deletion. */
        }
      }
    }
  }
}

KnowledgeImport decodeKnowledgeImport(String name, List<int> bytes) {
  final ext = name.toLowerCase().split('.').last;
  if (!knowledgeFileExtensions.contains(ext)) {
    throw const FormatException('暂不支持这种文件格式');
  }
  if (bytes.isEmpty || bytes.length > maxKnowledgeFileBytes) {
    throw const FormatException('文件为空或超过 20 MB');
  }
  if (!['md', 'txt', 'csv', 'tsv'].contains(ext)) {
    final kind = switch (ext) {
      'pdf' => KnowledgeKind.pdf,
      'doc' || 'docx' => KnowledgeKind.word,
      'xls' || 'xlsx' || 'ods' => KnowledgeKind.spreadsheet,
      'ppt' || 'pptx' => KnowledgeKind.presentation,
      _ => KnowledgeKind.office,
    };
    if (!_validFileSignature(ext, bytes)) {
      throw const FormatException('文件内容与扩展名不符，请检查原文件');
    }
    return KnowledgeImport(
      name,
      '',
      kind,
      fileData: base64Encode(bytes),
      fileHash: sha256.convert(bytes).toString(),
    );
  }
  if (bytes.length > maxKnowledgeBytes) {
    throw const FormatException('文本资料请控制在 2 MB 以内');
  }
  String text;
  try {
    text = utf8
        .decode(bytes, allowMalformed: false)
        .replaceFirst(RegExp(r'^\uFEFF'), '');
  } on FormatException {
    throw const FormatException('文件不是 UTF-8 文本，请转换编码后重试');
  }
  if (text.trim().isEmpty || text.contains('\u0000')) {
    throw const FormatException('文件为空或不是可读文本');
  }
  return KnowledgeImport(
    name,
    text,
    ext == 'md' ? KnowledgeKind.markdown : KnowledgeKind.text,
  );
}

bool _validFileSignature(String ext, List<int> bytes) {
  bool starts(List<int> prefix) =>
      bytes.length >= prefix.length &&
      List.generate(
        prefix.length,
        (i) => bytes[i] == prefix[i],
      ).every((v) => v);
  return switch (ext) {
    'pdf' => starts([0x25, 0x50, 0x44, 0x46, 0x2d]),
    'doc' ||
    'xls' ||
    'ppt' => starts([0xd0, 0xcf, 0x11, 0xe0, 0xa1, 0xb1, 0x1a, 0xe1]),
    'docx' ||
    'xlsx' ||
    'pptx' ||
    'odt' ||
    'ods' => starts([0x50, 0x4b, 0x03, 0x04]),
    'rtf' => starts([123, 92, 114, 116, 102]),
    _ => false,
  };
}
