import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:yanshu/features/home/viewmodels/home_view_model.dart';
import 'package:yanshu/features/home/views/weekly_rhythm_card.dart';
import 'package:yanshu/features/progress/widgets/progress_components.dart';
import 'profile_page_test.dart' as helpers;

void main() {
  testWidgets('目标进展切换真实底部Tab，并从双方承诺回到目标', (t) async {
    helpers.profilePhone(t);
    await helpers.openProfile(t);
    Future<void> home() async {
      await t.tap(
        find.descendant(
          of: find.byType(NavigationBar),
          matching: find.text('首页'),
        ),
      );
      await t.pumpAndSettle();
      await t.ensureVisible(find.byKey(const ValueKey('weekly-goal-progress')));
      await t.pumpAndSettle();
    }

    await home();
    await t.tap(find.byKey(const ValueKey('weekly-goal-progress')));
    await t.pumpAndSettle();
    expect(
      t.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
      1,
    );
    expect(
      t.widget<ProgressPills>(find.byType(ProgressPills).first).selected,
      0,
    );
    await t.tap(find.byKey(const ValueKey('progress-section-1')));
    await t.pumpAndSettle();
    await home();
    await t.tap(find.byKey(const ValueKey('weekly-goal-progress')));
    await t.pumpAndSettle();
    expect(
      t.widget<ProgressPills>(find.byType(ProgressPills).first).selected,
      0,
    );
    expect(t.takeException(), isNull);
  });
  testWidgets(
    'day selection reveals only selected statistics and toggles closed; goals uses tab route',
    (t) async {
      final home = HomeViewModel()
        ..data = {
          'weeklyRhythm': {
            'meetings': 9,
            'days': [
              {
                'date': '2030-10-28',
                'meetings': 2,
                'decisions': 1,
                'activeGoals': 3,
                'missingItems': 4,
                'pendingActions': 5,
              },
              {
                'date': '2030-10-29',
                'meetings': 7,
                'decisions': 2,
                'activeGoals': 6,
                'missingItems': 8,
                'pendingActions': 10,
              },
            ],
          },
        };
      addTearDown(home.dispose);
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (_, _) => const Scaffold(body: WeeklyRhythmCard()),
          ),
          GoRoute(
            path: '/affairs',
            builder: (_, s) =>
                Scaffold(body: Text('目标页 ${s.uri.queryParameters['section']}')),
          ),
        ],
      );
      addTearDown(router.dispose);
      await t.pumpWidget(
        ChangeNotifierProvider.value(
          value: home,
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await t.pumpAndSettle();
      expect(find.text('进行中目标'), findsNothing);
      expect(find.byType(VerticalDivider), findsNothing);
      expect(find.text('当前卡点'), findsNothing);
      expect(find.text('依据'), findsNothing);
      await t.tap(find.byKey(const ValueKey('weekly-bar-2030-10-28')));
      await t.pumpAndSettle();
      expect(find.text('进行中目标'), findsOneWidget);
      expect(find.byType(VerticalDivider), findsNWidgets(2));
      expect(find.text('3'), findsOneWidget);
      expect(find.text('5'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('weekly-bar-2030-10-29')));
      await t.pumpAndSettle();
      expect(find.text('6'), findsOneWidget);
      expect(find.text('10'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('weekly-bar-2030-10-29')));
      await t.pumpAndSettle();
      expect(find.text('进行中目标'), findsNothing);
      expect(find.byType(VerticalDivider), findsNothing);
      await t.tap(find.byKey(const ValueKey('weekly-goal-progress')));
      await t.pumpAndSettle();
      expect(find.text('目标页 goals'), findsOneWidget);
      expect(t.takeException(), isNull);
    },
  );
  testWidgets('empty stats, dark mode and large fonts remain usable', (
    t,
  ) async {
    t.view.physicalSize = const Size(320, 640);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    final home = HomeViewModel();
    addTearDown(home.dispose);
    await t.pumpWidget(
      ChangeNotifierProvider.value(
        value: home,
        child: MaterialApp(
          theme: ThemeData.dark(),
          home: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(2)),
            child: const Scaffold(
              body: SingleChildScrollView(child: WeeklyRhythmCard()),
            ),
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    expect(find.text('暂无本周统计'), findsOneWidget);
    expect(find.text('进行中目标'), findsNothing);
    expect(t.takeException(), isNull);
  });
}
