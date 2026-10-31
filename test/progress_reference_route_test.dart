import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:yanshu/features/knowledge/repositories/knowledge_repository.dart';
import 'package:yanshu/features/knowledge/viewmodels/knowledge_view_model.dart';
import 'package:yanshu/features/progress/widgets/goal_related_sections.dart';

void main() {
  for (final label in ['目标关联 · 接口验收', '承诺关联 · 提交报告']) {
    testWidgets('$label preserves its own relation metadata', (tester) async {
      final kb = KnowledgeViewModel(
        KnowledgeRepository(MemoryKnowledgeStore(), seedExamples: true),
      );
      addTearDown(kb.dispose);
      await kb.load();
      final document = kb.data.documents.first;
      final version = document.selected;
      Uri? opened;
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (_, _) => Scaffold(
              body: BoundKnowledgeSection(
                references: [
                  {
                    'documentId': document.id,
                    'versionId': version.id,
                    'hash': version.hash,
                  },
                ],
                relationLabel: label,
                relationQuery: '各自关联的查询',
                relationQuote: '各自对应的原始依据',
              ),
            ),
          ),
          GoRoute(
            path: '/knowledge/documents/:id',
            builder: (_, state) {
              opened = state.uri;
              return const Scaffold(body: Text('引用页面'));
            },
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: kb,
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text(version.title));
      await tester.pumpAndSettle();
      expect(opened?.queryParameters['version'], version.id);
      expect(opened?.queryParameters['hash'], version.hash);
      expect(opened?.queryParameters['relation'], label);
      expect(opened?.queryParameters['quote'], '各自对应的原始依据');
      expect(tester.takeException(), isNull);
    });
  }
}
