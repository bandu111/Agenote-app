import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:provider/provider.dart';
import 'package:yanshu/features/notifications/notification_model.dart';
import 'package:yanshu/features/notifications/notification_views.dart';

/// Run twice without reinstalling/clearing the test package. The second run
/// must have a different process ID; it cannot use NotificationModel's cache.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('真实安全存储：清空后结束进程并重启不恢复旧通知', (tester) async {
    const storage = FlutterSecureStorage();
    const scope = 'https://124.220.169.122/api/v1/:notification-cold-start-qa';
    const phaseKey = 'qa.notification-restart.phase';
    final previous = await storage.read(key: phaseKey);
    final cold = previous != null;
    final model = NotificationModel(storage: storage);
    final checks = <String, bool>{};
    final report = <String, dynamic>{
      'realSecureStorage': true,
      'pid': pid,
      'phase': cold ? 'cold-restart' : 'clear-and-persist',
      'checks': checks,
    };
    try {
      await model.configureInbox(scope);
      expect(model.loadError, isNull);
      model.receive(
        ActionNotice(
          id: 'artifact:report:${cold ? 9 : 2}',
          title: '评估报告',
          instruction: '无需操作。',
          state: NoticeState.completed,
        ),
        onAllow: () async => true,
      );
      model.receive(
        ActionNotice(
          id: 'assistance:meeting-warning:qa:risk:${List.filled(64, cold ? 'b' : 'a').join()}',
          title: '接口风险',
          instruction: '核对上线影响',
          kind: NoticeKind.warning,
        ),
        onAllow: () async => true,
      );
      model.receive(
        ActionNotice(
          id: 'progress-pending:123:${cold ? 8 : 1}',
          title: '补全交期',
          instruction: '选择交期',
          kind: NoticeKind.completion,
        ),
        onAllow: () async => true,
      );
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
      await tester.pump();
      if (!cold) {
        expect(model.items.length, 3);
        await tester.tap(find.text('清空'));
        await tester.pump();
        await model.flushInbox();
        await tester.pump();
        expect(model.persistenceError, isNull);
        final persisted = await storage.read(key: 'notice-inbox:$scope');
        expect((jsonDecode(persisted!) as Map)['version'], 5);
        await storage.write(key: phaseKey, value: jsonEncode({'pid': pid}));
        checks['clearButtonWritesNativeSecureStorage'] = true;
      } else {
        final previousPid = (jsonDecode(previous) as Map)['pid'];
        expect(pid, isNot(previousPid), reason: '必须真正重启进程');
        checks['differentProcessWithSameAppData'] = true;
        checks['changedRevisionAndFingerprintStayCleared'] =
            model.items.isEmpty;
      }
      expect(model.items, isEmpty);
      expect(model.pendingCount, 0);
      expect(model.prompt, isNull);
      expect(find.text('暂无通知'), findsOneWidget);
      expect(tester.widget<Badge>(find.byType(Badge)).isLabelVisible, false);
      checks['emptyListBadgeZeroAndNoPrompt'] = true;
      if (cold) {
        expect(
          model.stateOf('progress-pending:123:8'),
          NoticeState.unavailable,
        );
        model.receive(
          const ActionNotice(
            id: 'warning:genuinely-new',
            title: '新的风险',
            instruction: '今天新出现的风险',
            kind: NoticeKind.warning,
          ),
          onAllow: () async => true,
        );
        await tester.pump();
        expect(model.pendingCount, 1);
        expect(model.items.single.id, 'warning:genuinely-new');
        checks['genuinelyNewNotificationsStillWork'] = true;
        await storage.delete(key: 'notice-inbox:$scope');
        await storage.delete(key: phaseKey);
        checks['isolatedTestStorageCleaned'] = true;
      }
      report['passed'] = true;
    } catch (error) {
      report['passed'] = false;
      report['error'] = error.toString();
      rethrow;
    } finally {
      binding.reportData = report;
      debugPrint('NOTIFICATION_RESTART_RESULT:${jsonEncode(report)}');
      await tester.pumpWidget(const SizedBox.shrink());
      model.dispose();
    }
  });
}
