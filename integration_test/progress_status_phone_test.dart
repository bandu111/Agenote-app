import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:provider/provider.dart';
import 'package:yanshu/core/network/api_client.dart';
import 'package:yanshu/core/network/api_config.dart';
import 'package:yanshu/features/auth/repositories/dio_auth_repository.dart';
import 'package:yanshu/features/auth/services/session_store.dart';
import 'package:yanshu/features/notifications/knowledge_assistance.dart';
import 'package:yanshu/features/notifications/notification_model.dart';
import 'package:yanshu/features/notifications/notification_views.dart';
import 'package:yanshu/features/progress/repositories/dio_progress_repository.dart';
import 'package:yanshu/features/progress/viewmodels/progress_view_model.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('真机清空通知同步过期、重新登录持久化与账号隔离', (tester) async {
    const channel = MethodChannel('agenote/local-notifications');
    const password = 'Progress-QA-2026!';
    final email = 'progress-phone-${DateTime.now().microsecondsSinceEpoch}@example.com';
    final api = ApiClient(baseUrl: ApiConfig.baseUrl);
    final auth = DioAuthRepository(api, SecureSessionStore('${ApiConfig.baseUrl}#progress-qa'));
    await auth.register('进展真机隔离测试', email, password);
    final owner = auth.accountId!;
    final vm = ProgressViewModel(DioProgressRepository(api));
    final notices = NotificationModel(storage: const FlutterSecureStorage());
    final assistance = KnowledgeAssistance(api, notices, onRecorded: () => vm.load(silent: true));
    final checks = <String,bool>{};
    try {
      final undated = await api.post('progress/goals', authenticated: true, data: {
        'title': '真机测试缺交期目标', 'condition': '提交报告',
      });
      final dated = await api.post('progress/goals', authenticated: true, data: {
        'title': '真机测试明确交期目标', 'condition': '提交报告',
        'deadline': DateTime.now().add(const Duration(days: 3)).toUtc().toIso8601String(),
      });
      final id = undated['data']['id'] as String;
      final datedId = dated['data']['id'] as String;
      await notices.configureInbox('${ApiConfig.baseUrl}:$owner');
      notices.bind(vm);
      await vm.load();
      assistance.refreshAccount();
      await tester.pumpWidget(ChangeNotifierProvider.value(value: notices,
        child: const MaterialApp(home: NotificationsPage())));
      await tester.pumpAndSettle();
      expect(find.text('清空'), findsOneWidget);
      expect(notices.pendingCount, 1);
      await tester.tap(find.text('清空'));
      await tester.pumpAndSettle();
      expect(find.text('暂无通知'), findsOneWidget);
      expect(notices.pendingCount, 0);
      await notices.flushInbox();
      for (var i = 0; i < 20 && notices.pendingRemoteClears.isNotEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await assistance.refresh();
      }
      expect(notices.pendingRemoteClears, isEmpty);
      await vm.load();
      expect(vm.goal(id)!.expiredByClear, isTrue);
      expect(vm.goal(id)!.statusLabelAt(DateTime.now()), '已过期');
      expect(vm.goal(datedId)!.expiredByClear, isFalse);
      checks['clearUpdatesCloudStatus'] = true;
      checks['datedGoalPreserved'] = true;
      await channel.invokeMethod<void>('configure', {'owner': owner, 'enabled': true});
      await channel.invokeMethod<void>('sync', {'owner': owner, 'ids': <String>[], 'badge': 0});
      final native = await channel.invokeMapMethod<String,dynamic>('status');
      expect(native?['badge'], 0);
      checks['badgeZero'] = true;
      await auth.logout();
      await auth.login(email,password);
      await vm.load();
      expect(vm.goal(id)!.expiredByClear,isTrue);
      final inbox = await api.get('knowledge/notice-inbox',authenticated:true);
      expect(inbox['data']['clearedIds'],contains('progress-pending:$id'));
      checks['reloginPersistsExpiryAndClear'] = true;
      await auth.deleteAccount(password);
      await auth.register('隔离空账户', 'other-$email', password);
      await vm.load();
      expect(vm.data.goals,isEmpty);
      checks['otherAccountEmpty'] = true;
      binding.reportData = checks;
      debugPrint('PROGRESS_STATUS_PHONE_RESULT:${jsonEncode(checks)}');
    } finally {
      assistance.dispose();
      await tester.pumpWidget(const SizedBox.shrink());
      notices.dispose();
      vm.dispose();
      await channel.invokeMethod<void>('configure', {'owner':null,'enabled':false});
      if (auth.accountId != null) await auth.deleteAccount(password);
    }
  });
}
