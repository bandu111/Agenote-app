import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dio/dio.dart';
import 'package:yanshu/core/network/api_client.dart';
import 'package:yanshu/core/network/api_config.dart';
import 'package:yanshu/features/auth/repositories/auth_repository.dart';
import 'package:yanshu/features/auth/repositories/dio_auth_repository.dart';
import 'auth_page_test.dart' as harness;
import 'dio_auth_repository_test.dart'
    show TestAdapter, MemorySessionStore, envelope;

class RecoveryFake extends harness.WaitingAuthRepository
    implements PasswordRecoveryRepository {
  bool found = true, offline = false;
  int lookups = 0, resets = 0;
  String? saved;
  @override
  Future<RecoveryAccount> lookupRegisteredEmail(String email) async {
    lookups++;
    if (offline) throw const ApiFailure('网络不可用，请重试');
    return RecoveryAccount(
      found: found,
      resetToken: found ? 'query-token' : null,
    );
  }

  @override
  Future<void> resetDemoPassword(
    String email,
    String token,
    String password,
  ) async {
    resets++;
    if (offline) throw const ApiFailure('网络不可用，请重试');
    saved = password;
  }
}

Future<void> open(WidgetTester t, RecoveryFake repo) async {
  await harness.openAuth(t, repository: repo);
  await harness.tapVisible(t, find.text('忘记密码？'));
}

Future<void> lookup(WidgetTester t) async {
  await t.enterText(
    find.byKey(const ValueKey('recovery-email')),
    'yan@example.com',
  );
  await harness.tapVisible(t, find.byKey(const ValueKey('recovery-submit')));
}

void main() {
  testWidgets(
    'registered lookup -> reset -> existing sign in, errors never report success',
    (t) async {
      final repo = RecoveryFake()..found = false;
      await open(t, repo);
      await harness.tapVisible(
        t,
        find.byKey(const ValueKey('recovery-submit')),
      );
      expect(find.text('请输入有效邮箱'), findsOneWidget);
      expect(repo.lookups, 0);
      await lookup(t);
      expect(find.text('这个邮箱还没有 Agenote 账号'), findsOneWidget);
      repo.found = true;
      await lookup(t);
      expect(find.text('账号已找到。'), findsOneWidget);
      expect(find.text('y***n@example.com'), findsOneWidget);
      await harness.tapVisible(t, find.text('重置密码'));
      await t.enterText(
        find.byKey(const ValueKey('recovery-password')),
        'abcdefgh',
      );
      await t.enterText(
        find.byKey(const ValueKey('recovery-confirmation')),
        'abcdefgh',
      );
      await harness.tapVisible(
        t,
        find.byKey(const ValueKey('recovery-submit')),
      );
      expect(find.text('密码需要包含至少1个数字'), findsOneWidget);
      expect(repo.resets, 0);
      await t.enterText(
        find.byKey(const ValueKey('recovery-password')),
        'new-password-42',
      );
      await t.enterText(
        find.byKey(const ValueKey('recovery-confirmation')),
        'other',
      );
      await harness.tapVisible(
        t,
        find.byKey(const ValueKey('recovery-submit')),
      );
      expect(find.text('两次输入的密码不一致'), findsOneWidget);
      await t.enterText(
        find.byKey(const ValueKey('recovery-confirmation')),
        'new-password-42',
      );
      repo.offline = true;
      await harness.tapVisible(
        t,
        find.byKey(const ValueKey('recovery-submit')),
      );
      expect(find.text('网络不可用，请重试'), findsOneWidget);
      expect(find.text('密码已重置。'), findsNothing);
      repo.offline = false;
      await harness.tapVisible(
        t,
        find.byKey(const ValueKey('recovery-submit')),
      );
      expect(repo.saved, 'new-password-42');
      expect(find.text('密码已重置。'), findsOneWidget);
      await harness.tapVisible(t, find.text('返回登录'));
      expect(find.byKey(const ValueKey('login-page')), findsOneWidget);
      expect(find.byType(NavigationBar), findsNothing);
      expect(t.takeException(), isNull);
    },
  );
  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    testWidgets(
      'recovery narrow dark, keyboard and large font $platform',
      (t) async {
        t.view.physicalSize = const Size(320, 640);
        t.view.devicePixelRatio = 1;
        t.platformDispatcher.textScaleFactorTestValue = 2;
        t.view.viewInsets = const FakeViewPadding(bottom: 220);
        addTearDown(t.view.resetPhysicalSize);
        addTearDown(t.view.resetDevicePixelRatio);
        addTearDown(t.view.resetViewInsets);
        addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
        await harness.openAuth(
          t,
          repository: RecoveryFake(),
          appearance: 'dark',
        );
        await harness.tapVisible(t, find.text('忘记密码？'));
        await lookup(t);
        await harness.tapVisible(t, find.text('重置密码'));
        await harness.tapVisible(
          t,
          find.byKey(const ValueKey('recovery-submit')),
        );
        await t.pump(const Duration(seconds: 2));
        expect(t.takeException(), isNull);
      },
      variant: TargetPlatformVariant({platform}),
    );
  }
  test(
    'Dio recovery uses actual unauthenticated contract and never saves token or password',
    () async {
      final requests = <RequestOptions>[];
      final storage = MemorySessionStore();
      final repo = DioAuthRepository(
        ApiClient(
          baseUrl: 'https://test/api/v1/',
          dio: Dio()
            ..httpClientAdapter = TestAdapter((r) async {
              requests.add(r);
              return (
                200,
                envelope(
                  r.path.endsWith('lookup')
                      ? {
                          'found': true,
                          'reset_token': 'short-lived-query-token',
                        }
                      : null,
                ),
              );
            }),
        ),
        storage,
      );
      final result = await repo.lookupRegisteredEmail(' YAN@EXAMPLE.COM ');
      expect(result.found, isTrue);
      await repo.resetDemoPassword(
        ' YAN@EXAMPLE.COM ',
        result.resetToken!,
        'new-password-42',
      );
      expect(requests.first.data, {'email': 'yan@example.com'});
      expect(requests.last.path, endsWith('/recovery/reset'));
      expect(requests.last.data['new_password'], 'new-password-42');
      expect(
        requests.every((r) => !r.headers.containsKey('Authorization')),
        isTrue,
      );
      expect(storage.value, isNull);
    },
  );
}
