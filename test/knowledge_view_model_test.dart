import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:yanshu/features/knowledge/models/knowledge_models.dart';
import 'package:yanshu/features/knowledge/repositories/knowledge_importer.dart';
import 'package:yanshu/features/knowledge/repositories/knowledge_repository.dart';
import 'package:yanshu/features/knowledge/viewmodels/knowledge_view_model.dart';

Future<KnowledgeViewModel> knowledgeModel({KnowledgeStore? store}) async {
  final vm = KnowledgeViewModel(
    KnowledgeRepository(store ?? MemoryKnowledgeStore(), seedExamples: true),
  );
  await vm.load();
  return vm;
}

void main() {
  test('升级前项目和资料的关闭标记不再阻止检索与引用', () async {
    final legacy = knowledgeExamples().toJson();
    for (final project in legacy['projects'] as List) {
      project['allowed'] = false;
    }
    for (final document in legacy['documents'] as List) {
      document['allowed'] = false;
    }
    final vm = await knowledgeModel(
      store: MemoryKnowledgeStore(value: jsonEncode(legacy)),
    );
    addTearDown(vm.dispose);
    final hits = vm.retrieve('30 天');
    expect(hits, isNotEmpty);
    expect(vm.resolveHit(hits.first), isNotNull);
    expect(vm.retrievalLabel(vm.document('demo-scope')!), '允许检索');
  });
  test('会议纪要在切换账户后不可浏览或检索，其他账户保存不丢旧记录', () async {
    String? owner = 'account-a';
    final store = MemoryKnowledgeStore();
    final vm = KnowledgeViewModel(
      KnowledgeRepository(store, seedExamples: true),
      accountId: () => owner,
    );
    await vm.load();
    final first = await vm.archiveMeeting(
      meetingId: 'private-a',
      ownerUserId: owner,
      title: '私有会议',
      content: '仅甲账户可见的原话',
      demo: false,
    );
    expect(first, isNotNull);
    expect(vm.document(first!)!.ownerUserId, owner);
    owner = 'account-b';
    expect(vm.document(first), isNull);
    expect(vm.data.documents.any((d) => d.id == first), isFalse);
    expect(vm.retrieve('仅甲账户'), isEmpty);
    expect(
      await vm.archiveMeeting(
        meetingId: 'private-a',
        ownerUserId: owner,
        title: '覆盖尝试',
        content: '不能覆盖甲',
        demo: false,
      ),
      isNull,
    );
    expect(
      await vm.archiveMeeting(
        meetingId: 'private-b',
        ownerUserId: owner,
        title: '乙的会议',
        content: '乙的原话',
        demo: false,
      ),
      isNotNull,
    );
    owner = 'account-a';
    await vm.load();
    expect(vm.document(first)!.selected.content, '仅甲账户可见的原话');
    expect(vm.document('meeting-private-b'), isNull);
    owner = null;
    expect(vm.document(first), isNull);
    vm.dispose();
  });
  test(
    'MD/TXT decoding accepts BOM and rejects invalid, binary, oversized and unsupported files',
    () {
      expect(
        decodeKnowledgeImport('范围.MD', utf8.encode('\ufeff# 范围\n正文')).content,
        '# 范围\n正文',
      );
      expect(
        decodeKnowledgeImport('memo.txt', utf8.encode('承诺')).kind,
        KnowledgeKind.text,
      );
      for (final invalid in [
        <int>[255, 255],
        <int>[],
        <int>[65, 0, 66],
      ]) {
        expect(
          () => decodeKnowledgeImport('bad.txt', invalid),
          throwsFormatException,
        );
      }
      expect(
        () => decodeKnowledgeImport('doc.pdf', [65]),
        throwsFormatException,
      );
      expect(
        () => decodeKnowledgeImport(
          'large.md',
          List.filled(maxKnowledgeBytes + 1, 65),
        ),
        throwsFormatException,
      );
    },
  );
  test(
    'real notes persist and are immediately searchable, duplicate files rejected',
    () async {
      final store = MemoryKnowledgeStore();
      final vm = await knowledgeModel(store: store);
      addTearDown(vm.dispose);
      final id = await vm.addDocument(
        title: '真实测试笔记',
        content: '只保存在本机的特别资料',
        folderId: 'inbox',
        projectId: 'delivery',
        kind: KnowledgeKind.text,
        allowed: false,
        filename: 'test.txt',
      );
      expect(id, isNotNull);
      expect(vm.retrieve('特别资料'), isNotEmpty);
      final fresh = await knowledgeModel(store: store);
      addTearDown(fresh.dispose);
      expect(fresh.document(id!)!.selected.content, '只保存在本机的特别资料');
      expect(
        await fresh.addDocument(
          title: '重复',
          content: '只保存在本机的特别资料',
          folderId: 'inbox',
          projectId: 'delivery',
          kind: KnowledgeKind.text,
          allowed: false,
          filename: 'other.txt',
        ),
        isNull,
      );
      expect(fresh.actionError, contains('相同内容'));
    },
  );
  test(
    'legacy retrieval flags no longer block existing documents; deletion invalidates hits',
    () async {
      final vm = await knowledgeModel();
      addTearDown(vm.dispose);
      final id = (await vm.addDocument(
        title: '内部资料',
        content: '资料片段quartz',
        folderId: 'inbox',
        projectId: 'desktop',
        kind: KnowledgeKind.note,
        allowed: false,
      ))!;
      final hit = vm.retrieve('quartz').single;
      expect(vm.resolveHit(hit), isNotNull);
      expect(hit.projectId, 'desktop');
      expect(vm.retrieve('quartz', projectId: 'delivery'), isEmpty);
      await vm.delete(id);
      expect(vm.resolveHit(hit), isNull);
      expect(vm.retrieve('quartz'), isEmpty);
      vm.search('quartz');
      expect(vm.visibleDocuments, isEmpty);
    },
  );
  test(
    'new version needs review, never silently replaces current and retains provenance',
    () async {
      final vm = await knowledgeModel();
      addTearDown(vm.dispose);
      final old = vm.document('demo-scope')!;
      final hit = vm.retrieve('30 天').single;
      expect(
        await vm.addVersion(old.id, '范围修订', '交期改为 45 天', '新讨论待确认'),
        isTrue,
      );
      final changed = vm.document(old.id)!;
      expect(changed.versions.length, 2);
      expect(changed.selected.state, KnowledgeValidity.review);
      expect(changed.effective!.id, old.selected.id);
      expect(vm.retrieve('45 天'), isEmpty);
      expect(vm.resolveHit(hit), isNotNull);
      await vm.setValidity(
        changed.id,
        changed.selected.id,
        KnowledgeValidity.current,
        '已由资料所有者核对',
      );
      expect(vm.resolveHit(hit), isNull);
      expect(vm.retrieve('30 天'), isEmpty);
      expect(vm.retrieve('45 天').single.source, '用户编辑副本');
      expect(
        vm.document(old.id)!.versions.first.state,
        KnowledgeValidity.stale,
      );
    },
  );
  test(
    'conflicted, retracted, unknown, expired and hash-mismatched evidence cannot be retrieved',
    () async {
      final vm = await knowledgeModel();
      addTearDown(vm.dispose);
      expect(vm.retrieve('Windows'), isEmpty);
      final d = vm.document('demo-scope')!;
      for (final status in [
        KnowledgeValidity.conflicted,
        KnowledgeValidity.retracted,
        KnowledgeValidity.unknown,
        KnowledgeValidity.stale,
      ]) {
        await vm.setValidity(d.id, d.selected.id, status, '测试状态变更');
        expect(vm.retrieve('30 天'), isEmpty);
      }
      final v = KnowledgeVersion(
        id: 'v',
        number: 1,
        title: '测试',
        content: '正文',
        hash: 'bad-hash',
        createdAt: DateTime.now(),
        state: KnowledgeValidity.current,
      );
      expect(v.integrityOk, isFalse);
      expect(v.usableAt(DateTime.now()), isFalse);
      final expired = KnowledgeVersion(
        id: 'v2',
        number: 1,
        title: '过期',
        content: '正文',
        hash: knowledgeHash('正文'),
        createdAt: DateTime(2020),
        state: KnowledgeValidity.current,
        validUntil: DateTime(2021),
      );
      expect(expired.usableAt(DateTime.now()), isFalse);
    },
  );
  test(
    'folder identity survives rename, nesting rejects cycles, moves preserve authorization',
    () async {
      final vm = await knowledgeModel();
      addTearDown(vm.dispose);
      await vm.createFolder('新文件夹');
      final id = vm.data.folders.last.id;
      await vm.renameFolder(id, '重命名');
      expect(vm.folder(id).name, '重命名');
      await vm.moveFolder(id, 'scope');
      expect(vm.canMoveFolder('scope', id), isFalse);
      expect(await vm.moveFolder('scope', id), isFalse);
      expect(await vm.moveFolder(id, id), isFalse);
      await vm.moveDocument('demo-scope', id);
      expect(vm.document('demo-scope')!.allowed, isTrue);
      await vm.deleteFolder(id);
      expect(vm.document('demo-scope')!.folderId, 'inbox');
      expect(vm.document('demo-scope')!.allowed, isTrue);
      expect(await vm.deleteFolder('inbox'), isFalse);
    },
  );
  test(
    'archive is not permission; removing purges text and old citations and does not reseed',
    () async {
      final store = MemoryKnowledgeStore();
      final vm = await knowledgeModel(store: store);
      addTearDown(vm.dispose);
      final hit = vm.retrieve('30 天').single;
      vm.filterArchived(true);
      vm.search('30 天');
      expect(vm.searchHits, isEmpty);
      await vm.archive('demo-scope', true);
      expect(vm.searchHits, hasLength(1));
      expect(vm.archivedCount, 2);
      expect(vm.resolveHit(hit), isNotNull);
      for (final d in List.of(vm.data.documents)) {
        await vm.delete(d.id);
      }
      expect(vm.resolveHit(hit), isNull);
      expect(store.value, isNot(contains('30 天')));
      final fresh = await knowledgeModel(store: store);
      addTearDown(fresh.dispose);
      expect(fresh.data.documents, isEmpty);
      expect(fresh.data.audit.every((a) => !a.action.contains('交期')), isTrue);
    },
  );
  test(
    'canceled saves and read/write failures never claim a changed library',
    () async {
      final store = KnowledgeFailingStore();
      final vm = await knowledgeModel(store: store);
      addTearDown(vm.dispose);
      expect(vm.error, isNotNull);
      store.failRead = false;
      await vm.load();
      expect(vm.error, isNull);
      store.failWrite = true;
      expect(await vm.delete('demo-scope'), isFalse);
      expect(vm.document('demo-scope'), isNotNull);
      expect(vm.actionError, isNotNull);
    },
  );
  test(
    'local file storage survives restart and removes backup/temp after successful deletion',
    () async {
      final dir = await Directory.systemTemp.createTemp(
        'yanshu-knowledge-test-',
      );
      addTearDown(() => dir.delete(recursive: true));
      final vm = await knowledgeModel(
        store: LocalKnowledgeStore(directory: dir),
      );
      addTearDown(vm.dispose);
      final hit = vm.retrieve('30 天').single;
      await vm.delete(hit.documentId);
      final fresh = await knowledgeModel(
        store: LocalKnowledgeStore(directory: dir),
      );
      addTearDown(fresh.dispose);
      expect(fresh.document(hit.documentId), isNull);
      expect(
        await dir
            .list()
            .where((f) => f.path.endsWith('.backup') || f.path.endsWith('.tmp'))
            .length,
        0,
      );
      final raw = await File(
        '${dir.path}${Platform.pathSeparator}yanshu-knowledge-v1.json',
      ).readAsString();
      expect(raw, isNot(contains('30 天')));
    },
  );
  test(
    'malformed snapshots surface errors without overwriting content',
    () async {
      final store = MemoryKnowledgeStore(value: '{bad json');
      final vm = await knowledgeModel(store: store);
      addTearDown(vm.dispose);
      expect(vm.error, isNotNull);
      expect(store.value, '{bad json');
      final bad = knowledgeExamples().copyWith(
        folders: [
          const KnowledgeFolder(id: 'inbox', name: '未归档'),
          const KnowledgeFolder(id: 'cycle', name: '循环', parentId: 'cycle'),
        ],
      );
      expect(() => validateKnowledge(bad), throwsFormatException);
    },
  );
  test(
    'expiry updates persist and exclude elapsed versions until explicitly cleared',
    () async {
      final store = MemoryKnowledgeStore();
      final vm = await knowledgeModel(store: store);
      addTearDown(vm.dispose);
      final d = vm.document('demo-scope')!;
      await vm.setValidity(
        d.id,
        d.selected.id,
        KnowledgeValidity.current,
        '有效期核对',
        validUntil: DateTime(2020),
      );
      expect(vm.retrieve('30 天'), isEmpty);
      final fresh = await knowledgeModel(store: store);
      addTearDown(fresh.dispose);
      expect(
        fresh
            .document(d.id)!
            .selected
            .validUntil!
            .isAtSameMomentAs(DateTime(2020)),
        isTrue,
      );
      await fresh.setValidity(
        d.id,
        d.selected.id,
        KnowledgeValidity.current,
        '取消有效期限制',
        clearExpiry: true,
      );
      expect(fresh.retrieve('30 天'), hasLength(1));
    },
  );
}

class KnowledgeFailingStore extends MemoryKnowledgeStore {
  bool failRead = true, failWrite = false;
  @override
  Future<String?> read() async {
    if (failRead) throw const FileSystemException('read');
    return super.read();
  }

  @override
  Future<void> write(String value) async {
    if (failWrite) throw const FileSystemException('write');
    return super.write(value);
  }
}
