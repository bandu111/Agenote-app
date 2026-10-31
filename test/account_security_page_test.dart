import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:yanshu/app/l10n/app_strings.dart';
import 'package:yanshu/features/auth/repositories/auth_repository.dart';
import 'package:yanshu/features/auth/viewmodels/auth_view_model.dart';
import 'package:yanshu/features/profile/repositories/profile_repository.dart';
import 'package:yanshu/features/profile/viewmodels/profile_view_model.dart';
import 'package:yanshu/features/profile/views/profile_security.dart';
import 'package:yanshu/features/progress/viewmodels/voice_evidence_controller.dart';

class SecurityFake implements SessionAuthRepository, AccountSecurityRepository {
  int changes = 0, deletions = 0;
  @override
  bool authenticated = true;
  @override
  set onSessionExpired(void Function()? value) {}
  @override
  Future<AuthIdentity?> restore() async => null;
  @override
  Future<AuthIdentity> login(String email, String password) async =>
      const AuthIdentity(email: 'qa@example.com');
  @override
  Future<AuthIdentity> register(String name, String email, String password) =>
      login(email, password);
  @override
  Future<void> logout() async {
    authenticated = false;
  }

  @override
  Future<void> changePassword(
    String currentPassword,
    String newPassword,
  ) async {
    changes++;
    authenticated = false;
  }

  @override
  Future<void> deleteAccount(String currentPassword) async {
    deletions++;
    authenticated = false;
  }
}

Future<void> open(
  WidgetTester tester,
  SecurityFake repository, {
  bool english = false,
  TargetPlatform platform = TargetPlatform.android,
}) async {
  final profile = ProfileViewModel(
    repository: ProfileRepository(MemoryProfileStore()),
  );
  await profile.load();
  final auth = AuthViewModel(repository, profile);
  final voice = VoiceEvidenceController();
  addTearDown(profile.dispose);
  addTearDown(auth.dispose);
  addTearDown(voice.dispose);
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: auth),
        ChangeNotifierProvider.value(value: voice),
      ],
      child: MaterialApp(
        theme: ThemeData.dark().copyWith(platform: platform),
        locale: Locale(english ? 'en' : 'zh'),
        supportedLocales: const [Locale('en'), Locale('zh')],
        localizationsDelegates: const [
          AppStrings.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
        ],
        home: const ProfileSecurityPage(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('改密前验证重复密码，注销必须二次确认', (tester) async {
    final repo = SecurityFake();
    await open(tester, repo);
    await tester.enterText(
      find.byType(TextFormField).at(0),
      'current-password',
    );
    await tester.enterText(find.byType(TextFormField).at(1), 'new-password');
    await tester.enterText(
      find.byType(TextFormField).at(2),
      'different-password',
    );
    await tester.ensureVisible(find.widgetWithText(FilledButton, '修改密码'));
    await tester.tap(find.widgetWithText(FilledButton, '修改密码'));
    await tester.pumpAndSettle();
    expect(find.text('两次密码不一致'), findsOneWidget);
    expect(repo.changes, 0);
    await tester.ensureVisible(find.widgetWithText(OutlinedButton, '注销账户'));
    await tester.tap(find.widgetWithText(OutlinedButton, '注销账户'));
    await tester.pumpAndSettle();
    expect(find.text('是否注销账户？'), findsOneWidget);
    expect(repo.deletions, 0);
    await tester.tap(find.widgetWithText(FilledButton, '取消'));
    await tester.pumpAndSettle();
    expect(repo.deletions, 0);
    expect(tester.takeException(), isNull);
  });
  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    testWidgets('账户安全英文暗色大字布局 $platform', (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await open(tester, SecurityFake(), english: true, platform: platform);
      await tester.enterText(
        find.byType(TextFormField).first,
        'current-password',
      );
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.widgetWithText(OutlinedButton, 'Delete account'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.widgetWithText(OutlinedButton, 'Delete account'),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(OutlinedButton, 'Delete account'));
      await tester.pumpAndSettle();
      expect(find.text('Delete your account?'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
