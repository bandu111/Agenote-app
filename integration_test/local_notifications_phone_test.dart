import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import 'package:yanshu/core/network/api_client.dart';
import 'package:yanshu/core/network/api_config.dart';
import 'package:yanshu/features/auth/repositories/dio_auth_repository.dart';
import 'package:yanshu/features/auth/services/session_store.dart';
import 'package:yanshu/features/notifications/knowledge_assistance.dart';
import 'package:yanshu/features/notifications/notification_model.dart';
import 'package:yanshu/features/notifications/notification_views.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('真实本地通知、云端清除墓碑与双账号隔离', (tester) async {
    const channel = MethodChannel('agenote/local-notifications');
    Future<void> expectActive(int count) async {
      int? actual;
      for (var i = 0; i < 30; i++) {
        actual =
            (await channel.invokeMapMethod<String, dynamic>(
                  'status',
                ))?['activeCount']
                as int?;
        if (actual == count) break;
        // NotificationManager 的发布/取消由系统异步处理，等待真实状态而非假定立即完成。
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(actual, count);
    }

    const storage = FlutterSecureStorage();
    final api = ApiClient(baseUrl: ApiConfig.baseUrl);
    final auth = DioAuthRepository(
      api,
      SecureSessionStore('${ApiConfig.baseUrl}#local-notice-qa'),
    );
    final stamp = DateTime.now().microsecondsSinceEpoch;
    await auth.register(
      '通知隔离 A',
      'notice-a-$stamp@example.com',
      'Notice-QA-2026!',
    );
    final ownerA = auth.accountId!;
    final model = NotificationModel(storage: storage);
    final service = KnowledgeAssistance(api, model);
    final checks = <String, bool>{};
    try {
      await model.configureInbox('${ApiConfig.baseUrl}:$ownerA');
      service.refreshAccount();
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: model,
          child: const MaterialApp(home: NotificationsPage()),
        ),
      );
      const notice = ActionNotice(
        id: 'progress-pending:qa-task:1',
        title: '测试补全事项',
        instruction: '补充交期',
        kind: NoticeKind.completion,
      );
      model.receive(notice, onAllow: () async => true);
      await tester.pump();
      await tester.tap(find.text('清空'));
      await tester.pump();
      expect(model.pendingCount, 0);
      expect(find.text('暂无通知'), findsOneWidget);
      await model.flushInbox();
      for (var i = 0; i < 30 && model.pendingRemoteClears.isNotEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        await service.refresh();
      }
      final cleared = await api.get(
        'knowledge/notice-inbox',
        authenticated: true,
        accountId: ownerA,
      );
      expect(
        cleared['data']['clearedIds'],
        contains('progress-pending:qa-task'),
      );
      checks['cloudClearPersisted'] = true;
      model.receive(
        const ActionNotice(
          id: 'progress-pending:qa-task:9',
          title: '同一任务模型重写',
          instruction: '同一任务换了措辞',
          kind: NoticeKind.completion,
        ),
        onAllow: () async => true,
      );
      expect(model.items, isEmpty);
      checks['clearedRevisionDoesNotResurface'] = true;

      model.receive(
        const ActionNotice(
          id: 'meeting:private-A',
          title: 'A 的私有会议通知',
          instruction: '隔离测试',
          kind: NoticeKind.warning,
        ),
        onAllow: () async => true,
      );
      await auth.register(
        '通知隔离 B',
        'notice-b-$stamp@example.com',
        'Notice-QA-2026!',
      );
      final ownerB = auth.accountId!;
      await model.configureInbox('${ApiConfig.baseUrl}:$ownerB');
      service.refreshAccount();
      expect(model.items, isEmpty);
      expect(model.prompt, isNull);
      final bInbox = await api.get(
        'knowledge/notice-inbox',
        authenticated: true,
        accountId: ownerB,
      );
      expect(bInbox['data']['clearedIds'], isEmpty);
      checks['cloudAndFlutterAccountsIsolated'] = true;

      await channel.invokeMethod<void>('configure', {
        'owner': ownerA,
        'enabled': true,
      });
      await Permission.notification.request();
      expect(
        await channel.invokeMethod<bool>('show', {
          'owner': ownerA,
          'id': 'qa-native',
          'title': 'Agenote 本地通知测试',
          'body': '这是隔离测试提醒',
          'badge': 1,
        }),
        isTrue,
      );
      await Future<void>.delayed(const Duration(milliseconds: 600));
      await expectActive(1);
      await channel.invokeMethod<bool>('show', {
        'owner': ownerA,
        'id': 'qa-native',
        'title': 'Agenote 本地通知测试',
        'body': '同一通知更新',
        'badge': 1,
      });
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await expectActive(1);
      checks['nativeNotificationReplacesDuplicate'] = true;
      // Java String.hashCode 的经典碰撞对必须各保留一条通知。
      for (final id in ['Aa', 'BB']) {
        expect(
          await channel.invokeMethod<bool>('show', {
            'owner': ownerA,
            'id': id,
            'title': '独立通知 $id',
            'body': 'ID 碰撞回归',
            'badge': 3,
          }),
          isTrue,
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final ids =
          (await channel.invokeMapMethod<String, dynamic>(
                'status',
              ))?['activeIds']
              as List;
      expect(ids, containsAll(['Aa', 'BB', 'qa-native']));
      await channel.invokeMethod<void>('sync', {
        'owner': ownerA,
        'ids': ['Aa', 'BB', 'qa-native'],
        'badge': 3,
      });
      if (Platform.isAndroid) {
        expect(
          (await channel.invokeMapMethod<String, dynamic>('status'))?['badge'],
          3,
        );
      }
      checks['hashCollisionAndBadgeRegression'] = true;

      await channel.invokeMethod<void>('configure', {
        'owner': ownerB,
        'enabled': true,
      });
      await expectActive(0);
      expect(
        await channel.invokeMethod<bool>('show', {
          'owner': ownerA,
          'id': 'late-A',
          'title': '旧账号迟到通知',
          'body': '不应展示',
        }),
        isFalse,
      );
      checks['nativeLateAccountRejected'] = true;
      expect(
        await channel.invokeMethod<bool>('show', {
          'owner': ownerB,
          'id': 'qa-native-b',
          'title': 'Agenote 本地通知测试',
          'body': 'B 账号测试',
          'badge': 1,
        }),
        isTrue,
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await channel.invokeMethod<void>('sync', {
        'owner': ownerB,
        'ids': <String>[],
        'badge': 0,
      });
      await expectActive(0);
      checks['nativeClearCancelsNotification'] = true;

      final cold = NotificationModel(storage: storage);
      const coldScope = 'qa-local-notification-cold-start';
      final previous = await storage.read(key: '$coldScope:pid');
      await cold.configureInbox(coldScope);
      const old = ActionNotice(
        id: 'progress-pending:cold-task:1',
        title: '冷启动测试',
        instruction: '补全交期',
        kind: NoticeKind.completion,
      );
      cold.receive(old, onAllow: () async => true);
      if (previous != null) {
        expect(int.parse(previous), isNot(pid));
        expect(cold.items, isEmpty);
      } else {
        expect(cold.items.length, 1);
        cold.clearAll();
        await cold.flushInbox();
        await storage.write(key: '$coldScope:pid', value: '$pid');
      }
      checks['realSecureStorageColdRestart'] = previous != null;
      cold.dispose();
      binding.reportData = {'pid': pid, 'checks': checks};
      debugPrint('LOCAL_NOTIFICATION_RESULT:${jsonEncode(binding.reportData)}');
    } finally {
      service.dispose();
      await channel.invokeMethod<void>('configure', {
        'owner': null,
        'enabled': false,
      });
      await tester.pumpWidget(const SizedBox.shrink());
      model.dispose();
      await auth.logout();
    }
  });
}
