import 'package:flutter_test/flutter_test.dart';
import 'package:yanshu/core/network/api_client.dart';
import 'package:yanshu/core/network/api_config.dart';
import 'package:yanshu/features/knowledge/models/knowledge_models.dart';
import 'package:yanshu/features/knowledge/repositories/dio_knowledge_repository.dart';
import 'package:yanshu/features/knowledge/repositories/knowledge_repository.dart';
import 'package:yanshu/features/knowledge/viewmodels/knowledge_view_model.dart';

class RemoteSearchRepository extends DioKnowledgeRepository {
  RemoteSearchRepository(this.snapshot)
    : super(ApiClient(baseUrl: 'https://invalid.example/api/v1/'));
  KnowledgeSnapshot snapshot;
  bool fail = false;
  bool empty = false;
  int calls = 0;
  String? project;
  @override
  String get accountId => 'owner';
  @override
  Future<KnowledgeSnapshot> load() async => snapshot;
  @override
  Future<List<Map<String, dynamic>>> search(
    String query, {
    String? projectId,
  }) async {
    calls++;
    project = projectId;
    if (fail) throw StateError('network');
    if (empty) return [];
    final d = snapshot.documents.first;
    return [
      {
        'documentId': d.id,
        'versionId': d.selected.id,
        'hash': d.selected.hash,
        'nodeId': 'authorized-node',
        'text': d.selected.content,
        'source': d.source,
      },
    ];
  }

  @override
  Future<bool> resolve(Map<String, dynamic> hit) async => true;
}

class ConcurrentDeleteRepository extends RemoteSearchRepository {
  ConcurrentDeleteRepository(super.snapshot);
  int writes = 0;
  bool conflict = false, keepDeleted = false, modifyTarget = false;
  @override
  Future<void> save(KnowledgeSnapshot value) async {
    writes++;
    if (conflict && writes == 1) {
      final docs = [...snapshot.documents];
      if (modifyTarget) {
        docs[0] = docs[0].copyWith(archived: !docs[0].archived);
      } else {
        docs.add(
          KnowledgeDocument.fromJson({
            ...docs.last.toJson(),
            'id': 'concurrent-new-document',
          }),
        );
      }
      snapshot = snapshot.copyWith(documents: docs);
      throw const ApiFailure(
        '资料已更新',
        status: 409,
        code: 'knowledge_revision_conflict',
      );
    }
    if (!keepDeleted) snapshot = value;
  }
}

void main() {
  test('删除遇到云端版本冲突时保留新增资料，回读确认后才成功', () async {
    final initial = knowledgeExamples();
    final repo = ConcurrentDeleteRepository(initial)..conflict = true;
    final vm = KnowledgeViewModel(repo);
    addTearDown(vm.dispose);
    addTearDown(() => repo.client.dio.close(force: true));
    await vm.load();
    final target = initial.documents.first.id;
    expect(await vm.delete(target), true);
    expect(repo.writes, 2);
    expect(vm.document(target), isNull);
    expect(vm.document('concurrent-new-document'), isNotNull);
    expect(repo.snapshot.documents.any((d) => d.id == target), false);
  });
  test('云端同一资料已被修改时不自动删除新版本', () async {
    final initial = knowledgeExamples();
    final repo = ConcurrentDeleteRepository(initial)
      ..conflict = true
      ..modifyTarget = true;
    final vm = KnowledgeViewModel(repo);
    addTearDown(vm.dispose);
    addTearDown(() => repo.client.dio.close(force: true));
    await vm.load();
    final target = initial.documents.first.id;
    expect(await vm.delete(target), false);
    expect(repo.writes, 1);
    expect(vm.document(target), isNotNull);
    expect(vm.actionError, contains('已更新'));
  });
  test('服务器回读仍存在资料时不显示删除成功', () async {
    final initial = knowledgeExamples();
    final repo = ConcurrentDeleteRepository(initial)..keepDeleted = true;
    final vm = KnowledgeViewModel(repo);
    addTearDown(vm.dispose);
    addTearDown(() => repo.client.dio.close(force: true));
    await vm.load();
    final target = initial.documents.first.id;
    expect(await vm.delete(target), false);
    expect(vm.document(target), isNotNull);
    expect(vm.actionError, contains('尚未确认删除'));
  });
  test('首次未命中不会永久缓存为空，后台完成索引后再次查询能得到来源', () async {
    final snapshot = await KnowledgeRepository(
      MemoryKnowledgeStore(),
      seedExamples: true,
    ).load();
    final repo = RemoteSearchRepository(snapshot)..empty = true;
    final vm = KnowledgeViewModel(repo);
    addTearDown(vm.dispose);
    addTearDown(() => repo.client.dio.close(force: true));
    await vm.load();
    expect(await vm.findReferences('等待 OCR 的资料'), isEmpty);
    repo.empty = false;
    expect(await vm.findReferences('等待 OCR 的资料'), isNotEmpty);
    expect(repo.calls, 2);
  });
  test('统一检索采用后端语义命中，保留引用，不要求客户端词面包含查询', () async {
    final snapshot = await KnowledgeRepository(
      MemoryKnowledgeStore(),
      seedExamples: true,
    ).load();
    final repo = RemoteSearchRepository(snapshot);
    final vm = KnowledgeViewModel(repo);
    addTearDown(vm.dispose);
    addTearDown(() => repo.client.dio.close(force: true));
    await vm.load();
    expect(vm.retrieve('与原文词面不同的语义查询'), isEmpty);
    final hits = await vm.findReferences(
      '与原文词面不同的语义查询',
      projectId: snapshot.projects.first.id,
    );
    expect(hits.single.nodeId, 'authorized-node');
    expect(hits.single.hash, snapshot.documents.first.selected.hash);
    expect(repo.project, snapshot.projects.first.id);
    await vm.findReferences(
      '与原文词面不同的语义查询',
      projectId: snapshot.projects.first.id,
    );
    expect(repo.calls, 1);
  });

  test('失败的检索不会永久缓存，重试能真正再次请求', () async {
    final snapshot = await KnowledgeRepository(
      MemoryKnowledgeStore(),
      seedExamples: true,
    ).load();
    final repo = RemoteSearchRepository(snapshot)..fail = true;
    final vm = KnowledgeViewModel(repo);
    addTearDown(vm.dispose);
    addTearDown(() => repo.client.dio.close(force: true));
    await vm.load();
    await expectLater(vm.findReferences('query'), throwsStateError);
    repo.fail = false;
    expect(await vm.findReferences('query'), isNotEmpty);
    expect(repo.calls, 2);
  });
}
