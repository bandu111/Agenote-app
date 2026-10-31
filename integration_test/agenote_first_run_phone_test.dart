import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:yanshu/features/auth/views/account_bootstrap.dart';
import 'package:yanshu/features/auth/repositories/auth_repository.dart';
import 'package:yanshu/features/auth/repositories/dio_auth_repository.dart';
import 'package:yanshu/features/auth/services/session_store.dart';
import 'package:yanshu/core/network/api_client.dart';
import 'package:yanshu/core/network/api_config.dart';
import 'package:yanshu/features/first_run/first_run_store.dart';
import 'package:yanshu/features/first_run/onboarding_page.dart';
import 'package:yanshu/features/profile/repositories/profile_repository.dart';
import 'package:yanshu/features/knowledge/repositories/knowledge_repository.dart';
import 'package:yanshu/features/meeting/meeting_store.dart';

class _Auth implements SessionAuthRepository {
  @override
  bool get authenticated => false;
  @override
  Future<AuthIdentity?> restore() async => null;
  @override
  set onSessionExpired(void Function()? value) {}
  @override
  Future<void> logout() async {}
  @override
  Future<AuthIdentity> login(String email, String password) async =>
      throw UnimplementedError();
  @override
  Future<AuthIdentity> register(
    String name,
    String email,
    String password,
  ) async => throw UnimplementedError();
}

Future<void> hostCapture(String name, List<int> bytes) async {
  final http = HttpClient();
  try {
    final request = await http.postUrl(
      Uri.parse('http://127.0.0.1:18774/qa/capture/$name'),
    );
    request.add(bytes);
    final response = await request.close();
    if (response.statusCode != 200) throw StateError('Local QA capture failed');
    await response.drain<void>();
  } finally {
    http.close(force: true);
  }
}

class _MemorySession implements SessionStore {
  String? value;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String s) async {
    value = s;
  }

  @override
  Future<void> clear() async {
    value = null;
  }
}

