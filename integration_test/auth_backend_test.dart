import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yanshu/app/app.dart';
import 'package:yanshu/core/network/api_client.dart';
import 'package:yanshu/core/network/api_config.dart';
import 'package:yanshu/features/auth/repositories/dio_auth_repository.dart';
import 'package:yanshu/features/auth/services/session_store.dart';
import 'package:yanshu/features/knowledge/repositories/knowledge_repository.dart';
import 'package:yanshu/features/meeting/meeting_store.dart';
import 'package:yanshu/features/profile/repositories/profile_repository.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('USB 真机验证注册、恢复、刷新、错误密码及退出', (tester) async {
    const email = String.fromEnvironment('YANSHU_SMOKE_EMAIL');
    expect(email.startsWith('usb-auth-'), isTrue);
    const password = 'Usb-Integration-Only-2026!';
    final baseUrl = ApiConfig.baseUrl;
    // 原生安全存储使用独立测试命名空间，不读取或覆盖用户账户令牌。
    final store = SecureSessionStore('$baseUrl#usb-integration');
    await store.clear();
    final profiles = ProfileRepository(
      MemoryProfileStore(),
      initialSessionActive: false,
    );
    var repo = DioAuthRepository(ApiClient(baseUrl: baseUrl), store);

    Future<void> waitFor(Finder finder) async {
      final watch = Stopwatch()..start();
      while (finder.evaluate().isEmpty &&
          watch.elapsed < const Duration(seconds: 35)) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      expect(finder, findsOneWidget);
    }

    Future<void> tap(Finder finder) async {
      if (finder.evaluate().isEmpty) {
        await tester.scrollUntilVisible(
          finder,
          240,
          scrollable: find.byType(Scrollable).first,
        );
      }
      await tester.ensureVisible(finder);
      await tester.tap(finder);
      await tester.pump(const Duration(milliseconds: 300));
    }

    Widget app({String location = '/register'}) => YanShuApp(
      key: UniqueKey(),
      initialLocation: location,
      authRepository: repo,
      profileRepository: profiles,
      knowledgeRepository: KnowledgeRepository(MemoryKnowledgeStore()),
      meetingStore: MemoryMeetingStore(),
    );

    try {
      await tester.pumpWidget(app());
      await waitFor(find.byKey(const ValueKey('register-page')));
      await tester.enterText(find.byKey(const ValueKey('auth-name')), 'USB联调');
      await tester.enterText(find.byKey(const ValueKey('auth-email')), email);
      await tester.enterText(
        find.byKey(const ValueKey('auth-password')),
        password,
      );
      await tester.enterText(
        find.byKey(const ValueKey('auth-confirmation')),
        password,
      );
      await tap(find.byKey(const ValueKey('auth-submit')));
      await waitFor(find.byType(NavigationBar));
      final saved = await profiles.load();
      expect(saved.name, 'USB联调');
      expect(saved.email, email);
      final stored = jsonDecode((await store.read())!) as Map<String, dynamic>;
      expect(stored.containsKey('password'), isFalse);

      // 仅使测试记录中的访问令牌失效，验证真实后端刷新和原生持久化恢复。
      stored['access_token'] = 'expired-integration-access-token';
      await store.write(jsonEncode(stored));
      repo = DioAuthRepository(ApiClient(baseUrl: baseUrl), store);
      final restored = await repo.restore();
      expect(restored?.id, saved.accountId);
      expect(
        (jsonDecode((await store.read())!) as Map)['access_token'],
        isNot('expired-integration-access-token'),
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(app(location: '/home'));
      await waitFor(find.byType(NavigationBar));
      await tap(find.text('我的'));
      await waitFor(find.byKey(const ValueKey('profile-edit')));
      await tap(find.byKey(const ValueKey('profile-logout')));
      await tap(find.widgetWithText(FilledButton, '退出'));
      await waitFor(find.byKey(const ValueKey('login-page')));
      expect(await store.read(), isNull);

      await tester.enterText(find.byKey(const ValueKey('auth-email')), email);
      await tester.enterText(
        find.byKey(const ValueKey('auth-password')),
        'wrong-password',
      );
      await tap(find.byKey(const ValueKey('auth-submit')));
      await waitFor(find.byKey(const ValueKey('auth-error')));
      expect(find.text('邮箱或密码不正确'), findsOneWidget);
      // 真机绑定缓存了同一输入框，提交失焦后需重新建立测试输入连接。
      tester.binding.focusedEditable = null;
      await tester.enterText(
        find.byKey(const ValueKey('auth-password')),
        password,
      );
      await tester.pump(const Duration(milliseconds: 500));
      expect(
        tester
                .widget<TextFormField>(
                  find.byKey(const ValueKey('auth-password')),
                )
                .controller!
                .text ==
            password,
        isTrue,
        reason: '正确密码应已写入输入框',
      );
      expect(
        tester
                .widget<TextFormField>(find.byKey(const ValueKey('auth-email')))
                .controller!
                .text ==
            email,
        isTrue,
        reason: '再次填写密码时应保留原邮箱',
      );
      await tap(find.byKey(const ValueKey('auth-submit')));
      await waitFor(find.byType(NavigationBar));
      await repo.logout();
      binding.reportData = {
        'auth_backend': 'passed',
        'secure_storage': 'passed',
        'refresh_and_restore': 'passed',
        'logout': 'passed',
        'real_device': 'Android',
      };
    } finally {
      await store.clear();
    }
  });
}
