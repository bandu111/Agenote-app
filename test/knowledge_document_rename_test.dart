import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yanshu/features/knowledge/widgets/knowledge_components.dart';
import 'package:yanshu/features/knowledge/repositories/knowledge_repository.dart';
import 'package:yanshu/features/knowledge/viewmodels/knowledge_view_model.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('inline rename persists name while keeping version, content and date', (tester) async {
    final repository = KnowledgeRepository(MemoryKnowledgeStore(), seedExamples: true);
    final vm = KnowledgeViewModel(repository);
    addTearDown(vm.dispose);
    await vm.load();
    final original = vm.data.documents.first;
    final version = original.selected;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: KnowledgeDocumentCard(
      document: original, projectName: '项目', retrievalLabel: '允许检索',
      onRename: (title) => vm.renameDocument(original.id, title),
    ))));
    await tester.tap(find.byKey(ValueKey('knowledge-document-edit-${original.id}')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '修改后的资料名称');
    await tester.tap(find.byTooltip('保存名称'));
    await tester.pumpAndSettle();
    final saved = (await repository.load()).documents.firstWhere((d) => d.id == original.id);
    expect(saved.selected.title, '修改后的资料名称');
    expect(saved.selected.id, version.id);
    expect(saved.selected.content, version.content);
    expect(saved.selected.createdAt.isAtSameMomentAs(version.createdAt), isTrue);
    expect(saved.versions.length, original.versions.length);
    expect(find.byType(TextField), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
