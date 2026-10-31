import 'package:flutter_test/flutter_test.dart';
import 'package:yanshu/features/knowledge/models/knowledge_models.dart';
import 'package:yanshu/features/knowledge/repositories/knowledge_repository.dart';
import 'package:yanshu/features/progress/repositories/goal_knowledge_matcher.dart';
import 'package:yanshu/features/progress/repositories/progress_repository.dart';

void main() {
  test(
    'goal matching ignores legacy flags and uses project and valid current text',
    () async {
      final goal = (await MockProgressRepository().load()).goals.first;
      final library = knowledgeExamples();
      final document = library.documents.first;
      expect(matchGoalDocuments(goal, library).map((d) => d.id), [
        'demo-scope',
        'demo-guide',
      ]);
      expect(
        matchGoalDocuments(
          goal,
          library.copyWith(documents: [document.copyWith(allowed: false)]),
        ),
        isNotEmpty,
      );
      expect(
        matchGoalDocuments(
          goal,
          library.copyWith(
            projects: [library.projects.first.withAllowed(false)],
          ),
        ),
        isNotEmpty,
      );
      expect(
        matchGoalDocuments(
          goal,
          library.copyWith(
            documents: [document.copyWith(projectId: 'desktop')],
          ),
        ),
        isEmpty,
      );
      expect(
        matchGoalDocuments(
          goal,
          library.copyWith(
            documents: [
              document.copyWith(
                versions: [
                  document.selected.withState(
                    KnowledgeValidity.retracted,
                    'withdrawn',
                  ),
                ],
              ),
            ],
          ),
        ),
        isEmpty,
      );
      expect(
        matchGoalDocuments(
          goal,
          library.copyWith(documents: [library.documents.last]),
        ),
        isEmpty,
      );
    },
  );
  test(
    'binary filenames can match without inventing body text; review versions never replace the match',
    () async {
      final goal = (await MockProgressRepository().load()).goals.first;
      final library = knowledgeExamples();
      final document = library.documents.first;
      final current = document.selected;
      final review = KnowledgeVersion(
        id: 'review',
        number: 2,
        title: 'Unconfirmed draft',
        content: 'draft',
        hash: knowledgeHash('draft'),
        createdAt: DateTime.now(),
        state: KnowledgeValidity.review,
      );
      final changed = document.copyWith(
        versions: [current, review],
        selectedVersionId: review.id,
      );
      expect(
        matchGoalDocuments(
          goal,
          library.copyWith(documents: [changed]),
        ).single.selectedVersionId,
        current.id,
      );
      final empty = KnowledgeVersion(
        id: 'pdf-v1',
        number: 1,
        title: 'Android 双端测试与验收方案',
        content: '',
        hash: knowledgeHash(''),
        createdAt: DateTime.now(),
        state: KnowledgeValidity.current,
      );
      final pdf = KnowledgeDocument(
        id: 'pdf',
        folderId: 'technical',
        projectId: 'delivery',
        kind: KnowledgeKind.pdf,
        source: 'Import',
        filename: 'Android 双端测试与验收方案.pdf',
        createdAt: DateTime.now(),
        versions: [empty],
        selectedVersionId: empty.id,
        allowed: true,
      );
      final matches = matchGoalDocuments(
        goal,
        library.copyWith(documents: [pdf]),
      );
      expect(matches.single.id, 'pdf');
      expect(matches.single.selected.content, isEmpty);
    },
  );
}
