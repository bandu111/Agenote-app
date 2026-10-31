import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:yanshu/core/network/api_client.dart';
import 'package:yanshu/features/home/repositories/dio_home_repository.dart';
import 'package:yanshu/features/home/viewmodels/schedule_view_model.dart';

void main() {
  final base = Platform.environment['YANSHU_CHECKLIST_QA_URL'];
  test('真实 HTTP：纪要行动→首页任务→勾选保存→重新登录回读', () async {
    final api = ApiClient(baseUrl: base!);
    const password = 'Checklist-QA-only-password-2026';
    final email =
        'checklist-http-${DateTime.now().microsecondsSinceEpoch}@example.com';
    final registered = (await api.post(
      'auth/register',
      data: {'name': '清单联调', 'email': email, 'password': password},
    ))['data'];
    final owner = registered['user']['id'] as String;
    var token = registered['access_token'] as String;
    api.accountId = () => owner;
    api.accessToken = () async => token;
    try {
      final source =
          jsonDecode(
                File('build/checklist_http_source.json').readAsStringSync(),
              )
              as Map<String, dynamic>;
      source['ended'] = true;
      if ((source['elapsed'] as num? ?? 0) < 60000) source['elapsed'] = 60000;
      await api.post(
        'meetings/sync',
        data: source,
        authenticated: true,
        accountId: owner,
      );
      final archive = (await api.post(
        'meetings/${source['id']}/archive',
        authenticated: true,
        accountId: owner,
        receiveTimeout: const Duration(minutes: 3),
      ))['data'];
      final actions = (archive['details']['actions'] as List);
      expect(actions, isNotEmpty);
      final repo = DioHomeRepository(api);
      final vm = ScheduleViewModel(
        repo,
        taskChecklist: true,
        listenToTime: false,
      );
      vm.refreshAccount();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await vm.refresh();
      expect(vm.error, isNull);
      final task = vm.entries.first;
      expect(actions.any((a) => a['taskId'] == task.item.id), true);
      expect(task.item.completed, isFalse);
      expect(await vm.complete(task.item.id), isTrue);
      expect(
        vm.entries.singleWhere((e) => e.item.id == task.item.id).item.completed,
        isTrue,
      );
      vm.dismissCompleted(task.item.id);
      expect(vm.entries.any((e) => e.item.id == task.item.id), false);
      vm.dispose();
      final login = (await api.post(
        'auth/login',
        data: {'email': email, 'password': password},
      ))['data'];
      token = login['access_token'];
      final fresh = ScheduleViewModel(
        DioHomeRepository(api),
        taskChecklist: true,
        listenToTime: false,
      );
      fresh.refreshAccount();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await fresh.refresh();
      expect(fresh.entries.any((e) => e.item.id == task.item.id), false);
      expect(fresh.error, isNull);
      fresh.dispose();
    } finally {
      await api.post(
        'auth/delete-account',
        data: {'current_password': password, 'confirmation': 'DELETE'},
        authenticated: true,
        accountId: owner,
      );
      api.dio.close(force: true);
    }
  }, skip: base == null ? '需要显式指定隔离 QA 服务地址' : false);
}
