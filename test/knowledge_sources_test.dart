import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:yanshu/features/knowledge/models/knowledge_models.dart';
import 'package:yanshu/features/knowledge/repositories/knowledge_repository.dart';
import 'package:yanshu/features/knowledge/repositories/knowledge_source_checks.dart';
import 'package:yanshu/features/progress/repositories/progress_repository.dart';
import 'package:yanshu/features/progress/viewmodels/progress_view_model.dart';
import 'knowledge_view_model_test.dart';

void main() {
  test(
    'source stream excludes self and yields bound sources and survives restart',
    () async {
      final store = MemoryKnowledgeStore();
      final vm = await knowledgeModel(store: store);
      final progress = ProgressViewModel(MockProgressRepository());
      addTearDown(vm.dispose);
      addTearDown(progress.dispose);
      await progress.load();
      final d = vm.document('demo-scope')!, target = vm.document('demo-guide')!;
      final link = KnowledgeSourceLink(
        kind: KnowledgeSourceKind.document,
        targetId: target.id,
        versionId: target.selected.id,
        hash: target.selected.hash,
      );
      expect(await vm.updateSource(d.id, d.selected.id, link), isTrue);
      final events = await KnowledgeSourceChecks(
        vm,
        progress,
      ).watch(d.id, d.selected.id).toList();
      expect(events.map((e) => e.length), [0, 1]);
      expect(events.last.last.available, isTrue);
      expect(events.last.last.text, isNotEmpty);
      final fresh = await knowledgeModel(store: store);
      addTearDown(fresh.dispose);
      expect(fresh.document(d.id)!.selected.sources.single.key, link.key);
      // Older snapshots without the new field still load.
      final legacy = jsonDecode(store.value!) as Map<String, dynamic>;
      for (final doc in legacy['documents']) {
        for (final v in doc['versions']) {
          v.remove('sources');
        }
      }
      expect(
        KnowledgeSnapshot.fromJson(legacy).documents.first.selected.sources,
        isEmpty,
      );
    },
  );

  test(
    'revoked/deleted document sources expose no cached body and do not rebind to a new version',
    () async {
      final vm = await knowledgeModel();
      final progress = ProgressViewModel(MockProgressRepository());
      addTearDown(vm.dispose);
      addTearDown(progress.dispose);
      final target = vm.document('demo-guide')!;
      final link = KnowledgeSourceLink(
        kind: KnowledgeSourceKind.document,
        targetId: target.id,
        versionId: target.selected.id,
        hash: target.selected.hash,
      );
      final checks = KnowledgeSourceChecks(vm, progress);
      expect(checks.resolve(link).available, isTrue);
      await vm.setValidity(
        target.id,
        target.effective!.id,
        KnowledgeValidity.retracted,
        '撤回资料',
      );
      expect(checks.resolve(link).text, isEmpty);
      expect(checks.resolve(link).available, isFalse);
      await vm.delete(target.id);
      expect(checks.resolve(link).status, '来源失效');
      expect(checks.resolve(link).text, isEmpty);
    },
  );

  test(
    'voice references resolve real session bounds and detect changed transcript hashes',
    () async {
      final vm = await knowledgeModel();
      final progress = ProgressViewModel(MockProgressRepository());
      addTearDown(vm.dispose);
      addTearDown(progress.dispose);
      await progress.load();
      final c = progress.data.commitments.first, d = vm.document('demo-scope')!;
      final link = KnowledgeSourceLink(
        kind: KnowledgeSourceKind.voice,
        targetId: c.id,
        versionId: c.evidence.id,
        hash: voiceSourceHash(c.evidence),
      );
      expect(await vm.updateSource(d.id, d.selected.id, link), isTrue);
      final checks = KnowledgeSourceChecks(vm, progress);
      final row = checks.resolve(link);
      expect(row.available, isTrue);
      expect(row.text, c.evidence.transcript);
      expect(row.voice!.start, c.evidence.start);
      expect(row.status, contains('示例音频未提供'));
      final changed = checks.resolve(
        KnowledgeSourceLink(
          kind: KnowledgeSourceKind.voice,
          targetId: c.id,
          versionId: c.evidence.id,
          hash: 'changed',
        ),
      );
      expect(changed.available, isFalse);
      expect(changed.voice, isNull);
      expect(changed.text, isEmpty);
      expect(
        await vm.updateSource(d.id, d.selected.id, link, remove: true),
        isTrue,
      );
      expect(vm.document(d.id)!.selected.sources, isEmpty);
    },
  );
}
