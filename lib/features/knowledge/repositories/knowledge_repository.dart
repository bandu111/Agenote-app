import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import '../models/knowledge_models.dart';
import 'knowledge_file_access.dart';

abstract interface class KnowledgeStore {
  Future<String?> read();
  Future<void> write(String value);
}

/// App-private storage; a failed write restores the prior snapshot, not an empty library.
class LocalKnowledgeStore implements KnowledgeStore {
  LocalKnowledgeStore({this.directory});
  final Directory? directory;
  Future<File> _file() async {
    final dir = directory ?? await getApplicationSupportDirectory();
    await dir.create(recursive: true);
    return File('${dir.path}${Platform.pathSeparator}yanshu-knowledge-v1.json');
  }

  @override
  Future<String?> read() async {
    final file = await _file();
    final backup = File('${file.path}.backup');
    if (!await file.exists() && await backup.exists()) {
      await backup.rename(file.path);
    }
    final temp = File('${file.path}.tmp');
    if (await temp.exists()) await temp.delete();
    if (!await file.exists()) return null;
    return file.readAsString();
  }

  @override
  Future<void> write(String value) async {
    final file = await _file();
    final temp = File('${file.path}.tmp');
    final backup = File('${file.path}.backup');
    await temp.writeAsString(value, flush: true);
    var moved = false;
    try {
      if (await backup.exists()) await backup.delete();
      if (await file.exists()) {
        await file.rename(backup.path);
        moved = true;
      }
      await temp.rename(file.path);
    } catch (_) {
      if (moved && !await file.exists() && await backup.exists()) {
        await backup.rename(file.path);
      }
      rethrow;
    } finally {
      if (await temp.exists()) await temp.delete();
    }
    // Do not keep revoked/deleted content in a historical backup after success.
    if (await backup.exists()) await backup.delete();
  }
}

class MemoryKnowledgeStore implements KnowledgeStore {
  MemoryKnowledgeStore({this.value});
  String? value;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String value) async {
    this.value = value;
  }
}

class KnowledgeRepository {
  KnowledgeRepository(this.store, {this.seedExamples = false});
  final bool seedExamples;
  final KnowledgeStore store;
  Future<KnowledgeSnapshot> load() async {
    final raw = await store.read();
    if (raw == null) {
      final seed = seedExamples
          ? knowledgeExamples()
          : const KnowledgeSnapshot(
              folders: [KnowledgeFolder(id: 'inbox', name: '未归档')],
              projects: [KnowledgeProject(id: 'personal', name: '个人资料')],
              documents: [],
            );
      await save(seed);
      return seed;
    }
    final data = KnowledgeSnapshot.fromJson(
      Map<String, dynamic>.from(jsonDecode(raw)),
    );
    validateKnowledge(data);
    return data;
  }

  Future<void> save(KnowledgeSnapshot value) async {
    validateKnowledge(value);
    await store.write(jsonEncode(value.toJson()));
  }
}

void validateKnowledge(KnowledgeSnapshot data) {
  final folders = {for (final f in data.folders) f.id: f};
  if (folders.length != data.folders.length || !folders.containsKey('inbox')) {
    throw const FormatException('文件夹数据不完整');
  }
  final projects = data.projects.map((p) => p.id).toSet();
  if (projects.isEmpty || projects.length != data.projects.length) {
    throw const FormatException('项目资料不完整');
  }
  final documentIds = <String>{};
  for (final folder in data.folders) {
    final seen = <String>{folder.id};
    var parent = folder.parentId;
    while (parent != null) {
      if (!seen.add(parent) || !folders.containsKey(parent)) {
        throw const FormatException('文件夹层级无效');
      }
      parent = folders[parent]!.parentId;
    }
  }
  for (final d in data.documents) {
    if (!documentIds.add(d.id) ||
        !folders.containsKey(d.folderId) ||
        !projects.contains(d.projectId) ||
        d.versions.isEmpty ||
        !d.versions.any((v) => v.id == d.selectedVersionId) ||
        d.versions.where((v) => v.state == KnowledgeValidity.current).length >
            1 ||
        d.versions.map((v) => v.id).toSet().length != d.versions.length) {
      throw const FormatException('资料数据不完整，请保留本地数据后重试');
    }
    if (d.kind.isBinary || d.fileData != null || d.fileHash != null) {
      decodeKnowledgeFile(d.fileData ?? '', d.fileHash ?? '');
    }
    for (final v in d.versions) {
      if (v.sources.length > 32 ||
          v.sources.map((s) => s.key).toSet().length != v.sources.length ||
          v.sources.any(
            (s) =>
                s.targetId.isEmpty ||
                s.versionId.isEmpty ||
                !RegExp(r'^[a-f0-9]{64}$').hasMatch(s.hash) ||
                (s.kind == KnowledgeSourceKind.document && s.targetId == d.id),
          )) {
        throw const FormatException('来源关联数据无效，请保留本地数据后重试');
      }
    }
  }
}

