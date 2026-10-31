import 'package:yanshu/shared/widgets/content_skeleton.dart';
import 'package:yanshu/features/progress/repositories/progress_repository.dart';
import 'package:yanshu/features/profile/repositories/profile_repository.dart';
import 'dart:async';
import 'dart:convert';
import 'package:printing/printing.dart';
import 'package:yanshu/features/knowledge/repositories/knowledge_pdf_document.dart';
import 'support/pdf_preview_platform.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:yanshu/app/app.dart';
import 'package:yanshu/features/knowledge/models/knowledge_models.dart';
import 'package:yanshu/features/knowledge/repositories/knowledge_importer.dart';
import 'package:yanshu/features/knowledge/repositories/knowledge_repository.dart';
import 'package:yanshu/features/knowledge/viewmodels/knowledge_view_model.dart';
import 'package:yanshu/features/knowledge/views/knowledge_page.dart';
import 'package:yanshu/features/knowledge/views/knowledge_forms.dart';
import 'package:yanshu/features/knowledge/repositories/knowledge_source_checks.dart';
import 'package:yanshu/features/progress/viewmodels/progress_view_model.dart';
import 'knowledge_view_model_test.dart' show KnowledgeFailingStore;

class BlockingKnowledgeStore extends MemoryKnowledgeStore {
  Completer<void>? gate;
  @override
  Future<void> write(String value) async {
    await gate?.future;
    await super.write(value);
  }
}

