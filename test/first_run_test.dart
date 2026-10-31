import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yanshu/app/app.dart';
import 'package:yanshu/features/auth/views/account_bootstrap.dart';
import 'package:yanshu/features/auth/repositories/auth_repository.dart';
import 'package:yanshu/features/first_run/brand_splash.dart';
import 'package:yanshu/features/first_run/first_run_store.dart';
import 'package:yanshu/features/first_run/onboarding_page.dart';
import 'package:yanshu/features/profile/repositories/profile_repository.dart';
import 'package:yanshu/features/knowledge/repositories/knowledge_repository.dart';
import 'package:yanshu/features/meeting/meeting_store.dart';

class MemoryFirstRun implements FirstRunStore {
  bool done = false, failRead = false, failWrite = false;
  int writes = 0, reads = 0;
  Completer<void>? gate;
  @override
  Future<bool> completed() async {
    reads++;
    if (failRead) throw StateError('read');
    return done;
  }

  @override
  Future<void> complete() async {
    writes++;
    await gate?.future;
    if (failWrite) throw StateError('write');
    done = true;
  }
}

class BootstrapAuth implements SessionAuthRepository {
  BootstrapAuth({this.authenticated = false, this.gate});
  final Completer<void>? gate;
  @override
  bool authenticated;
  @override
  Future<AuthIdentity?> restore() async {
    await gate?.future;
    return authenticated
        ? const AuthIdentity(id: 'user', email: 'qa@example.com')
        : null;
  }

  @override
  set onSessionExpired(void Function()? value) {}
  @override
  Future<void> logout() async {
    authenticated = false;
  }

  @override
  Future<AuthIdentity> login(String email, String password) async =>
      const AuthIdentity(email: 'qa@example.com');
  @override
  Future<AuthIdentity> register(String name, String email, String password) =>
      login(email, password);
}

Future<void> mount(
  WidgetTester t, {
  double width = 402,
  double height = 874,
  double scale = 1,
  TargetPlatform platform = TargetPlatform.android,
  bool reduced = true,
  Brightness brightness = Brightness.light,
  Future<void> Function()? complete,
}) async {
  t.view.physicalSize = Size(width, height);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.resetPhysicalSize);
  addTearDown(t.view.resetDevicePixelRatio);
  await t.runAsync(() async {
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    for (final (family, path) in [
      ('InstrumentSans', 'assets/fonts/InstrumentSans.ttf'),
      ('AgenoteNotoSC', 'assets/fonts/NotoSansSC-Regular.ttf'),
      ('AgenoteNotoSC', 'assets/fonts/NotoSansSC-Medium-FirstRun.ttf'),
    ]) {
      await (FontLoader(family)..addFont(rootBundle.load(path))).load();
    }
  });
  await t.pumpWidget(
    MaterialApp(
      theme: ThemeData(platform: platform, brightness: brightness),
      home: MediaQuery(
        data: MediaQueryData(
          size: Size(width, height),
          textScaler: TextScaler.linear(scale),
          disableAnimations: reduced,
        ),
        child: RepaintBoundary(
          key: const ValueKey('first-run-capture'),
          child: OnboardingPage(onComplete: complete ?? () async {}),
        ),
      ),
    ),
  );
  await t.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 100)),
  );
  await t.pumpAndSettle();
}

Future<void> capture(WidgetTester t, String name) async {
  if (!const bool.fromEnvironment('FIRST_RUN_CAPTURE')) return;
  final boundary = t.renderObject<RenderRepaintBoundary>(
    find.byKey(const ValueKey('first-run-capture')),
  );
  await t.runAsync(() async {
    final im = await boundary.toImage(pixelRatio: 1);
    final bytes = await im.toByteData(format: ui.ImageByteFormat.png);
    final dir = Directory('build/first-run-qa');
    await dir.create(recursive: true);
    await File(
      '${dir.path}/$name.png',
    ).writeAsBytes(bytes!.buffer.asUint8List());
    im.dispose();
  });
}