KnowledgeSnapshot knowledgeExamples() {
  final now = DateTime.now();
  KnowledgeDocument example(
    String id,
    String title,
    String content,
    String folder, {
    KnowledgeValidity state = KnowledgeValidity.current,
    bool archived = false,
  }) {
    final version = KnowledgeVersion(
      id: '$id-v1',
      number: 1,
      title: title,
      content: content,
      hash: knowledgeHash(content),
      createdAt: now.subtract(const Duration(days: 1)),
      state: state,
      reason: state == KnowledgeValidity.conflicted
          ? '演示：桌面端范围与一期交付约定需并列核对。'
          : '内置演示资料',
    );
    return KnowledgeDocument(
      id: id,
      folderId: folder,
      projectId: 'delivery',
      kind: KnowledgeKind.markdown,
      source: '内置演示资料',
      createdAt: version.createdAt,
      versions: [version],
      selectedVersionId: version.id,
      allowed: true,
      demo: true,
      archived: archived,
      tags: ['演示', folder == 'scope' ? '交付范围' : '会议记录'],
    );
  }

  return KnowledgeSnapshot(
    folders: const [
      KnowledgeFolder(id: 'scope', name: '项目合同与范围'),
      KnowledgeFolder(id: 'meetings', name: '会议与沟通'),
      KnowledgeFolder(id: 'technical', name: '技术资料'),
      KnowledgeFolder(id: 'inbox', name: '未归档'),
    ],
    projects: const [
      KnowledgeProject(id: 'delivery', name: '星澜客户管理 App', allowed: true),
      KnowledgeProject(id: 'desktop', name: '桌面端范围评估'),
      KnowledgeProject(id: 'personal', name: '个人资料'),
    ],
    documents: [
      example(
        'demo-scope',
        '一期交付范围与验收约定',
        '# 一期交付范围\n\n本资料为内置演示，不是真实合同。\n\n'
            '一期交付包含 Android / iOS 双端测试，并部署至客户预发环境。\n\n'
            '## 验收条件\n\n满足双方已经确认的交付指标；未确认的新增范围单独评估。\n\n'
            '## 交期约束\n\n演示交付周期为 30 天。桌面端需求未自动纳入一期范围。',
        'scope',
      ),
      example(
        'demo-guide',
        '资料引用与版本核查清单',
        '# 引用前核查\n\n核对项目、来源、资料版本、原文位置和授权。\n\n'
            '- 撤回的资料不再用于检索。\n- 冲突资料保持待核对，不按更新时间自动覆盖。\n- 声称完成不等于已核实。',
        'scope',
        archived: true,
      ),
      example(
        'demo-meeting',
        '桌面端新增范围讨论纪要',
        '# 桌面端范围讨论\n\n这是演示会议纪要。\n\n'
            '讨论提出：是否把 Windows 桌面端加入当前交付周期？\n\n'
            '该说法尚未形成双方确认的范围变更，与原一期交付范围需要并列核对。',
        'meetings',
        state: KnowledgeValidity.conflicted,
      ),
    ],
  );
}