class _Seen implements FirstRunStore {
  @override
  Future<bool> completed() async => true;
  @override
  Future<void> complete() async {}
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  testWidgets(
    'Agenote real phone local assets, swipe, completion and persisted restart',
    (t) async {
      if (!const bool.fromEnvironment('YANSHU_INTEGRATION_TEST')) {
        throw StateError('Isolated test package required');
      }
      const flags = SecureFirstRunStore();
      final previous = await flags.storage.read(key: SecureFirstRunStore.key);
      final dir = await getApplicationSupportDirectory();
      Future<void> capture(String name) async {
        final boundary = t.renderObject<RenderRepaintBoundary>(
          find.byKey(const ValueKey('phone-first-run')),
        );
        final im = await boundary.toImage(pixelRatio: 1);
        final bytes = await im.toByteData(format: ui.ImageByteFormat.png);
        await File(
          '${dir.path}/agenote-$name.png',
        ).writeAsBytes(bytes!.buffer.asUint8List());
        im.dispose();
        if (const bool.fromEnvironment('AGENOTE_CAPTURE_HOST')) {
          await hostCapture(name, bytes.buffer.asUint8List());
        }
      }

      Widget app() => RepaintBoundary(
        key: const ValueKey('phone-first-run'),
        child: AccountBootstrap(
          auth: _Auth(),
          firstRunStore: flags,
          profiles: ProfileRepository(
            MemoryProfileStore(),
            initialSessionActive: false,
          ),
          knowledgeRepository: KnowledgeRepository(MemoryKnowledgeStore()),
          meetingStore: MemoryMeetingStore(),
        ),
      );
      try {
        await flags.storage.delete(key: SecureFirstRunStore.key);
        await t.pumpWidget(app());
        await t.pumpAndSettle();
        await t.pump(const Duration(seconds: 1));
        expect(find.text('01 / 03'), findsOneWidget);
        await capture('onboarding-1');
        await t.drag(find.byType(PageView), const Offset(-350, 0));
        await t.pumpAndSettle();
        expect(find.text('02 / 03'), findsOneWidget);
        await capture('onboarding-2');
        await t.tap(find.byKey(const ValueKey('onboarding-dot-2')));
        await t.pumpAndSettle();
        expect(find.text('03 / 03'), findsOneWidget);
        await capture('onboarding-3');
        await t.tap(find.text('开始使用'));
        await t.pumpAndSettle();
        expect(await flags.completed(), isTrue);
        expect(find.text('邮箱登录'), findsOneWidget);
        await capture('login-handoff');
        expect(find.byKey(const ValueKey('profile-resume')), findsNothing);
        expect(find.text('填入演示账号'), findsNothing);
        await t.ensureVisible(find.byKey(const ValueKey('auth-switch')));
        await t.tap(find.byKey(const ValueKey('auth-switch')));
        await t.pumpAndSettle();
        expect(find.byKey(const ValueKey('auth-name')), findsOneWidget);
        expect(find.byKey(const ValueKey('auth-confirmation')), findsOneWidget);
        await capture('register');
        await t.ensureVisible(find.byKey(const ValueKey('auth-submit')));
        await t.tap(find.byKey(const ValueKey('auth-submit')));
        await t.pumpAndSettle();
        expect(find.text('请输入昵称'), findsOneWidget);
        expect(find.text('请输入有效邮箱'), findsOneWidget);
        await t.ensureVisible(find.byKey(const ValueKey('auth-switch')));
        await t.tap(find.byKey(const ValueKey('auth-switch')));
        await t.pumpAndSettle();

        await t.pumpWidget(const SizedBox());
        await t.pumpAndSettle();
        await t.pumpWidget(app());
        await t.pumpAndSettle();
        expect(find.byType(OnboardingPage), findsNothing);
        expect(find.text('邮箱登录'), findsOneWidget);
        expect(t.takeException(), isNull);
        binding.reportData = {
          'passed': true,
          'realSecureStorage': true,
          'recordingStarted': false,
          'screenshotsDirectory': dir.path,
        };
      } finally {
        if (previous == null) {
          await flags.storage.delete(key: SecureFirstRunStore.key);
        } else {
          await flags.storage.write(
            key: SecureFirstRunStore.key,
            value: previous,
          );
        }
      }
    },
  );
  if (const String.fromEnvironment('AGENOTE_RECOVERY_QA_URL').isNotEmpty) {
    testWidgets(
      'real phone -> actual HTTP registered-email recovery -> new password login',
      (t) async {
        final api = ApiClient(
          baseUrl: const String.fromEnvironment('AGENOTE_RECOVERY_QA_URL'),
        );
        final email = 'qa-${DateTime.now().millisecondsSinceEpoch}@example.com';
        await api.post(
          'auth/register',
          data: {'name': 'QA', 'email': email, 'password': 'old-password-42'},
        );
        final auth = DioAuthRepository(api, _MemorySession());
        await t.pumpWidget(
          RepaintBoundary(
            key: const ValueKey('phone-recovery'),
            child: AccountBootstrap(
              auth: auth,
              firstRunStore: _Seen(),
              profiles: ProfileRepository(
                MemoryProfileStore(),
                initialSessionActive: false,
              ),
              knowledgeRepository: KnowledgeRepository(MemoryKnowledgeStore()),
              meetingStore: MemoryMeetingStore(),
            ),
          ),
        );
        await t.pumpAndSettle();
        Future<void> tap(Finder f) async {
          await t.ensureVisible(f);
          await t.tap(f);
          await t.pumpAndSettle();
        }

        Future<void> shot(String name) async {
          final boundary = t.renderObject<RenderRepaintBoundary>(
            find.byKey(const ValueKey('phone-recovery')),
          );
          final im = await boundary.toImage(pixelRatio: 1);
          final bytes = await im.toByteData(format: ui.ImageByteFormat.png);
          await hostCapture(name, bytes!.buffer.asUint8List());
          im.dispose();
        }

        await tap(find.text('忘记密码？'));
        await shot('recovery-email');
        await t.enterText(find.byKey(const ValueKey('recovery-email')), email);
        await tap(find.byKey(const ValueKey('recovery-submit')));
        expect(find.text('账号已找到。'), findsOneWidget);
        await shot('recovery-found');
        await tap(find.text('重置密码'));
        await t.enterText(
          find.byKey(const ValueKey('recovery-password')),
          'new-password-42',
        );
        await t.enterText(
          find.byKey(const ValueKey('recovery-confirmation')),
          'new-password-42',
        );
        await shot('recovery-new-password');
        await tap(find.byKey(const ValueKey('recovery-submit')));
        expect(find.text('密码已重置。'), findsOneWidget);
        await shot('recovery-success');
        await tap(find.text('返回登录'));
        await t.enterText(find.byKey(const ValueKey('auth-email')), email);
        await t.enterText(
          find.byKey(const ValueKey('auth-password')),
          'new-password-42',
        );
        await tap(find.byKey(const ValueKey('auth-submit')));
        expect(find.byType(NavigationBar), findsOneWidget);
        expect(auth.authenticated, isTrue);
        await expectLater(
          api.post(
            'auth/login',
            data: {'email': email, 'password': 'old-password-42'},
          ),
          throwsA(isA<ApiFailure>()),
        );
        expect(t.takeException(), isNull);
        await t.pumpWidget(const SizedBox());
        await t.pumpAndSettle();
        api.dio.close(force: true);
      },
    );
  }
}
