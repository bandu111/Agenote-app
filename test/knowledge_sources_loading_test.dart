import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:yanshu/core/network/api_client.dart';
import 'package:yanshu/features/knowledge/models/knowledge_models.dart';
import 'package:yanshu/features/knowledge/repositories/dio_knowledge_repository.dart';
import 'package:yanshu/features/knowledge/repositories/knowledge_repository.dart';
import 'package:yanshu/features/knowledge/repositories/knowledge_source_checks.dart';
import 'package:yanshu/features/knowledge/viewmodels/knowledge_view_model.dart';
import 'package:yanshu/features/knowledge/widgets/knowledge_components.dart';
import 'package:yanshu/features/knowledge/widgets/knowledge_sources_section.dart';
import 'package:yanshu/features/progress/repositories/progress_repository.dart';
import 'package:yanshu/features/progress/viewmodels/progress_view_model.dart';
import 'package:yanshu/features/progress/viewmodels/voice_evidence_controller.dart';

class SearchRepository extends DioKnowledgeRepository {
  SearchRepository(this.snapshot)
    : super(ApiClient(baseUrl: 'https://invalid.example/api/v1/'));
  final KnowledgeSnapshot snapshot;
  Future<List<Map<String, dynamic>>> result = Future.value([]);
  int searches = 0;
  @override
  String get accountId => 'owner';
  @override
  Future<KnowledgeSnapshot> load() async => snapshot;
  @override
  Future<List<Map<String, dynamic>>> search(String query, {String? projectId}) {
    searches++;
    return result;
  }

  @override
  Future<bool> resolve(Map<String, dynamic> hit) async => true;
}

Future<({KnowledgeViewModel kb, SearchRepository repo, VoidCallback rebuild})>
mountSources(
  WidgetTester tester, {
  bool filtered = false,
  Future<List<Map<String, dynamic>>> Function(KnowledgeSnapshot)? response,
}) async {
  final seed = await KnowledgeRepository(
    MemoryKnowledgeStore(),
    seedExamples: true,
  ).load();
  final repo = SearchRepository(seed);
  if (response != null) repo.result = response(seed);
  final kb = KnowledgeViewModel(repo, accountId: filtered ? () => null : null);
  // 使用本地授权过滤路径复现 data 每次返回新对象的情形。
  final visibleKb = filtered
      ? KnowledgeViewModel(
          KnowledgeRepository(
            MemoryKnowledgeStore(value: jsonEncode(seed.toJson())),
          ),
          accountId: () => 'owner',
        )
      : kb;
  await visibleKb.load();
  final progress = ProgressViewModel(EmptyProgressRepository());
  final audio = VoiceEvidenceController();
  addTearDown(() {
    visibleKb.dispose();
    if (!identical(visibleKb, kb)) kb.dispose();
    audio.dispose();
    repo.client.dio.close(force: true);
  });
  late VoidCallback rebuild;
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: visibleKb),
        ChangeNotifierProvider(create: (_) => progress),
        ChangeNotifierProvider.value(value: audio),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              rebuild = () => setState(() {});
              final d = visibleKb.document('demo-scope')!;
              return SingleChildScrollView(
                child: KnowledgeSourcesSection(
                  document: d,
                  version: d.selected,
                ),
              );
            },
          ),
        ),
      ),
    ),
  );
  return (kb: visibleKb, repo: repo, rebuild: () => rebuild());
}