Widget bootstrap(MemoryFirstRun flags, BootstrapAuth auth) => AccountBootstrap(
  auth: auth,
  profiles: ProfileRepository(
    MemoryProfileStore(),
    initialSessionActive: false,
  ),
  firstRunStore: flags,
  knowledgeRepository: KnowledgeRepository(MemoryKnowledgeStore()),
  meetingStore: MemoryMeetingStore(),
);
void main() {
  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized()
        .platformDispatcher
        .accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(
      disableAnimations: true,
    );
  });
  tearDown(
    () => TestWidgetsFlutterBinding.ensureInitialized().platformDispatcher
        .clearAccessibilityFeaturesTestValue(),
  );
  testWidgets(
    'swipe, dots, continue and back share one page state; three exact copy screens',
    (t) async {
      await mount(t);
      expect(find.text('01 / 03'), findsOneWidget);
      await capture(t, 'flutter-1');
      await t.drag(find.byType(PageView), const Offset(-340, 0));
      await t.pumpAndSettle();
      expect(find.text('02 / 03'), findsOneWidget);
      await capture(t, 'flutter-2');
      await t.binding.handlePopRoute();
      await t.pumpAndSettle();
      expect(find.text('01 / 03'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('onboarding-dot-2')));
      await t.pumpAndSettle();
      expect(find.text('03 / 03'), findsOneWidget);
      expect(find.text('开始使用'), findsOneWidget);
      expect(find.text('跳过'), findsNothing);
      await capture(t, 'flutter-3');
      await t.binding.handlePopRoute();
      await t.pumpAndSettle();
      expect(find.text('02 / 03'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('onboarding-next')));
      await t.pumpAndSettle();
      expect(find.text('03 / 03'), findsOneWidget);
      expect(t.takeException(), isNull);
    },
  );
  testWidgets('skip and rapid double tap write once; failure is retryable', (
    t,
  ) async {
    final flags = MemoryFirstRun()..gate = Completer<void>();
    await mount(t, complete: flags.complete);
    await t.tap(find.text('跳过'));
    await t.tap(find.byKey(const ValueKey('onboarding-next')));
    await t.pump();
    expect(flags.writes, 1);
    flags.gate!.complete();
    await t.pumpAndSettle();
    expect(flags.done, isTrue);
    await t.pumpWidget(const SizedBox());
    await t.pumpAndSettle();
    final failed = MemoryFirstRun()..failWrite = true;
    await mount(t, complete: failed.complete);
    await t.tap(find.text('跳过'));
    await t.pumpAndSettle();
    expect(find.text('引导状态未能保存，请重试'), findsOneWidget);
    expect(failed.done, isFalse);
    failed.failWrite = false;
    await t.tap(find.text('跳过'));
    await t.pumpAndSettle();
    expect(failed.done, isTrue);
  });
  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    for (final config in [
      (360.0, 640.0, 2.0),
      (402.0, 874.0, 1.0),
      (480.0, 760.0, 1.3),
      (740.0, 360.0, 1.0),
    ]) {
      testWidgets('layout $platform $config dark and reduced motion', (
        t,
      ) async {
        await mount(
          t,
          width: config.$1,
          height: config.$2,
          scale: config.$3,
          platform: platform,
          brightness: Brightness.dark,
        );
        for (var i = 0; i < 3; i++) {
          await t.tap(find.byKey(ValueKey('onboarding-dot-$i')));
          await t.pumpAndSettle();
          expect(t.takeException(), isNull);
          expect(find.byKey(const ValueKey('onboarding-next')), findsOneWidget);
          expect(
            find
                .byType(Image)
                .evaluate()
                .every((e) => (e.widget as Image).image is AssetImage),
            isTrue,
          );
        }
      });
    }
  }
  testWidgets(
    'initialization uses splash until actual auth restores, not timeout',
    (t) async {
      final gate = Completer<void>();
      final flags = MemoryFirstRun();
      await t.pumpWidget(bootstrap(flags, BootstrapAuth(gate: gate)));
      await t.pump(const Duration(seconds: 4));
      expect(find.byType(BrandSplash), findsOneWidget);
      expect(find.byType(OnboardingPage), findsNothing);
      gate.complete();
      await t.pumpAndSettle();
      expect(find.byType(OnboardingPage), findsOneWidget);
    },
  );
  testWidgets(
    'skip enters existing login and next startup bypasses onboarding',
    (t) async {
      final flags = MemoryFirstRun();
      await t.pumpWidget(bootstrap(flags, BootstrapAuth()));
      await t.pumpAndSettle();
      await t.tap(find.text('跳过'));
      await t.pumpAndSettle();
      expect(find.byType(YanShuApp), findsOneWidget);
      expect(find.text('邮箱登录'), findsOneWidget);
      expect(flags.writes, 1);
      await t.pumpWidget(const SizedBox());
      await t.pumpAndSettle();
      await t.pumpWidget(bootstrap(flags, BootstrapAuth()));
      await t.pumpAndSettle();
      expect(find.byType(OnboardingPage), findsNothing);
    },
  );
  testWidgets(
    'final CTA writes once and animated splash disposes without a timer',
    (t) async {
      final flags = MemoryFirstRun();
      await mount(t, complete: flags.complete);
      await t.tap(find.byKey(const ValueKey('onboarding-dot-2')));
      await t.pumpAndSettle();
      await t.tap(find.text('开始使用'));
      await t.tap(find.text('开始使用'));
      await t.pumpAndSettle();
      expect(flags.writes, 1);
      expect(flags.done, isTrue);
      await t.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(disableAnimations: false),
            child: RepaintBoundary(
              key: const ValueKey('first-run-capture'),
              child: const BrandSplash(),
            ),
          ),
        ),
      );
      await t.pump(const Duration(milliseconds: 800));
      await capture(t, 'flutter-splash');
      expect(find.text('记录会议，推进工作'), findsOneWidget);
      await t.pumpWidget(const SizedBox());
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
    },
  );
  testWidgets(
    'restored account bypasses onboarding even when flag storage fails',
    (t) async {
      final flags = MemoryFirstRun()..failRead = true;
      await t.pumpWidget(bootstrap(flags, BootstrapAuth(authenticated: true)));
      await t.pumpAndSettle();
      expect(find.byType(YanShuApp), findsOneWidget);
      expect(find.byType(OnboardingPage), findsNothing);
      expect(flags.reads, 0);
    },
  );
  testWidgets('flag read failure retries without losing login flow', (t) async {
    final flags = MemoryFirstRun()..failRead = true;
    await t.pumpWidget(bootstrap(flags, BootstrapAuth()));
    await t.pumpAndSettle();
    expect(find.text('首次使用状态读取失败，请重试'), findsOneWidget);
    flags.failRead = false;
    await t.tap(find.text('重试'));
    await t.pumpAndSettle();
    expect(find.byType(OnboardingPage), findsOneWidget);
  });
}
