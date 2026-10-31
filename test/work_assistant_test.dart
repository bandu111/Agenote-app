import 'package:yanshu/features/work_assistant/outcome_page.dart';
import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yanshu/core/network/api_client.dart';
import 'package:yanshu/features/work_assistant/assistant_model.dart';
import 'package:yanshu/features/work_assistant/wechat_panel.dart';
import 'package:yanshu/features/profile/viewmodels/profile_view_model.dart';
import 'package:yanshu/features/profile/models/profile_data.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'dio_auth_repository_test.dart' show TestAdapter, envelope;

void main() {
  testWidgets('malformed outcome and stale oversized QR do not crash', (
    tester,
  ) async {
    final client = ApiClient(baseUrl: 'https://test.invalid/', dio: Dio())
      ..accountId = () => 'first';
    final profile = ProfileViewModel()
      ..data = const ProfileData(accountId: 'first');
    final model = AssistantModel(client, 'first')
      ..channel = {
        'bindingStatus': 'expired',
        'canBind': true,
        'qr': 'x' * 4000,
      };
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: profile),
          ChangeNotifierProvider.value(value: model),
        ],
        child: const MaterialApp(home: Scaffold(body: WechatPanel())),
      ),
    );
    expect(find.text('重新获取二维码'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: profile,
        child: MaterialApp(
          home: OutcomePage(
            owner: 'first',
            client: client,
            row: {
              'result': {
                'metrics': [
                  null,
                  {'name': 42},
                ],
                'findings': [
                  {'evidence_ids': 42},
                ],
                'analysis_tables': [
                  {
                    'columns': ['a'],
                    'rows': [
                      [{}, {}],
                    ],
                  },
                ],
              },
              'status': 42,
              'delivery': 'bad',
            },
          ),
        ),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    model.dispose();
    profile.dispose();
  });

  test('temporary account loss releases loading and saving guards', () async {
    String? owner = 'first';
    final client = ApiClient(baseUrl: 'https://test.invalid/', dio: Dio())
      ..accountId = () => owner;
    Completer<void> gate = Completer<void>();
    final paths = <String>[];
    client.dio.httpClientAdapter = TestAdapter((r) async {
      paths.add(r.path);
      await gate.future;
      return (200, envelope({'version': 1, 'bindingStatus': 'bound'}));
    });
    final model = AssistantModel(client, 'first');
    final pending = model.load();
    owner = null;
    gate.complete();
    await pending;
    expect(model.loading, isFalse);
    expect(model.channel, isEmpty);
    owner = 'first';
    await model.load();
    expect(model.channel['bindingStatus'], 'bound');
    gate = Completer<void>();
    final saving = model.unbind();
    owner = null;
    gate.complete();
    await saving;
    expect(model.saving, isFalse);
    owner = 'first';
    await model.load();
    expect(model.loading, isFalse);
    expect(paths.any((p) => p.endsWith('outcomes')), isFalse);
    model.dispose();
  });
  test(
    'rebind reset version replaces stale QR and preserves PDF defaults',
    () async {
      final client = ApiClient(baseUrl: 'https://test.invalid/', dio: Dio())
        ..accountId = () => 'first';
      client.dio.httpClientAdapter = TestAdapter((r) async {
        if (r.method == 'POST') {
          if (r.path.endsWith('preferences')) {
            expect((r.data as Map)['sendPdf'], isTrue);
            expect((r.data as Map)['preMeeting'], isTrue);
          }
          return (200, envelope({'version': 1, 'bindingStatus': 'unbound'}));
        }
        return (200, envelope({'version': 1, 'bindingStatus': 'unbound'}));
      });
      final model = AssistantModel(client, 'first')
        ..channel = {'version': 99, 'qr': 'old'};
      await model.load();
      expect(model.channel['version'], 1);
      expect(model.channel['qr'], isNull);
      await model.preference('paused', true);
      model.channel = {};
      await model.unbind();
      expect(model.error, isNotNull);
      model.dispose();
    },
  );

  test(
    'single automatic-results setting enables existing server analysis opt-in',
    () async {
      final paths = <String>[];
      final client = ApiClient(baseUrl: 'https://test.invalid/', dio: Dio())
        ..accountId = () => 'first';
      client.dio.httpClientAdapter = TestAdapter((request) async {
        paths.add(request.path);
        if (request.path.endsWith('assistant/preferences')) {
          expect((request.data as Map)['autoAnalyze'], isTrue);
          return (200, envelope({'autoAnalyze': true}));
        }
        expect((request.data as Map)['autoMeeting'], isTrue);
        expect((request.data as Map)['sendPdf'], isTrue);
        expect((request.data as Map)['preMeeting'], isFalse);
        return (200, envelope({'version': 2, 'preferences': request.data}));
      });
      final model = AssistantModel(client, 'first');
      model.channel = {
        'version': 1,
        'preferences': {'sendPdf': true, 'preMeeting': false},
      };
      await model.preference('autoMeeting', true);
      expect(paths.length, 2);
      expect(model.channel['analysisPreferences']['autoAnalyze'], isTrue);
      expect(model.channel['preferences']['autoMeeting'], isTrue);
      model.dispose();
    },
  );
  testWidgets(
    'QR authorization switches to connected settings without a binding code',
    (tester) async {
      final client = ApiClient(baseUrl: 'https://test.invalid/', dio: Dio());
      client.accountId = () => 'first';
      final model = AssistantModel(client, 'first');
      final profile = ProfileViewModel()
        ..data = const ProfileData(
          accountId: 'first',
          email: 'first@example.com',
        );
      model.channel = {
        'bindingStatus': 'pending',
        'canBind': true,
        'qr': 'https://liteapp.weixin.qq.com/test-fixture',
      };
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider.value(value: model),
            ChangeNotifierProvider.value(value: profile),
          ],
          child: const MaterialApp(
            home: Scaffold(body: SingleChildScrollView(child: WechatPanel())),
          ),
        ),
      );
      expect(find.bySemanticsLabel('微信授权二维码'), findsOneWidget);
      expect(find.text('一次性绑定码'), findsNothing);
      model.channel = {
        'bindingStatus': 'bound',
        'canSend': false,
        'preferences': {
          'autoMeeting': true,
          'importantOnly': true,
          'aiDone': true,
          'paused': false,
        },
      };
      client.dio.httpClientAdapter = TestAdapter(
        (request) async => (
          200,
          envelope(request.path.endsWith('outcomes') ? [] : model.channel),
        ),
      );
      await tester.runAsync(() => model.load());
      await tester.pump();
      expect(find.text('微信助手已连接'), findsOneWidget);
      expect(find.bySemanticsLabel('微信授权二维码'), findsNothing);
      expect(find.text('请先在微信发送一条消息'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      model.dispose();
      profile.dispose();
    },
  );
  test('late response cannot cross accounts', () async {
    String owner = 'first';
    final gate = Completer<void>();
    final client = ApiClient(baseUrl: 'https://test.invalid/', dio: Dio());
    client.accountId = () => owner;
    client.dio.httpClientAdapter = TestAdapter((request) async {
      await gate.future;
      return (
        200,
        envelope(
          request.path.endsWith('outcomes')
              ? [
                  {'id': 'private-first-report'},
                ]
              : {'bindingStatus': 'unavailable'},
        ),
      );
    });
    final model = AssistantModel(client, 'first');
    final pending = model.load();
    owner = 'second';
    gate.complete();
    await pending;
    expect(model.channel, isEmpty);
    model.dispose();
  });
  test('unavailable binding does not become fake success', () async {
    final client = ApiClient(baseUrl: 'https://test.invalid/', dio: Dio());
    client.accountId = () => 'first';
    client.dio.httpClientAdapter = TestAdapter(
      (request) async => (
        200,
        envelope(
          request.path.endsWith('outcomes')
              ? []
              : {
                  'canBind': false,
                  'canSend': false,
                  'qr': null,
                  'bindingStatus': 'unavailable',
                },
        ),
      ),
    );
    final model = AssistantModel(client, 'first');
    await model.load();
    expect(model.channel['canBind'], isFalse);
    expect(model.channel['canSend'], isFalse);
    expect(model.channel['qr'], isNull);
    model.dispose();
  });
}
