import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yanshu/app/l10n/app_strings.dart';
import 'package:yanshu/app/theme/app_theme.dart';
import 'package:yanshu/features/progress/models/progress_models.dart';
import 'package:yanshu/features/progress/repositories/progress_repository.dart';
import 'package:yanshu/features/progress/widgets/goal_topology.dart';

Future<ProgressGoal> example() async =>
    (await MockProgressRepository().load()).goals.first;
Future<void> graphApp(
  WidgetTester tester,
  ProgressGoal goal, {
  bool reduced = false,
  bool english = false,
  bool dark = false,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      locale: english ? const Locale('en') : const Locale('zh'),
      supportedLocales: const [Locale('en'), Locale('zh')],
      localizationsDelegates: const [
        AppStrings.delegate,
        ...GlobalMaterialLocalizations.delegates,
      ],
      theme: dark ? AppTheme.dark() : AppTheme.light(),
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
          child: Scaffold(
            body: SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: GoalTopology(goal: goal),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  test(
    'explicit in-progress milestone does not count as completed progress',
    () async {
      final goal = await example();
      expect(goal.progress, .68);
      expect(goal.milestones.map((m) => m.status), [
        MilestoneStatus.completed,
        MilestoneStatus.completed,
        MilestoneStatus.completed,
        MilestoneStatus.active,
        MilestoneStatus.pending,
      ]);
      expect(goal.milestones[3].completed, isFalse);
      expect(
        const Milestone('Not started', weight: 10).status,
        MilestoneStatus.pending,
      );
    },
  );

  testWidgets(
    'graph keeps goal branches and milestone order without node popups',
    (tester) async {
      final goal = await example();
      await graphApp(tester, goal);
      final context = tester.element(find.byType(GoalTopology));
      final layout = GoalTopologyLayout.create(context, goal);
      final r = layout.rects;
      expect(r['delivery']!.bottom, lessThan(r['acceptance']!.top));
      expect(r['acceptance']!.right, lessThan(r['phase']!.left));
      expect(r['milestones']!.top, greaterThan(r['phase']!.bottom));
      expect(r['milestone-0']!.top, greaterThan(r['milestones']!.bottom));
      for (var i = 0; i < goal.milestones.length - 1; i++) {
        expect(
          r['milestone-$i']!.right,
          lessThan(r['milestone-${i + 1}']!.left),
        );
      }
      for (final rect in r.values) {
        expect((Offset.zero & layout.size).contains(rect.center), isTrue);
        expect(rect.bottom, lessThanOrEqualTo(layout.size.height));
      }
      expect(find.byType(Animate), findsOneWidget);
      await tester.ensureVisible(
        find.byKey(const ValueKey('goal-topology-node-milestone-3')),
      );
      await tester.tap(
        find.byKey(const ValueKey('goal-topology-node-milestone-3')),
      );
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsNothing);
      expect(find.byType(Dialog), findsNothing);
      expect(find.text(goal.milestones[3].title), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    testWidgets(
      'goal map supports dark English and large text on $platform',
      (tester) async {
        tester.view.physicalSize = const Size(320, 740);
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.textScaleFactorTestValue = 2;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        final goal = await example();
        await graphApp(tester, goal, reduced: true, english: true, dark: true);
        expect(find.byType(Animate), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.tap(find.byKey(const ValueKey('goal-topology-expand')));
        await tester.pumpAndSettle();
        expect(find.text('Goal map'), findsOneWidget);
        expect(find.byType(InteractiveViewer), findsOneWidget);
        final viewer = tester.widget<InteractiveViewer>(
          find.byType(InteractiveViewer),
        );
        final before = viewer.transformationController!.value
            .getMaxScaleOnAxis();
        final center = tester.getCenter(find.byType(InteractiveViewer));
        final a = await tester.startGesture(
          center - const Offset(30, 0),
          pointer: 1,
        );
        final b = await tester.startGesture(
          center + const Offset(30, 0),
          pointer: 2,
        );
        await a.moveBy(const Offset(-40, 0));
        await b.moveBy(const Offset(40, 0));
        await tester.pump();
        await a.up();
        await b.up();
        await tester.pumpAndSettle();
        expect(
          viewer.transformationController!.value.getMaxScaleOnAxis(),
          greaterThan(before),
        );
        await tester.tap(find.byKey(const ValueKey('goal-topology-reset')));
        await tester.pumpAndSettle();
        expect(
          viewer.transformationController!.value.getMaxScaleOnAxis(),
          closeTo(before, .001),
        );
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant({platform}),
    );
  }

  testWidgets('empty and long goal content is measured without overflow', (
    tester,
  ) async {
    final goal = await example();
    final long = ProgressGoal(
      id: 'long',
      title: goal.title,
      code: goal.code,
      phase: 'This is a longer current stage description',
      condition: List.filled(18, '双端测试并部署至客户环境').join('，'),
      acceptance: List.filled(12, 'Acceptance must be reviewed').join(' '),
      deadline: goal.deadline,
      status: goal.status,
      milestones: const [],
      history: [],
    );
    await graphApp(tester, long, english: true);
    final layout = GoalTopologyLayout.create(
      tester.element(find.byType(GoalTopology)),
      long,
    );
    expect(layout.nodes.length, 4);
    expect(
      layout.rects['delivery']!.bottom,
      lessThan(layout.rects['phase']!.top),
    );
    expect(tester.takeException(), isNull);
  });
}
