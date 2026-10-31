import '../../../core/network/api_client.dart';
import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import '../../../core/network/api_config.dart';
import '../models/knowledge_models.dart';
import 'knowledge_repository.dart';

/// 正式资料按认证账户同步，不将旧设备上的演示资料自动归给新账户。
class DioKnowledgeRepository extends KnowledgeRepository {
  DioKnowledgeRepository(this.client) : super(MemoryKnowledgeStore());
  final ApiClient client;
  String? get accountId => client.accountId?.call();
  String? _owner;
  Future<void> renameDocument(KnowledgeDocument document, String title) async {
    final owner = accountId;
    if (owner == null) throw const ApiFailure('请先登录');
    await client.post('knowledge/documents/${Uri.encodeComponent(document.id)}/rename',
      authenticated: true, accountId: owner,
      data: {'title': title, 'versionId': document.selected.id, 'expectedTitle': document.selected.title});
    if (owner != accountId) throw const ApiFailure('账户已切换');
  }
  Future<Uint8List> preview(
    KnowledgeDocument document,
    KnowledgeVersion version,
  ) async {
    final owner = accountId;
    if (owner == null || document.ownerUserId != owner) {
      throw const ApiFailure('请先登录资料所属账户');
    }
    final response = await client.post(
      'knowledge/preview',
      authenticated: true,
      accountId: owner,
      receiveTimeout: const Duration(seconds: 100),
      data: {
        'documentId': document.id,
        'versionId': version.id,
        'hash': version.hash,
        'fileHash': document.fileHash,
      },
    );
    if (owner != accountId) throw const ApiFailure('账户已切换');
    final data = response['data'] as Map;
    if (data['documentId'] != document.id ||
        data['versionId'] != version.id ||
        data['sourceHash'] != document.fileHash ||
        (data['pdfData'] as String).length > 42 * 1024 * 1024) {
      throw const ApiFailure('预览来源不一致');
    }
    final bytes = base64Decode(data['pdfData']);
    if (bytes.length > 30 * 1024 * 1024 ||
        sha256.convert(bytes).toString() != data['pdfHash'] ||
        bytes.length < 5 ||
        ascii.decode(bytes.sublist(0, 5), allowInvalid: true) != '%PDF-') {
      throw const ApiFailure('预览文件校验失败');
    }
    return bytes;
  }

  int? _revision;
  Map<String, String> _indexStates = {};
  bool get hasPendingIndex =>
      _owner == accountId && _indexStates.containsValue('queued');
  Future<bool> refreshIndexStatus() async {
    final owner = accountId;
    if (owner == null || _owner != owner) return false;
    final response = await client.get(
      'knowledge/index-status',
      authenticated: true,
      accountId: owner,
    );
    if (owner != accountId || _owner != owner) return false;
    final states = {
      for (final s in response['data'] as List)
        '${s['documentId']}:${s['versionId']}': s['status'] as String,
    };
    final changed =
        states.length != _indexStates.length ||
        states.entries.any((e) => _indexStates[e.key] != e.value);
    _indexStates = states;
    return changed;
  }

  int? get revision => _owner == accountId ? _revision : null;
  String? indexStatus(String documentId, String versionId) =>
      _owner == accountId ? _indexStates['$documentId:$versionId'] : null;

  @override
  Future<KnowledgeSnapshot> load() async {
    final owner = accountId;
    if (owner == null) {
      _owner = null;
      _revision = null;
      return const KnowledgeSnapshot(folders: [], projects: [], documents: []);
    }
    final response = await client.get(
      'knowledge',
      authenticated: true,
      accountId: owner,
    );
    if (accountId != owner) throw const ApiFailure('账户已切换');
    final data = Map<String, dynamic>.from(response['data']);
    final snapshot = KnowledgeSnapshot.fromJson(
      Map<String, dynamic>.from(data['snapshot']),
    );
    validateKnowledge(snapshot);
    _owner = owner;
    _revision = data['revision'] as int;
    _indexStates = {
      for (final s in data['indexStates'] as List? ?? [])
        '${s['documentId']}:${s['versionId']}': s['status'] as String,
    };
    return snapshot;
  }

  Future<List<Map<String, dynamic>>> search(
    String query, {
    String? projectId,
  }) async {
    final owner = accountId;
    if (owner == null) return [];
    final response = await client.post(
      'knowledge/search',
      authenticated: true,
      accountId: owner,
      data: {
        'query': query.length > 4000 ? query.substring(0, 4000) : query,
        'limit': 6,
        'projectId': ?projectId,
      },
    );
    if (owner != accountId) return [];
    return [
      for (final h in response['data'] as List) Map<String, dynamic>.from(h),
    ];
  }

  Future<bool> resolve(Map<String, dynamic> hit) async {
    final owner = accountId;
    if (owner == null) return false;
    try {
      await client.post(
        'knowledge/resolve',
        authenticated: true,
        accountId: owner,
        data: {
          for (final k in ['nodeId', 'documentId', 'versionId', 'hash'])
            k: hit[k],
        },
      );
      return owner == accountId;
    } on ApiFailure catch (error) {
      if (owner != accountId || [403, 404, 409, 410].contains(error.status)) {
        return false;
      }
      rethrow;
    }
  }

  @override
  Future<void> save(KnowledgeSnapshot value) async {
    final owner = accountId;
    if (owner == null || _owner != owner || _revision == null) {
      throw const ApiFailure('请先读取当前账户的资料');
    }
    validateKnowledge(value);
    final response = await client.post(
      'knowledge/sync',
      authenticated: true,
      accountId: owner,
      receiveTimeout: const Duration(seconds: 90),
      data: {'revision': _revision, 'snapshot': value.toJson()},
    );
    if (accountId != owner) throw const ApiFailure('账户已切换');
    _revision = response['data']['revision'] as int;
  }
}
