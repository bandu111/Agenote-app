import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:yanshu/app/theme/app_theme.dart';
import 'package:yanshu/features/knowledge/repositories/knowledge_repository.dart';
import 'package:yanshu/features/knowledge/repositories/knowledge_importer.dart';
import 'package:yanshu/features/knowledge/models/knowledge_models.dart';
import 'package:yanshu/features/knowledge/viewmodels/knowledge_view_model.dart';
import 'package:yanshu/features/knowledge/views/knowledge_forms.dart';

Future<KnowledgeViewModel> mountInput(
  WidgetTester tester, {
  double width = 393,
  double scale = 1,
  double keyboard = 0,
  bool dark = false,
  TargetPlatform platform = TargetPlatform.android,
}) async {
  tester.view.physicalSize = Size(width, 852);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  if (const bool.fromEnvironment('INPUT_CAPTURE')) {
    await tester.runAsync(() async {
      final loader = FontLoader('Input QA')
        ..addFont(
          File(
            'C:/Windows/Fonts/msyh.ttc',
          ).readAsBytes().then(ByteData.sublistView),
        );
      await loader.load();
      final icons = FontLoader('MaterialIcons')
        ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
      await icons.load();
    });
  }
  final vm = KnowledgeViewModel(
    KnowledgeRepository(MemoryKnowledgeStore(), seedExamples: true),
  );
  await vm.load();
  addTearDown(vm.dispose);
  final theme = dark ? AppTheme.dark() : AppTheme.light();
  await tester.pumpWidget(
    ChangeNotifierProvider.value(
      value: vm,
      child: MaterialApp(
        theme: theme.copyWith(
          platform: platform,
          textTheme: const bool.fromEnvironment('INPUT_CAPTURE')
              ? theme.textTheme.apply(fontFamily: 'Input QA')
              : theme.textTheme,
        ),
        builder: (_, child) => MediaQuery(
          data: MediaQueryData(
            size: Size(width, 852),
            textScaler: TextScaler.linear(scale),
            viewInsets: EdgeInsets.only(bottom: keyboard),
          ),
          child: child!,
        ),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => unawaited(
                showKnowledgeInput(
                  context,
                  imported: const KnowledgeImport(
                    '会议笔记.md',
                    '讨论接口验证与测试安排。',
                    KnowledgeKind.markdown,
                  ),
                ),
              ),
              child: const Text('打开录入'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开录入'));
  await tester.pumpAndSettle();
  return vm;
}

Future<void> captureInput(
  WidgetTester tester,
  String name, {
  String boundaryKey = 'knowledge-input-capture',
}) async {
  if (!const bool.fromEnvironment('INPUT_CAPTURE')) return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(ValueKey(boundaryKey)),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    final folder = await Directory(
      'build/quick-input-qa',
    ).create(recursive: true);
    await File(
      '${folder.path}/$name.png',
    ).writeAsBytes(data!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  testWidgets(
    'project selector shares the sheet style, cancel preserves draft and selection saves',
    (tester) async {
      final vm = await mountInput(tester);
      await tester.ensureVisible(
        find.byKey(const ValueKey('knowledge-input-more')),
      );
      await tester.tap(find.byKey(const ValueKey('knowledge-input-more')));
      await tester.pumpAndSettle();
      final trigger = find.byKey(const ValueKey('knowledge-input-project'));
      await tester.ensureVisible(trigger);
      await tester.tap(trigger);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('knowledge-project-menu-capture')),
        findsOneWidget,
      );
      expect(find.byType(DropdownButtonFormField<String>), findsNothing);
      await captureInput(
        tester,
        'project-menu',
        boundaryKey: 'knowledge-project-menu-capture',
      );
      await tester.tap(find.byTooltip('关闭项目选择'));
      await tester.pumpAndSettle();
      expect(find.text('会议笔记'), findsOneWidget);
      await tester.ensureVisible(trigger);
      await tester.tap(trigger);
      await tester.pumpAndSettle();
      final project = vm.data.projects.last;
      final option = find.byKey(
        ValueKey('knowledge-project-option-${project.id}'),
      );
      await tester.ensureVisible(option);
      await tester.tap(option);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('knowledge-project-menu-capture')),
        findsNothing,
      );
      expect(
        find.descendant(of: trigger, matching: find.text(project.name)),
        findsOneWidget,
      );
      await tester.ensureVisible(
        find.byKey(const ValueKey('knowledge-input-save')),
      );
      await tester.tap(find.byKey(const ValueKey('knowledge-input-save')));
      await tester.pumpAndSettle();
      expect(vm.data.documents.last.projectId, project.id);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'quick-entry layout saves into the selected folder using real repository state',
    (tester) async {
      final vm = await mountInput(tester);
      expect(find.text('导入内容'), findsNothing);
      expect(
        find.byKey(const ValueKey('knowledge-input-project')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('knowledge-input-more')),
        findsOneWidget,
      );
      await captureInput(tester, 'import-sheet');
      final folder = vm.data.folders.firstWhere((f) => f.id != 'inbox');
      final chip = find.byKey(ValueKey('knowledge-folder-choice-${folder.id}'));
      await tester.ensureVisible(chip);
      await tester.tap(chip);
      await tester.pumpAndSettle();
      expect(tester.widget<ChoiceChip>(chip).selected, true);
      await tester.ensureVisible(
        find.byKey(const ValueKey('knowledge-input-save')),
      );
      await tester.tap(find.byKey(const ValueKey('knowledge-input-save')));
      await tester.pumpAndSettle();
      final saved = vm.data.documents.last;
      expect(saved.folderId, folder.id);
      expect(saved.selected.content, '讨论接口验证与测试安排。');
      expect(saved.filename, '会议笔记.md');
      expect(
        find.byKey(const ValueKey('knowledge-quick-input-sheet')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );
  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    testWidgets(
      'input remains usable on narrow/large-text keyboard screens on $platform',
      (tester) async {
        await mountInput(
          tester,
          width: 320,
          scale: 1.6,
          keyboard: 290,
          dark: true,
          platform: platform,
        );
        await tester.ensureVisible(
          find.byKey(const ValueKey('knowledge-input-more')),
        );
        await tester.tap(find.byKey(const ValueKey('knowledge-input-more')));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('knowledge-input-project')),
          findsOneWidget,
        );
        await tester.ensureVisible(
          find.byKey(const ValueKey('knowledge-input-save')),
        );
        await tester.pumpAndSettle();
        expect(
          tester
              .getRect(find.byKey(const ValueKey('knowledge-input-save')))
              .bottom,
          lessThanOrEqualTo(562),
        );
        await captureInput(tester, 'narrow-$platform');
        expect(tester.takeException(), isNull);
      },
    );
  }
}