void main() {
  testWidgets('授权过滤快照和反复重建立即加载且反复重建不重发请求，无来源显示空', (tester) async {
    final h = await mountSources(tester, filtered: true);
    expect(identical(h.kb.data, h.kb.data), isFalse);
    for (var i = 0; i < 9; i++) {
      h.rebuild();
      await tester.pump(const Duration(milliseconds: 500));
    }
    await settleSources(tester);
    expect(
      find.byKey(const ValueKey('knowledge-sources-empty')),
      findsOneWidget,
    );
    expect(find.text('100% 匹配'), findsNothing);
    expect(find.byType(KnowledgeReferenceCard), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('后端返回空集合后结束骨架加载，不把自身作为匹配', (tester) async {
    final pending = Completer<List<Map<String, dynamic>>>();
    final h = await mountSources(tester, response: (_) => pending.future);
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    expect(h.repo.searches, 1);
    expect(find.byKey(const ValueKey('knowledge-sources-empty')), findsNothing);
    pending.complete([]);
    await settleSources(tester);
    expect(find.text('暂无匹配来源'), findsOneWidget);
    h.rebuild();
    await tester.pump(const Duration(seconds: 5));
    expect(h.repo.searches, 1);
    expect(find.text('暂无匹配来源'), findsOneWidget);
  });

  testWidgets('来源请求超时可重试，不能永久显示骨架', (tester) async {
    final pending = Completer<List<Map<String, dynamic>>>();
    final h = await mountSources(tester, response: (_) => pending.future);
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    await tester.pump(const Duration(seconds: 31));
    await tester.pump();
    expect(find.text('来源暂时读取失败'), findsOneWidget);
    h.repo.result = Future.value([]);
    await tester.tap(find.text('重新核对'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));
    await settleSources(tester);
    expect(find.text('暂无匹配来源'), findsOneWidget);
    expect(h.repo.searches, 2);
    pending.complete([]);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('60及以上来源显示独立卡片和后端返回的匹配度', (tester) async {
    final response = Completer<List<Map<String, dynamic>>>();
    final h = await mountSources(tester, response: (_) => response.future);
    final own = h.kb.document('demo-scope')!;
    final others = h.kb.data.documents
        .where((d) => d.id != own.id)
        .take(2)
        .toList();
    expect(others.length, 2);
    response.complete([
      for (final d in [own, ...others])
        {
          'documentId': d.id,
          'versionId': d.selected.id,
          'title': d.selected.title,
          'text': d.selected.content,
          'matchPercent': d == others.first ? 60 : 85,
        },
    ]);
    await tester.pump(const Duration(seconds: 3));
    await settleSources(tester);
    expect(find.byType(KnowledgeReferenceCard), findsNWidgets(2));
    for (final d in others) {
      final card = find.byKey(
        ValueKey('knowledge-source-card-${d.id}:${d.selected.id}'),
      );
      expect(card, findsOneWidget);
      expect(
        find.descendant(
          of: card,
          matching: find.text('${d == others.first ? 60 : 85}% 匹配'),
        ),
        findsOneWidget,
      );
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('低于60的来源全部隐藏，结束加载后显示空状态', (tester) async {
    final response = Completer<List<Map<String, dynamic>>>();
    final h = await mountSources(tester, response: (_) => response.future);
    final d = h.kb.data.documents.firstWhere((d) => d.id != 'demo-scope');
    response.complete([
      {
        'documentId': d.id,
        'versionId': d.selected.id,
        'title': d.selected.title,
        'text': d.selected.content,
        'matchPercent': 59,
      },
    ]);
    await tester.pump(const Duration(seconds: 3));
    await settleSources(tester);
    expect(find.byType(KnowledgeReferenceCard), findsNothing);
    expect(find.text('暂无匹配来源'), findsOneWidget);
    expect(find.byType(KnowledgeSourceSkeleton), findsNothing);
    expect(tester.takeException(), isNull);
  });

  test('匹配度来自文本：相同100、无重合0、缺少文本无分值', () {
    expect(sourceMatchPercent('交付验收', '交付验收'), 100);
    expect(sourceMatchPercent('交付验收', '苹果香蕉'), 0);
    expect(sourceMatchPercent('', '验收'), isNull);
  });
}

Future<void> settleSources(WidgetTester tester) async {
  await tester.pump();
  // 让异步生成器的关闭/取消完成，不能只推进动画的虚拟时钟。
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 10)),
  );
  await tester.pumpAndSettle();
}
