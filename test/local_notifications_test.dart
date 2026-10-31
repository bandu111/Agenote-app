import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yanshu/core/network/api_client.dart';
import 'package:yanshu/features/notifications/local_notifications.dart';
import 'package:yanshu/features/notifications/notification_model.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    '只发本地补全和风险，去重、清空和账号切换同步原生层',
    (tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      const channel = MethodChannel('agenote/local-notifications');
      final calls = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        calls.add(call);
        return call.method == 'show' ? true : null;
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      String? owner = 'A';
      final api = ApiClient(baseUrl: 'http://local/')..accountId = () => owner;
      final model = NotificationModel();
      final local = LocalNotifications(
        api,
        model,
        onChanged: () async {},
        onOpen: () {},
      );
      addTearDown(local.dispose);
      addTearDown(model.dispose);
      await model.configureInbox('local:A');
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      local.configure(enabled: true);
      await tester.pumpAndSettle();
      const warning = ActionNotice(
        id: 'assistance:risk:one',
        title: '风险',
        instruction: '核对风险',
        kind: NoticeKind.warning,
      );
      model.receive(warning, onAllow: () async => true);
      model.receive(
        const ActionNotice(id: 'info', title: '普通资料', instruction: '静默'),
        onAllow: () async => true,
      );
      await tester.pumpAndSettle();
      expect(calls.where((c) => c.method == 'show').length, 1);
      model.receive(warning, onAllow: () async => true);
      await tester.pumpAndSettle();
      expect(calls.where((c) => c.method == 'show').length, 1);
      model.clearAll();
      await tester.pumpAndSettle();
      expect(
        (calls.lastWhere((c) => c.method == 'sync').arguments as Map)['ids'],
        isEmpty,
      );
      owner = 'B';
      await model.configureInbox('local:B');
      local.configure(enabled: true);
      await tester.pumpAndSettle();
      expect(
        (calls.lastWhere((c) => c.method == 'configure').arguments
            as Map)['owner'],
        'B',
      );
      expect(model.items, isEmpty);
      local.configure(enabled: false);
      await tester.pumpAndSettle();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    },
    variant: TargetPlatformVariant({TargetPlatform.android}),
  );
}
