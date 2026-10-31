import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:yanshu/app/app.dart';
import 'package:yanshu/features/auth/repositories/auth_repository.dart';
import 'package:yanshu/features/auth/viewmodels/auth_view_model.dart';
import 'package:yanshu/features/profile/repositories/profile_repository.dart';
import 'package:yanshu/features/knowledge/repositories/knowledge_repository.dart';
import 'package:yanshu/features/meeting/meeting_store.dart';

class WaitingAuthRepository implements AuthRepository {
  int calls = 0;
  final result = Completer<AuthIdentity>();
  @override
  Future<AuthIdentity> login(String email, String password) {
    calls++;
    return result.future;
  }

  @override
  Future<AuthIdentity> register(String name, String email, String password) =>
      login(email, password);
}

Future<MemoryProfileStore> openAuth(
  WidgetTester tester, {
  String location = '/login',
  AuthRepository? repository,
  String appearance = 'light',
  String language = 'zh',
}) async {
  final store = MemoryProfileStore();
  final profile = ProfileRepository(store, initialSessionActive: false);
  final data = await profile.load();
  await profile.save(data.copyWith(appearance: appearance, language: language));
  await tester.pumpWidget(
    YanShuApp(
      initialLocation: location,
      authRepository: repository,
      profileRepository: profile,
      knowledgeRepository: KnowledgeRepository(
        MemoryKnowledgeStore(),
        seedExamples: true,
      ),
      meetingStore: MemoryMeetingStore(),
    ),
  );
  await tester.pumpAndSettle();
  return store;
}

Future<void> tapVisible(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'an injected account response opens home and saves identity without password',
    (tester) async {
      final repository = WaitingAuthRepository();
      final store = await openAuth(tester, repository: repository);
      await tester.enterText(
        find.byKey(const ValueKey('auth-email')),
        'yan@example.com',
      );
      await tester.enterText(
        find.byKey(const ValueKey('auth-password')),
        'example-password',
      );
      await tapVisible(tester, find.byTooltip('显示密码'));
      expect(
        tester
            .widget<TextField>(
              find.descendant(
                of: find.byKey(const ValueKey('auth-password')),
                matching: find.byType(TextField),
              ),
            )
            .obscureText,
        isFalse,
      );
      final button = find.byKey(const ValueKey('auth-submit'));
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pump();
      repository.result.complete(
        const AuthIdentity(email: 'yan@example.com', name: '言言'),
      );
      await tester.pumpAndSettle();
      expect(find.byType(NavigationBar), findsOneWidget);
      final profile = await ProfileRepository(store).load();
      expect(profile.name, '言言');
      expect(profile.email, 'yan@example.com');
      expect(profile.sessionActive, isTrue);
      expect(store.value, isNot(contains('example-password')));
    },
  );

  testWidgets(
    'protected links redirect to sign in; local bypass and demo account are absent',
    (tester) async {
      final store = await openAuth(
        tester,
        location: '/knowledge/documents/private',
      );
      expect(find.byKey(const ValueKey('login-page')), findsOneWidget);
      expect(find.byType(NavigationBar), findsNothing);
      expect(find.byKey(const ValueKey('profile-resume')), findsNothing);
      expect(find.text('先体验本机模式'), findsNothing);
      expect(find.text('本机体验无需账户，资料保留在这台设备上。'), findsNothing);
      expect(find.text('填入演示账号'), findsNothing);
      expect((await ProfileRepository(store).load()).sessionActive, isFalse);
    },
  );

  testWidgets(
    'registration validates email, password and confirmation; never fabricates remote success',
    (tester) async {
      final store = await openAuth(tester);
      await tapVisible(tester, find.byKey(const ValueKey('auth-switch')));
      expect(find.byKey(const ValueKey('register-page')), findsOneWidget);
      await tapVisible(tester, find.byKey(const ValueKey('auth-submit')));
      expect(find.text('请输入昵称'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('auth-name')), '言言');
      await tester.enterText(
        find.byKey(const ValueKey('auth-email')),
        'yan@example.com',
      );
      await tester.enterText(
        find.byKey(const ValueKey('auth-password')),
        'example-password-42',
      );
      await tester.enterText(
        find.byKey(const ValueKey('auth-confirmation')),
        'different',
      );
      await tapVisible(tester, find.byKey(const ValueKey('auth-submit')));
      expect(find.text('两次输入的密码不一致'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('auth-confirmation')),
        'example-password-42',
      );
      await tapVisible(tester, find.byKey(const ValueKey('auth-submit')));
      expect(find.text('账户服务暂不可用，请稍后重试'), findsOneWidget);
      expect(find.byType(NavigationBar), findsNothing);
      expect(store.value, isNot(contains('example-password-42')));
      expect((await ProfileRepository(store).load()).sessionActive, isFalse);
    },
  );

  testWidgets(
    'pending sign in prevents duplicate requests and reports service failure without persisting secrets',
    (tester) async {
      final repository = WaitingAuthRepository();
      final store = await openAuth(tester, repository: repository);
      await tester.enterText(
        find.byKey(const ValueKey('auth-email')),
        'yan@example.com',
      );
      await tester.enterText(
        find.byKey(const ValueKey('auth-password')),
        'private-password',
      );
      final button = find.byKey(const ValueKey('auth-submit'));
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pump();
      final vm = tester.element(button).read<AuthViewModel>();
      expect(tester.widget<FilledButton>(button).onPressed, isNull);
      expect(
        await vm.submit(
          register: false,
          email: 'yan@example.com',
          password: 'again',
        ),
        isFalse,
      );
      expect(repository.calls, 1);
      repository.result.completeError(StateError('offline'));
      await tester.pumpAndSettle();
      expect(find.text('暂时无法连接账户服务，请稍后重试'), findsOneWidget);
      expect(store.value, isNot(contains('private-password')));
      expect(find.byKey(const ValueKey('login-page')), findsOneWidget);
    },
  );

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    testWidgets(
      'auth forms fit dark English small screens with keyboard and large text on $platform',
      (tester) async {
        tester.view.physicalSize = const Size(320, 640);
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.textScaleFactorTestValue = 2;
        tester.view.viewInsets = const FakeViewPadding(bottom: 220);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetViewInsets);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        await openAuth(tester, appearance: 'dark', language: 'en');
        expect(find.text('Welcome back'), findsOneWidget);
        expect(find.widgetWithText(FilledButton, 'Sign in'), findsOneWidget);
        await tapVisible(tester, find.byKey(const ValueKey('auth-switch')));
        expect(find.text('Create your account'), findsOneWidget);
        await tapVisible(tester, find.byKey(const ValueKey('auth-submit')));
        expect(find.text('Passwords do not match'), findsNothing);
        // iOS Form's accessibility announcement runs one second after validation.
        await tester.pump(const Duration(seconds: 2));
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant({platform}),
    );
  }
}
