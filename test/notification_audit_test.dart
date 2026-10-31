import 'dart:async';
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yanshu/core/network/api_client.dart';
import 'package:yanshu/features/notifications/account_actions.dart';
import 'package:yanshu/features/notifications/device_calendar_executor.dart';
import 'package:yanshu/features/notifications/local_notifications.dart';
import 'package:yanshu/features/notifications/notification_model.dart';
import 'package:yanshu/features/notifications/notification_views.dart';
import 'package:yanshu/features/progress/repositories/progress_repository.dart';
import 'package:yanshu/features/progress/viewmodels/progress_view_model.dart';
import 'dio_auth_repository_test.dart' show TestAdapter, envelope;

class AuditCalendar extends DeviceCalendarExecutor {
  @override
  Future<String> deviceId() async => 'audit-device';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('M2 部分确认只移除实际确认的同步墓碑', () async {
    final model = NotificationModel();
    addTearDown(model.dispose);
    for (final id in ['progress-pending:a:1', 'progress-pending:b:1']) {
      model.receive(
        ActionNotice(
          id: id,
          title: id,
          instruction: '补全',
          kind: NoticeKind.completion,
        ),
        onAllow: () async => true,
      );
    }
    model.clearAll();
    model.applyRemoteCleared(
      {'progress-pending:a'},
      synced: {'progress-pending:a', 'progress-pending:b'},
    );
    expect(model.pendingRemoteClears, {'progress-pending:b'});
    expect(model.items, isEmpty);
  });
  test('M1 会议和失效进展清理同时销毁拒绝回调', () async {
    final progress = ProgressViewModel(MockProgressRepository());
    final model = NotificationModel();
    addTearDown(progress.dispose);
    addTearDown(model.dispose);
    var declined = 0;
    for (final id in ['meeting:old', 'artifact:old:1']) {
      model.receive(
        ActionNotice(id: id, title: '旧', instruction: '旧'),
        onAllow: () async => true,
        onDecline: () async {
          declined++;
          return true;
        },
      );
    }
    model.clearMeetingNotices();
    model.bind(progress);
    await progress.load();
    for (final id in ['meeting:old', 'artifact:old:1']) {
      model.receive(
        ActionNotice(id: id, title: '新', instruction: '新'),
        onAllow: () async => true,
      );
      expect(await model.decide(id, allow: false), isTrue);
    }
    expect(declined, 0);
  });
  test('M3 单条日期和结构异常不阻断其余日程及任务', () async {
    var tasksFetched = false;
    final dio = Dio()
      ..httpClientAdapter = TestAdapter((request) async {
        if (request.path == 'tasks') {
          tasksFetched = true;
          return (
            200,
            envelope([
              {
                'id': 'task',
                'title': '提交报告',
                'version': 1,
                'status': 'pending',
              },
            ]),
          );
        }
        return (
          200,
          envelope([
            null,
            {'id': 'bad', 'start': 'not-a-date', 'end': null},
            {
              'id': 'good',
              'title': '有效日程',
              'status': 'pending',
              'start': '2030-01-01T09:00:00Z',
              'end': '2030-01-01T10:00:00Z',
            },
          ]),
        );
      });
    final api = ApiClient(baseUrl: 'https://audit.invalid/', dio: dio)
      ..accountId = () => 'owner';
    final model = NotificationModel();
    final actions = AccountActions(api, model, executor: AuditCalendar());
    addTearDown(actions.dispose);
    addTearDown(model.dispose);
    addTearDown(() => dio.close(force: true));
    actions.refreshAccount();
    for (
      var i = 0;
      i < 100 && !model.items.any((n) => n.id == 'action:task:task:1');
      i++
    ) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(tasksFetched, isTrue);
    expect(
      model.items.map((n) => n.id),
      containsAll(['action:good', 'action:task:task:1']),
    );
    expect(actions.malformedItems, 2);
    expect(actions.error, contains('已跳过'));
  });
  testWidgets('L1 正常轮询至少间隔15秒，失败后退避而非两秒全量重试', (tester) async {
    var requests = 0, failing = false;
    final dio = Dio()
      ..httpClientAdapter = TestAdapter((request) async {
        if (request.path == 'tasks') return (200, envelope([]));
        requests++;
        return failing ? (503, envelope([])) : (200, envelope([]));
      });
    final api = ApiClient(baseUrl: 'https://audit.invalid/', dio: dio)
      ..accountId = () => 'owner';
    final model = NotificationModel();
    final actions = AccountActions(api, model, executor: AuditCalendar());
    try {
      actions.refreshAccount();
      await tester.pumpAndSettle();
      expect(requests, 1);
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(requests, 1);
      await tester.pump(const Duration(seconds: 13));
      await tester.pumpAndSettle();
      expect(requests, 2);
      failing = true;
      unawaited(actions.refresh());
      await tester.pumpAndSettle();
      final failedAt = requests;
      await tester.pump(const Duration(seconds: 29));
      await tester.pumpAndSettle();
      expect(requests, failedAt);
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(requests, failedAt + 1);
    } finally {
      actions.dispose();
      model.dispose();
      dio.close(force: true);
    }
  });
  for (final scenario in [
    'versions',
    'opened',
    'retry',
    'disabled-retry',
    'permission',
    'prune',
  ]) {
    testWidgets(
      '本地通知审计回归 $scenario',
      (tester) async {
        FlutterSecureStorage.setMockInitialValues({});
        const channel = MethodChannel('agenote/local-notifications');
        final calls = <MethodCall>[];
        final active = <String>{};
        String? opened;
        var granted = true, failInitialize = scenario.endsWith('retry');
        var openedPages = 0, changes = 0;
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          (call) async {
            calls.add(call);
            final args = call.arguments is Map
                ? call.arguments as Map
                : const {};
            switch (call.method) {
              case 'configure':
                if (failInitialize) {
                  failInitialize = false;
                  throw PlatformException(code: 'temporary');
                }
                return null;
              case 'status':
                return {
                  'permissionGranted': granted,
                  'activeIds': active.toList(),
                };
              case 'takeOpen':
                final value = opened;
                opened = null;
                return value;
              case 'show':
                active.add(args['id'] as String);
                return true;
              case 'sync':
                active.removeWhere((id) => !(args['ids'] as List).contains(id));
                return null;
            }
            return null;
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            channel,
            null,
          ),
        );
        final api = ApiClient(baseUrl: 'https://audit/')
          ..accountId = () => 'owner';
        final model = NotificationModel();
        var local = LocalNotifications(
          api,
          model,
          onChanged: () async {},
          onOpen: () {
            openedPages++;
          },
        );
        local.addListener(() {
          changes++;
        });
        addTearDown(() => local.dispose());
        addTearDown(model.dispose);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        local.configure(enabled: scenario != 'disabled-retry');
        await tester.pumpAndSettle();
        if (scenario == 'versions' || scenario == 'prune') {
          const first = ActionNotice(
            id: 'progress-pending:task:1',
            title: '报告',
            instruction: '旧交期',
            kind: NoticeKind.completion,
          );
          model.receive(first, onAllow: () async => true);
          await tester.pumpAndSettle();
          model.receive(first, onAllow: () async => true);
          await tester.pumpAndSettle();
          expect(calls.where((c) => c.method == 'show').length, 1);
          model.receive(
            const ActionNotice(
              id: 'progress-pending:task:1',
              title: '报告',
              instruction: '新的交期风险',
              kind: NoticeKind.completion,
            ),
            onAllow: () async => true,
          );
          await tester.pumpAndSettle();
          expect(calls.where((c) => c.method == 'show').length, 2);
          expect(active.single, 'progress-pending:task');
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.resumed,
          );
          await tester.pumpAndSettle();
          model.receive(
            const ActionNotice(
              id: 'progress-pending:task:1',
              title: '报告',
              instruction: '前台更新内容',
              kind: NoticeKind.completion,
            ),
            onAllow: () async => true,
          );
          await tester.pumpAndSettle();
          expect(
            (calls.lastWhere((c) => c.method == 'show').arguments
                as Map)['silent'],
            isTrue,
          );
          model.clearAll();
          await tester.pumpAndSettle();
          final saved = await const FlutterSecureStorage().read(
            key: 'local-notice-delivery:https://audit/:owner',
          );
          expect((jsonDecode(saved!) as Map)['seen'], isEmpty);
        } else if (scenario == 'opened') {
          opened = 'owner';
          final done = Completer<void>();
          tester.binding.defaultBinaryMessenger.handlePlatformMessage(
            'agenote/local-notifications',
            const StandardMethodCodec().encodeMethodCall(
              const MethodCall('opened', 'owner'),
            ),
            (_) => done.complete(),
          );
          await tester.pumpAndSettle();
          await done.future;
          expect(openedPages, 1);
          expect(opened, isNull);
          local.dispose();
          local = LocalNotifications(
            api,
            model,
            onChanged: () async {},
            onOpen: () {
              openedPages++;
            },
          );
          local.configure(enabled: true);
          await tester.pumpAndSettle();
          expect(openedPages, 1);
        } else if (scenario.endsWith('retry')) {
          expect(local.error, isNotNull);
          await tester.pump(const Duration(seconds: 30));
          await tester.pumpAndSettle();
          expect(local.error, isNull);
          expect(calls.where((c) => c.method == 'configure').length, 2);
        } else {
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.resumed,
          );
          await tester.pumpAndSettle();
          await tester.pumpWidget(
            ChangeNotifierProvider<LocalNotifications?>.value(
              value: local,
              child: const MaterialApp(
                home: Scaffold(
                  bottomNavigationBar: NotificationDeliveryStatus(),
                ),
              ),
            ),
          );
          granted = false;
          await local.retry();
          await tester.pumpAndSettle();
          expect(local.error, contains('已关闭'));
          expect(changes, greaterThan(0));
          expect(find.textContaining('系统通知已关闭'), findsOneWidget);
          granted = true;
          await local.retry();
          await tester.pumpAndSettle();
          expect(local.error, isNull);
        }
        await tester.pumpWidget(const SizedBox.shrink());
        local.configure(enabled: false);
        await tester.pumpAndSettle();
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
      },
      variant: TargetPlatformVariant({TargetPlatform.android}),
    );
  }
}
