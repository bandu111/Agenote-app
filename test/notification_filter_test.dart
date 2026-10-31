import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:go_router/go_router.dart';
import 'package:yanshu/features/notifications/notification_model.dart';
import 'package:yanshu/features/notifications/notification_views.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('详情页不再生成全局浮动铃铛，顶部通知和角标仍可使用', (tester) async {
    final model = NotificationModel();
    final navigator = GlobalKey<NavigatorState>();
    final router = GoRouter(
      navigatorKey: navigator,
      initialLocation: '/detail',
      routes: [
        GoRoute(
          path: '/detail',
          builder: (_, _) => Scaffold(
            appBar: AppBar(actions: const [NotificationAction()]),
            body: const Text('详情'),
          ),
        ),
        GoRoute(
          path: '/notifications',
          builder: (_, _) => const NotificationsPage(),
        ),
      ],
    );
    addTearDown(router.dispose);
    addTearDown(model.dispose);
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: model,
        child: MaterialApp.router(
          routerConfig: router,
          builder: (context, child) => NotificationOverlay(
            child: NotificationHost(
              router: router,
              navigatorKey: navigator,
              child: child!,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(FloatingActionButton), findsNothing);
    expect(find.byType(NotificationAction), findsOneWidget);
    await tester.tap(find.byTooltip('通知'));
    await tester.pumpAndSettle();
    expect(find.byType(NotificationsPage), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  test('v3 清除记录升级后成果、辅助通知和数字任务 ID 都正确恢复', () async {
    const version = '["旧通知","旧内容","warning"]';
    final model = NotificationModel(
      readInbox: (_) async => jsonEncode({
        'version': 3,
        'cleared': {
          'artifact:report:2': version,
          'assistance:meeting-warning:m:r:${List.filled(64, 'a').join()}':
              version,
          'progress-pending:123': version,
        },
        'invalidated': {'progress-pending:123': version},
      }),
    );
    addTearDown(model.dispose);
    await model.configureInbox('cloud:v3-migration');
    for (final id in [
      'artifact:report:4',
      'assistance:meeting-warning:m:r:${List.filled(64, 'b').join()}',
      'progress-pending:123:9',
    ]) {
      model.receive(
        ActionNotice(
          id: id,
          title: '旧通知',
          instruction: '旧内容',
          kind: NoticeKind.warning,
        ),
        onAllow: () async => true,
      );
    }
    expect(model.items, isEmpty);
    expect(model.stateOf('progress-pending:123:9'), NoticeState.unavailable);
  });
  test('冷启动后成果版本和辅助通知指纹变化不能让相同旧通知复活', () async {
    final persisted = <String, String>{};
    NotificationModel create() => NotificationModel(
      readInbox: (key) async => persisted[key],
      writeInbox: (key, value) async => persisted[key] = value,
    );
    final first = create();
    await first.configureInbox('cloud:cold-start');
    const old = [
      ActionNotice(
        id: 'artifact:report:2',
        title: '评估报告',
        instruction: '无需操作。',
      ),
      ActionNotice(
        id: 'assistance:meeting-warning:meeting:risk:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        title: 'ERP 接口超时',
        instruction: '需核对影响范围',
        kind: NoticeKind.warning,
      ),
    ];
    for (final n in old) {
      first.receive(n, onAllow: () async => true);
    }
    first.clearAll();
    await first.flushInbox();
    first.dispose();
    final restarted = create();
    addTearDown(restarted.dispose);
    await restarted.configureInbox('cloud:cold-start');
    for (final n in [
      const ActionNotice(
        id: 'artifact:report:9',
        title: '评估报告',
        instruction: '无需操作。',
      ),
      const ActionNotice(
        id: 'assistance:meeting-warning:meeting:risk:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
        title: 'ERP 接口超时',
        instruction: '需核对影响范围',
        kind: NoticeKind.warning,
      ),
    ]) {
      restarted.receive(n, onAllow: () async => true);
    }
    expect(restarted.items, isEmpty);
    expect(restarted.pendingCount, 0);
    expect(restarted.prompt, isNull);
    restarted.receive(
      const ActionNotice(
        id: 'assistance:meeting-warning:meeting:new-risk:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc',
        title: 'ERP 接口超时',
        instruction: '新的严重影响：上线被阻塞',
        kind: NoticeKind.warning,
      ),
      onAllow: () async => true,
    );
    expect(restarted.items.length, 1);
    expect(restarted.pendingCount, 1);
  });
  test('读取清除记录失败时不把旧通知当新消息，重试后正确恢复', () async {
    var failRead = true;
    final model = NotificationModel(
      readInbox: (_) async {
        if (failRead) throw StateError('keychain unavailable');
        return '{"version":3,"cleared":{"artifact:report:1":"[\\"评估报告\\",\\"无需操作。\\",\\"action\\"]"},"invalidated":{}}';
      },
    );
    addTearDown(model.dispose);
    await model.configureInbox('cloud:read-failure');
    model.receive(
      const ActionNotice(
        id: 'artifact:report:2',
        title: '评估报告',
        instruction: '无需操作。',
      ),
      onAllow: () async => true,
    );
    expect(model.loadError, isNotNull);
    expect(model.items, isEmpty);
    expect(model.pendingCount, 0);
    failRead = false;
    await model.refresh();
    expect(model.loadError, isNull);
    expect(model.items, isEmpty);
  });
  test('恢复清除记录期间不闪旧提示，恢复后仅发布真正的新提醒', () async {
    final stored = Completer<String?>();
    const old = ActionNotice(
      id: 'warning:old',
      title: '旧风险',
      instruction: '已核对',
      kind: NoticeKind.warning,
    );
    const fresh = ActionNotice(
      id: 'warning:new',
      title: '新风险',
      instruction: '交期刚变化',
      kind: NoticeKind.warning,
    );
    final model = NotificationModel(readInbox: (_) => stored.future);
    addTearDown(model.dispose);
    final ready = model.configureInbox('cloud:restore');
    model.receive(old, onAllow: () async => true);
    model.receive(fresh, onAllow: () async => true);
    expect(model.items, isEmpty);
    expect(model.prompt, isNull);
    stored.complete(
      jsonEncode({
        'version': 2,
        'cleared': {old.id: old.inboxVersion},
        'invalidated': {old.id: old.inboxVersion},
      }),
    );
    await ready;
    expect(model.items.single.id, fresh.id);
    expect(model.pendingCount, 1);
    expect(model.prompt?.id, fresh.id);
  });

  test('保存失败不声称持久化成功，允许重试且同进程重登保留清除状态', () async {
    var failWrite = true;
    final stored = <String, String>{};
    final model = NotificationModel(
      readInbox: (key) async => stored[key],
      writeInbox: (key, value) async {
        if (failWrite) throw StateError('storage unavailable');
        stored[key] = value;
      },
    );
    addTearDown(model.dispose);
    await model.configureInbox('cloud:write-error');
    const notice = ActionNotice(
      id: 'warning:write',
      title: '风险',
      instruction: '需核对',
      kind: NoticeKind.warning,
    );
    model.receive(notice, onAllow: () async => true);
    model.clearAll();
    await model.flushInbox();
    expect(model.persistenceError, isNotNull);
    expect(model.canClear, isTrue);
    expect(model.items, isEmpty);
    failWrite = false;
    model.clearAll();
    await model.flushInbox();
    expect(model.persistenceError, isNull);
    await model.configureInbox(null);
    await model.configureInbox('cloud:write-error');
    model.receive(notice, onAllow: () async => true);
    expect(model.items, isEmpty);
  });
  test('清空后立即退出重登，等待旧写入完成再恢复，不闪回旧通知', () async {
    final persisted = <String, String>{};
    final release = Completer<void>();
    final model = NotificationModel(
      readInbox: (key) async => persisted[key],
      writeInbox: (key, value) async {
        await release.future;
        persisted[key] = value;
      },
    );
    addTearDown(model.dispose);
    await model.configureInbox('cloud:race');
    const notice = ActionNotice(
      id: 'progress-pending:task:1',
      title: '补全报告',
      instruction: '补充交期',
      kind: NoticeKind.completion,
    );
    model.receive(notice, onAllow: () async => true);
    model.clearAll();
    await model.configureInbox(null);
    var restored = false;
    final login = model
        .configureInbox('cloud:race')
        .then((_) => restored = true);
    model.receive(notice, onAllow: () async => true);
    await Future<void>.delayed(Duration.zero);
    expect(restored, isFalse);
    expect(model.items, isEmpty);
    expect(model.pendingCount, 0);
    expect(model.prompt, isNull);
    release.complete();
    await login;
    expect(model.stateOf(notice.id), NoticeState.unavailable);
    expect(model.items, isEmpty);
  });

  test('重登后仅业务版本变化不会复活同一补全，新缺项仍正常出现', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final model = NotificationModel(storage: const FlutterSecureStorage());
    addTearDown(model.dispose);
    await model.configureInbox('cloud:stable');
    const original = ActionNotice(
      id: 'progress-pending:123:4',
      title: '补全报告',
      instruction: '补充交期',
      kind: NoticeKind.completion,
    );
    model.receive(original, onAllow: () async => true);
    model.clearAll();
    await model.flushInbox();
    await model.configureInbox(null);
    await model.configureInbox('cloud:stable');
    model.receive(
      const ActionNotice(
        id: 'progress-pending:123:9',
        title: '补全报告',
        instruction: '补充交期',
        kind: NoticeKind.completion,
      ),
      onAllow: () async => true,
    );
    expect(model.items, isEmpty);
    expect(model.pendingCount, 0);
    expect(model.stateOf('progress-pending:123:9'), NoticeState.unavailable);
    model.receive(
      const ActionNotice(
        id: 'progress-pending:new-task:10',
        title: '补全报告',
        instruction: '选择我方或对方履约项，补充交期',
        kind: NoticeKind.completion,
      ),
      onAllow: () async => true,
    );
    expect(model.pendingCount, 1);
    expect(model.items.length, 1);
  });

  test('旧存储版本 ID 迁移后，开始任务通知也不随版本刷新复活', () async {
    FlutterSecureStorage.setMockInitialValues({
      'notice-inbox:cloud:old-task':
          '{"version":2,"cleared":{"action:task:t:2":"[\\"开始任务\\",\\"保留原始会议依据\\",\\"action\\"]"},"invalidated":{"action:task:t:2":"[\\"开始任务\\",\\"保留原始会议依据\\",\\"action\\"]"}}',
    });
    final model = NotificationModel(storage: const FlutterSecureStorage());
    addTearDown(model.dispose);
    await model.configureInbox('cloud:old-task');
    model.receive(
      const ActionNotice(
        id: 'action:task:t:5',
        title: '开始任务',
        instruction: '保留原始会议依据',
      ),
      onAllow: () async => true,
    );
    expect(model.items, isEmpty);
    expect(model.stateOf('action:task:t:5'), NoticeState.unavailable);
  });
  const ordinary = ActionNotice(
    id: 'action:1',
    title: '创建日程',
    instruction: '需本人允许',
  );
  const completion = ActionNotice(
    id: 'pending:1',
    title: '补全交期',
    instruction: '请选择日期',
    kind: NoticeKind.completion,
  );
  const warning = ActionNotice(
    id: 'warning:1',
    title: '交期冲突',
    instruction: '核对上线前提',
    kind: NoticeKind.warning,
    allowLabel: '知道了',
  );

  test('旧澄清通知重新分类后立即移除弹层和角标', () {
    final model = NotificationModel();
    addTearDown(model.dispose);
    model.receive(
      const ActionNotice(
        id: 'question:old',
        title: '建议核对',
        instruction: '影响待判断',
        kind: NoticeKind.completion,
      ),
      onAllow: () async => true,
    );
    expect(model.pendingCount, 1);
    expect(model.prompt, isNotNull);
    model.receive(
      const ActionNotice(
        id: 'question:old',
        title: '建议核对',
        instruction: '影响待判断',
        kind: NoticeKind.information,
        allowLabel: '知道了',
      ),
      onAllow: () async => true,
    );
    expect(model.pendingCount, 0);
    expect(model.prompt, isNull);
    model.acknowledge('question:old');
    expect(model.stateOf('question:old'), NoticeState.cleared);
    expect(model.items, isEmpty);
  });

  test('清空所有类型并失效待确认项，不执行业务，轮询不复活', () async {
    final model = NotificationModel();
    addTearDown(model.dispose);
    var executed = 0;
    model.receive(
      ordinary,
      onAllow: () async {
        executed++;
        return true;
      },
    );
    expect(model.prompt, isNull);
    expect(model.pendingCount, 0);
    model.receive(completion, onAllow: () async => true);
    model.receive(warning, onAllow: () async => true);
    expect(model.pendingCount, 2);
    expect(model.prompt?.id, warning.id);
    expect(model.clearAll(), 3);
    for (final notice in [ordinary, completion, warning]) {
      expect(model.stateOf(notice.id), NoticeState.unavailable);
    }
    expect(model.items, isEmpty);
    expect(model.pendingCount, 0);
    expect(model.prompt, isNull);
    model.receive(
      ordinary,
      onAllow: () async {
        executed++;
        return true;
      },
    );
    model.receive(completion, onAllow: () async => true);
    model.receive(warning, onAllow: () async => true);
    expect(model.items, isEmpty); // 所有类型相同内容轮询都不复活。
    expect(model.prompt, isNull);
    expect(executed, 0);
    expect(await model.decide(ordinary.id, allow: true), isFalse);
    expect(await model.decide(warning.id, allow: true), isFalse);
    expect(await model.decide(completion.id, allow: true), isFalse);
    expect(model.pendingCount, 0);
    expect(model.prompt, isNull);
  });

  test('清空持久保存并按环境账户隔离，新内容重新显示', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final model = NotificationModel(storage: const FlutterSecureStorage());
    addTearDown(model.dispose);
    await model.configureInbox('cloud:owner-1');
    model.receive(ordinary, onAllow: () async => true);
    model.acknowledge(ordinary.id);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    final restored = NotificationModel(storage: const FlutterSecureStorage());
    addTearDown(restored.dispose);
    await restored.configureInbox('cloud:owner-1');
    restored.receive(ordinary, onAllow: () async => true);
    expect(restored.items, isEmpty);
    expect(restored.stateOf(ordinary.id), NoticeState.cleared);
    restored.receive(
      const ActionNotice(id: 'action:1', title: '创建日程', instruction: '日期已修改'),
      onAllow: () async => true,
    );
    expect(restored.items.length, 1);
    await restored.configureInbox('local:owner-1');
    restored.receive(ordinary, onAllow: () async => true);
    expect(restored.items.length, 1);
  });

  test('清除不随后台状态切换复活，旧格式清理记录可以迁移', () async {
    FlutterSecureStorage.setMockInitialValues({
      'notice-inbox:cloud:migration':
          '{"action:1":"[\\"创建日程\\",\\"需本人允许\\",\\"pending\\",\\"action\\"]"}',
    });
    final model = NotificationModel(storage: const FlutterSecureStorage());
    addTearDown(model.dispose);
    await model.configureInbox('cloud:migration');
    model.receive(ordinary, onAllow: () async => true);
    expect(model.stateOf(ordinary.id), NoticeState.cleared);
    model.receive(
      const ActionNotice(
        id: 'action:1',
        title: '创建日程',
        instruction: '需本人允许',
        state: NoticeState.completed,
      ),
      onAllow: () async => true,
    );
    expect(model.items, isEmpty);
    expect(model.pendingCount, 0);
    expect(model.stateOf(ordinary.id), NoticeState.cleared);
  });

  testWidgets(
    '通知页清空全部显示暂无通知，角标和弹层同步归零',
    (tester) async {
      final model = NotificationModel();
      addTearDown(model.dispose);
      for (final notice in [ordinary, completion, warning]) {
        model.receive(notice, onAllow: () async => true);
      }
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: model,
          child: const MaterialApp(
            home: Stack(
              children: [
                NotificationsPage(),
                Positioned(right: 0, bottom: 0, child: NotificationAction()),
              ],
            ),
          ),
        ),
      );
      expect(find.text('待确认 · 2'), findsOneWidget);
      expect(tester.widget<Badge>(find.byType(Badge)).isLabelVisible, isTrue);
      await tester.tap(find.text('清空'));
      await tester.pump();
      expect(find.text('已清除 3 条通知'), findsOneWidget);
      expect(find.text('暂无通知'), findsOneWidget);
      expect(find.text('创建日程'), findsNothing);
      expect(find.text('待确认 · 2'), findsNothing);
      expect(model.pendingCount, 0);
      expect(tester.widget<Badge>(find.byType(Badge)).isLabelVisible, isFalse);
      expect(model.items, isEmpty);
      expect(model.prompt, isNull);
      expect(model.canClear, isFalse);
    },
    variant: TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.iOS,
    }),
  );

  test('补全与风险清空后重启仍失效，新内容正常提醒，账户隔离', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final model = NotificationModel(storage: const FlutterSecureStorage());
    addTearDown(model.dispose);
    await model.configureInbox('cloud:clear-all');
    for (final n in [completion, warning]) {
      model.receive(n, onAllow: () async => true);
    }
    model.clearAll();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    final restored = NotificationModel(storage: const FlutterSecureStorage());
    addTearDown(restored.dispose);
    await restored.configureInbox('cloud:clear-all');
    for (final n in [completion, warning]) {
      restored.receive(n, onAllow: () async => true);
      expect(restored.stateOf(n.id), NoticeState.unavailable);
    }
    expect(restored.items, isEmpty);
    expect(restored.pendingCount, 0);
    expect(restored.prompt, isNull);
    restored.receive(
      const ActionNotice(
        id: 'warning:2',
        title: '交期冲突',
        instruction: '交期已变化，重新核对',
        kind: NoticeKind.warning,
      ),
      onAllow: () async => true,
    );
    expect(restored.items.length, 1);
    expect(restored.pendingCount, 1);
    expect(restored.prompt, isNotNull);
    await restored.configureInbox('local:clear-all');
    restored.receive(completion, onAllow: () async => true);
    expect(restored.stateOf(completion.id), NoticeState.pending);
  });

  test('执行中仍可清空，执行结束不会重新出现，也不重复执行', () async {
    final model = NotificationModel();
    addTearDown(model.dispose);
    final result = Completer<bool>();
    var calls = 0;
    model.receive(
      completion,
      onAllow: () {
        calls++;
        return result.future;
      },
    );
    final running = model.decide(completion.id, allow: true);
    expect(model.busy(completion.id), isTrue);
    expect(model.clearAll(), 1);
    expect(model.items, isEmpty);
    expect(model.stateOf(completion.id), NoticeState.unavailable);
    result.complete(true);
    expect(await running, isTrue);
    expect(model.items, isEmpty);
    expect(model.pendingCount, 0);
    expect(model.prompt, isNull);
    expect(await model.decide(completion.id, allow: true), isFalse);
    expect(calls, 1);
  });
}
