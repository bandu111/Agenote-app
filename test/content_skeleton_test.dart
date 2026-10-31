import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yanshu/shared/widgets/content_skeleton.dart';

void main() {
  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    testWidgets(
      'skeleton layouts fit narrow dark/reduced-motion screens on $platform',
      (tester) async {
        tester.view.physicalSize = const Size(280, 440);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        for (final layout in SkeletonLayout.values) {
          await tester.pumpWidget(
            MaterialApp(
              theme: ThemeData(brightness: Brightness.dark, platform: platform),
              home: MediaQuery(
                data: const MediaQueryData(
                  disableAnimations: true,
                  textScaler: TextScaler.linear(2),
                ),
                child: Scaffold(
                  body: ContentSkeleton(layout: layout, label: '正在加载测试内容'),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(find.byType(ShaderMask), findsNothing);
          expect(find.bySemanticsLabel('正在加载测试内容'), findsOneWidget);
          expect(tester.takeException(), isNull);
        }
      },
    );
  }
  testWidgets(
    'skeleton follows actual loading state and stops animating when hidden or removed',
    (tester) async {
      Widget page({bool loading = true, bool enabled = true}) => MaterialApp(
        home: Scaffold(
          body: TickerMode(
            enabled: enabled,
            child: loading ? const ContentSkeleton() : const Text('暂无资料'),
          ),
        ),
      );
      await tester.pumpWidget(page());
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(ShaderMask), findsOneWidget);
      await tester.pumpWidget(page(enabled: false));
      await tester.pumpAndSettle();
      expect(find.byType(ShaderMask), findsNothing);
      await tester.pumpWidget(page(loading: false));
      await tester.pumpAndSettle();
      expect(find.byType(ContentSkeleton), findsNothing);
      expect(find.text('暂无资料'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