Future<void> openLibrary(
  WidgetTester tester, {
  KnowledgeStore? store,
  KnowledgeImporter? importer,
}) async {
  await tester.pumpWidget(
    YanShuApp(
      progressRepository: MockProgressRepository(),
      profileRepository: ProfileRepository(MemoryProfileStore()),
      initialLocation: '/knowledge',
      knowledgeRepository: KnowledgeRepository(
        store ?? MemoryKnowledgeStore(),
        seedExamples: true,
      ),
      knowledgeImporter: importer ?? FakeKnowledgeImporter(),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> kbTap(WidgetTester tester, Finder finder) async {
  if (finder.evaluate().isEmpty) {
    await tester.scrollUntilVisible(
      finder,
      250,
      scrollable: find
          .descendant(
            of: find.byKey(const PageStorageKey('knowledge-scroll')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
  } else {
    await tester.ensureVisible(finder);
  }
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> addChoice(WidgetTester tester, String value) async {
  await tester.tap(find.byKey(const ValueKey('knowledge-add')));
  await tester.pumpAndSettle();
  expect(find.text('新建笔记'), findsNothing);
  expect(find.text('保存链接'), findsNothing);
  expect(find.byKey(const ValueKey('knowledge-add-folder')), findsNothing);
  await tester.tap(find.byKey(ValueKey('knowledge-add-$value')));
  await tester.pumpAndSettle();
}

void phone(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  testWidgets('滑动确认移除后，资料从页面和重新读取的资料库消失', (tester) async {
    phone(tester, const Size(390, 844));
    final store = BlockingKnowledgeStore();
    await openLibrary(tester, store: store);
    final vm = tester
        .element(find.byType(KnowledgePage))
        .read<KnowledgeViewModel>();
    final id = vm.data.documents.first.id;
    final item = find.byKey(ValueKey('knowledge-dismiss-$id'));
    await tester.ensureVisible(item);
    await tester.pumpAndSettle();
    await tester.drag(item, const Offset(340, 0));
    await tester.pumpAndSettle();
    expect(find.text('移除这份资料？'), findsOneWidget);
    expect(find.text('先留着'), findsOneWidget);
    store.gate = Completer<void>();
    await tester.tap(find.text('移除').last);
    await tester.pump(const Duration(milliseconds: 300));
    expect(vm.deleting, true);
    expect(find.byType(ContentSkeleton), findsOneWidget);
    expect(vm.document(id), isNotNull);
    store.gate!.complete();
    await tester.pumpAndSettle();
    expect(vm.deleting, false);
    expect(vm.document(id), isNull);
    expect(find.byKey(ValueKey('knowledge-dismiss-$id')), findsNothing);
    expect(
      (await KnowledgeRepository(
        store,
      ).load()).documents.any((d) => d.id == id),
      false,
    );
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'folder renames inline with cancel and persistence, with archive tabs and no list menus',
    (tester) async {
      phone(tester, const Size(390, 844));
      final store = MemoryKnowledgeStore();
      await openLibrary(tester, store: store);
      final vm = tester
          .element(find.byType(KnowledgePage))
          .read<KnowledgeViewModel>();
      expect(
        find.byKey(const ValueKey('knowledge-project-filter')),
        findsNothing,
      );
      expect(find.byKey(const ValueKey('knowledge-tab-0')), findsOneWidget);
      expect(find.byTooltip('文件夹操作'), findsNothing);
      expect(find.byTooltip('资料操作'), findsNothing);
      expect(find.byIcon(Icons.more_horiz), findsNothing);
      final edit = find.byKey(const ValueKey('knowledge-folder-edit-scope'));
      final input = find.byKey(const ValueKey('knowledge-folder-name-scope'));
      await tester.tap(edit);
      await tester.pumpAndSettle();
      await tester.enterText(input, '取消的修改');
      await tester.tap(find.byTooltip('取消修改'));
      await tester.pumpAndSettle();
      expect(
        vm.data.folders.firstWhere((f) => f.id == 'scope').name,
        '项目合同与范围',
      );
      await tester.tap(edit);
      await tester.pumpAndSettle();
      await tester.enterText(input, '项目档案');
      await tester.tap(
        find.byKey(const ValueKey('knowledge-folder-save-scope')),
      );
      await tester.pumpAndSettle();
      expect(input, findsNothing);
      expect(vm.data.folders.firstWhere((f) => f.id == 'scope').name, '项目档案');
      expect(store.value, contains('项目档案'));
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'file picker cancel is silent and actual selected MD populates editable import',
    (tester) async {
      phone(tester, const Size(390, 844));
      final picker = FakeKnowledgeImporter();
      await openLibrary(tester, importer: picker);
      await addChoice(tester, 'file');
      expect(find.byKey(const ValueKey('knowledge-input-title')), findsNothing);
      picker.value = decodeKnowledgeImport(
        '本地导入.md',
        utf8.encode('# 本地测试\n本机文本'),
      );
      await addChoice(tester, 'file');
      expect(find.text('本地导入'), findsOneWidget);
      expect(find.byKey(const ValueKey('knowledge-input-allow')), findsNothing);
      await kbTap(tester, find.byKey(const ValueKey('knowledge-input-save')));
      final vm = tester
          .element(find.byType(KnowledgePage))
          .read<KnowledgeViewModel>();
      expect(vm.data.documents.last.selected.content, '# 本地测试\n本机文本');
      expect(vm.data.documents.last.allowed, isTrue);
      expect(vm.retrieve('本机文本'), isNotEmpty);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'authorized hit opens exact original span and revoked citation becomes unavailable',
    (tester) async {
      phone(tester, const Size(390, 844));
      await openLibrary(tester);
      final vm = tester
          .element(find.byType(KnowledgePage))
          .read<KnowledgeViewModel>();
      await tester.tap(find.byKey(const ValueKey('knowledge-search-toggle')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('knowledge-search')),
        '30 天',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('查看原文位置 ›'));
      await tester.pumpAndSettle();
      expect(find.text('已定位原文引用'), findsOneWidget);
      expect(find.byType(NavigationBar), findsNothing);
      await vm.setValidity(
        'demo-scope',
        vm.document('demo-scope')!.effective!.id,
        KnowledgeValidity.retracted,
        '撤回资料',
      );
      await tester.pumpAndSettle();
      expect(find.text('这条引用已失效，请重新检索'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'editing makes a review version, does not silently overwrite effective evidence',
    (tester) async {
      phone(tester, const Size(390, 844));
      await openLibrary(tester);
      final vm = tester
          .element(find.byType(KnowledgePage))
          .read<KnowledgeViewModel>();
      await kbTap(tester, find.text('一期交付范围与验收约定'));
      expect(
        find.byKey(const ValueKey('knowledge-edit-version')),
        findsNothing,
      );
      expect(find.byTooltip('更多资料操作'), findsNothing);
      unawaited(
        showKnowledgeInput(
          tester.element(find.text('资料详情')),
          editing: vm.document('demo-scope'),
          kind: KnowledgeKind.markdown,
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('knowledge-input-content')),
        '交期变为 45 天，待双方核对。',
      );
      await kbTap(
        tester,
        find.byKey(const ValueKey('knowledge-change-reason')),
      );
      await tester.enterText(
        find.byKey(const ValueKey('knowledge-change-reason')),
        '补充讨论记录',
      );
      await kbTap(tester, find.byKey(const ValueKey('knowledge-input-save')));
      expect(
        vm.document('demo-scope')!.selected.state,
        KnowledgeValidity.review,
      );
      expect(vm.document('demo-scope')!.effective!.number, 1);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'long press drag moves a card to another folder without changing its grant',
    (tester) async {
      phone(tester, const Size(390, 1100));
      await openLibrary(tester);
      final vm = tester
          .element(find.byType(KnowledgePage))
          .read<KnowledgeViewModel>();
      vm.toggleFolder('meetings');
      await tester.pumpAndSettle();
      final source = find.byKey(
        const ValueKey('knowledge-document-demo-scope'),
      );
      final gesture = await tester.startGesture(tester.getCenter(source));
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
      final target = find.byKey(
        const ValueKey('knowledge-folder-toggle-technical'),
      );
      await gesture.moveTo(tester.getCenter(target));
      await tester.pump(const Duration(milliseconds: 100));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(vm.document('demo-scope')!.folderId, 'technical');
      expect(vm.document('demo-scope')!.allowed, isTrue);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'compact source cards hide auxiliary controls and open bound voice transcripts',
    (tester) async {
      phone(tester, const Size(390, 844));
      await openLibrary(tester);
      final vm = tester
          .element(find.byType(KnowledgePage))
          .read<KnowledgeViewModel>();
      final progress = tester
          .element(find.byType(KnowledgePage))
          .read<ProgressViewModel>();
      await tester.runAsync(progress.load);
      await tester.pumpAndSettle();
      final c = progress.data.commitments.first;
      final sourceDoc = await vm.addDocument(
        title: '语音来源核对',
        content: c.evidence.transcript,
        folderId: 'inbox',
        projectId: 'personal',
        kind: KnowledgeKind.note,
      );
      final d = vm.document(sourceDoc!)!;
      final linked = KnowledgeSourceLink(
        kind: KnowledgeSourceKind.voice,
        targetId: c.id,
        versionId: c.evidence.id,
        hash: voiceSourceHash(c.evidence),
      );
      await vm.updateSource(d.id, d.selected.id, linked);
      await tester.pumpAndSettle();
      await kbTap(tester, find.text('语音来源核对'));
      expect(find.text('变更记录'), findsNothing);
      expect(find.text('来源与版本核对'), findsOneWidget);
      expect(
        find.text(
          '${sourceMatchPercent('${d.selected.title} ${d.selected.content}', c.evidence.transcript)}% 匹配',
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('knowledge-original-overview')),
        findsOneWidget,
      );
      expect(find.text('关联来源'), findsNothing);
      expect(find.text('核对版本有效状态'), findsNothing);
      expect(find.text('文档 · 语音'), findsNothing);
      expect(find.text('按来源逐项核对，关联不代表内容已确认。'), findsNothing);
      await kbTap(
        tester,
        find.byKey(ValueKey('knowledge-source-card-${linked.key}')),
      );
      expect(find.text('语音转写'), findsOneWidget);
      await kbTap(tester, find.text('取消来源关联'));
      expect(vm.document(d.id)!.selected.sources, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'binary PDF import saves original without requiring fake body text',
    (tester) async {
      phone(tester, const Size(390, 844));
      final picker = FakeKnowledgeImporter()
        ..value = decodeKnowledgeImport(
          'report.pdf',
          utf8.encode('%PDF-1.4\n%%EOF'),
        );
      await openLibrary(tester, importer: picker);
      await addChoice(tester, 'file');
      await kbTap(tester, find.byKey(const ValueKey('knowledge-input-save')));
      final vm = tester
          .element(find.byType(KnowledgePage))
          .read<KnowledgeViewModel>();
      final doc = vm.data.documents.last;
      expect(doc.kind, KnowledgeKind.pdf);
      expect(doc.selected.content, isEmpty);
      expect(doc.fileData, isNotNull);
      expect(vm.retrievable(doc), isFalse);
      await kbTap(tester, find.text('report'));
      expect(find.text('原文概览'), findsOneWidget);
      expect(find.text('暂无文本摘要，点击「打开文档」查看原文件。'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('knowledge-open-original')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('read failure has retry without dropping the library', (
    tester,
  ) async {
    final store = KnowledgeFailingStore();
    await openLibrary(tester, store: store);
    expect(find.text('资料库读取失败，原有本地资料未被覆盖，请重试'), findsOneWidget);
    store.failRead = false;
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('一期交付范围与验收约定'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    testWidgets(
      'library and reader support narrow large text on $platform',
      (tester) async {
        phone(tester, const Size(320, 640));
        tester.platformDispatcher.textScaleFactorTestValue = 2;
        tester.platformDispatcher.accessibilityFeaturesTestValue =
            const FakeAccessibilityFeatures(disableAnimations: true);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        addTearDown(
          tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
        );
        await openLibrary(tester);
        expect(tester.takeException(), isNull);
        await kbTap(tester, find.text('一期交付范围与验收约定'));
        expect(find.text('资料详情'), findsOneWidget);
        final raster = PdfPreviewTestPlatform();
        final previous = installPdfPreviewTestPlatform(raster);
        addTearDown(() => restorePdfPreviewTestPlatform(previous));
        await tester.runAsync(KnowledgePdfDocument.prepareFont);
        await kbTap(
          tester,
          find.byKey(const ValueKey('knowledge-open-original')),
        );
        expect(
          find.byKey(const ValueKey('knowledge-pdf-preview')),
          findsOneWidget,
        );
        for (
          var attempt = 0;
          attempt < 50 && find.byType(PdfPreview).evaluate().isEmpty;
          attempt++
        ) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 100)),
          );
          await tester.pump();
        }
        expect(find.byType(PdfPreview), findsOneWidget);
        // Reduced-motion skeletons do not schedule frames. Advance the PDF
        // renderer's own debounce instead of relying on a spinning indicator.
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pumpAndSettle();
        expect(latin1.decode(raster.document!.take(5).toList()), '%PDF-');
        await tester.tap(find.byType(BackButton).last);
        await tester.pumpAndSettle();
        expect(find.text('资料详情'), findsOneWidget);
        expect(find.text('原文'), findsNothing);
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant({platform}),
    );
  }
}

class FakeKnowledgeImporter implements KnowledgeImporter {
  KnowledgeImport? value;
  @override
  Future<KnowledgeImport?> pick() async => value;
}
