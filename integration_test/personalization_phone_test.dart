import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:yanshu/app/router/app_router.dart';
import 'package:yanshu/core/network/api_client.dart';
import 'package:yanshu/features/auth/repositories/dio_auth_repository.dart';
import 'package:yanshu/features/auth/services/session_store.dart';
import 'package:yanshu/features/auth/viewmodels/auth_view_model.dart';
import 'package:yanshu/features/auth/views/auth_page.dart';
import 'package:yanshu/features/profile/repositories/profile_repository.dart';
import 'package:yanshu/features/profile/viewmodels/profile_view_model.dart';
import 'package:yanshu/features/personalization/personalization_page.dart';
import 'package:yanshu/features/personalization/personalization_controller.dart';

class _Sessions implements SessionStore {
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

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'real Android registration -> personalization cloud save -> restore -> complete',
    (t) async {
      final api = ApiClient(baseUrl: 'https://124.220.169.122/api/v1/');
      final auth = DioAuthRepository(api, _Sessions());
      final repo = ProfileRepository(
        MemoryProfileStore(),
        initialSessionActive: false,
        client: api,
      );
      final p = ProfileViewModel(repository: repo);
      await p.load();
      final vm = AuthViewModel(auth, p);
      final email =
          'personalization-phone-${DateTime.now().microsecondsSinceEpoch}@example.com';
      final password = 'Temporary-qa-${DateTime.now().millisecondsSinceEpoch}';
      GoRouter router() => GoRouter(
        initialLocation: '/register',
        refreshListenable: p,
        redirect: (_, s) => accountRedirect(p, s.uri.path),
        routes: [
          GoRoute(
            path: '/register',
            builder: (_, _) => const AuthPage(register: true),
          ),
          GoRoute(path: '/login', builder: (_, _) => const AuthPage()),
          GoRoute(
            path: '/personalization',
            builder: (_, _) => const PersonalizationPage(),
          ),
          GoRoute(
            path: '/home',
            builder: (_, _) =>
                const Scaffold(body: Text('Existing home destination')),
          ),
        ],
      );
      var routes = router();
      Widget app() => MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: p),
          ChangeNotifierProvider.value(value: vm),
        ],
        child: MaterialApp.router(
          routerConfig: routes,
          builder: (_, child) => RepaintBoundary(
            key: const ValueKey('phone-personalization'),
            child: child,
          ),
        ),
      );
      Future<void> settle() async {
        await t.pumpAndSettle();
      }

      Future<void> until(String text) async {
        for (var i = 0; i < 200; i++) {
          await t.pump(const Duration(milliseconds: 200));
          if (find.text(text).evaluate().isNotEmpty) {
            await settle();
            return;
          }
        }
        fail('Missing expected UI: $text');
      }

      Future<void> hideKeyboard() async {
        FocusManager.instance.primaryFocus?.unfocus();
        await SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
        for (var i = 0; i < 50; i++) {
          await t.pump(const Duration(milliseconds: 100));
          if (WidgetsBinding
                  .instance
                  .platformDispatcher
                  .views
                  .first
                  .viewInsets
                  .bottom ==
              0) {
            break;
          }
        }
        await t.pumpAndSettle();
        expect(
          WidgetsBinding
              .instance
              .platformDispatcher
              .views
              .first
              .viewInsets
              .bottom,
          0,
        );
      }

      Future<void> shot(String name) async {
        if (!const bool.fromEnvironment('PERSONALIZATION_PHONE_CAPTURE')) {
          return;
        }
        final boundary = t.renderObject<RenderRepaintBoundary>(
          find.byKey(const ValueKey('phone-personalization')),
        );
        final im = await boundary.toImage(pixelRatio: 1);
        final bytes = await im.toByteData(format: ui.ImageByteFormat.png);
        final client = HttpClient();
        try {
          final request = await client.postUrl(
            Uri.parse('http://127.0.0.1:18775/$name'),
          );
          request.contentLength = bytes!.lengthInBytes;
          request.add(bytes.buffer.asUint8List());
          final response = await request.close();
          await response.drain<void>();
        } finally {
          client.close(force: true);
          im.dispose();
        }
      }

      try {
        await t.pumpWidget(app());
        await settle();
        final fields = find.byType(TextFormField);
        await t.enterText(fields.at(0), 'Real registered nickname');
        await t.enterText(fields.at(1), email);
        await t.enterText(fields.at(2), password);
        await t.enterText(fields.at(3), password);
        FocusManager.instance.primaryFocus?.unfocus();
        await settle();
        await t.ensureVisible(find.text('创建账户'));
        await t.tap(find.text('创建账户'));
        await until('先简单认识一下你。');
        expect(find.text('Real registered nickname'), findsOneWidget);
        await shot('step1-original');
        await t.enterText(find.byType(TextField).first, 'Agenote 测试用户');
        await hideKeyboard();
        await t.ensureVisible(find.text('软件开发'));
        await t.tap(find.text('软件开发'));
        await settle();
        await t.tap(find.text('继续'));
        await until('02 / 02');
        await t.tap(find.text('工作会议'));
        await t.tap(find.text('客户沟通'));
        await settle();
        await shot('step2-selected');
        // Wait for cloud draft, then recreate the page and reload from the real server.
        for (var i = 0; i < 30; i++) {
          await t.pump(const Duration(milliseconds: 200));
        }
        await t.pumpWidget(const SizedBox());
        routes.dispose();
        await p.load();
        expect(p.data.name, 'Agenote 测试用户');
        expect(p.data.personalization!.profession, 'software');
        expect(p.data.personalization!.step, 2);
        expect(
          p.data.personalization!.scenarios,
          containsAll(['work', 'customer']),
        );
        routes = router();
        await t.pumpWidget(app());
        await until('02 / 02');
        await shot('step2-restored');
        await t.tap(find.text('开启 Agenote'));
        await until('Existing home destination');
        final response = await api.get(
          'auth/profile',
          authenticated: true,
          accountId: auth.accountId,
        );
        expect(
          (response['data'] as Map)['personalization']['status'],
          'completed',
        );
        expect((response['data'] as Map)['name'], 'Agenote 测试用户');
        expect(accountRedirect(p, '/login'), '/home');
      } finally {
        await t.pumpWidget(const SizedBox());
        routes.dispose();
        if (auth.authenticated) {
          await const SecurePersonalizationDrafts().write(
            auth.accountId!,
            null,
          );
          await api.post(
            'auth/delete-account',
            authenticated: true,
            accountId: auth.accountId,
            data: {'current_password': password, 'confirmation': 'DELETE'},
          );
        }
        vm.dispose();
        p.dispose();
        api.dio.close();
      }
    },
  );
}
