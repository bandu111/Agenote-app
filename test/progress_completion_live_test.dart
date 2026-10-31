import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:yanshu/features/auth/repositories/dio_auth_repository.dart';
import 'package:yanshu/features/progress/repositories/dio_progress_repository.dart';
import 'package:yanshu/features/progress/viewmodels/progress_view_model.dart';
import 'dio_auth_repository_test.dart' show MemorySessionStore;
import 'meeting_backend_live_test.dart' show liveApi;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    '真实Dio待补记录→保存交期→重读进入目标列表',
    () async {
      final api = liveApi();
      final auth = DioAuthRepository(api, MemorySessionStore());
      final accounts = <Map<String, String>>[];
      final checks = <String, bool>{};
      Future<void> save() => File('docs/progress_completion_live_result.json')
          .writeAsString(
            jsonEncode({
              'synthetic_only': true,
              'real_backend': true,
              'model_called': false,
              'accounts_for_cleanup': accounts,
              'checks': checks,
            }),
          )
          .then((_) {});
      try {
        final email =
            'auto-meeting-completion-${DateTime.now().microsecondsSinceEpoch}@example.com';
        final user = await auth.register(
          '自动化会议',
          email,
          'Only-Local-Completion-Test-2026!',
        );
        accounts.add({'id': user.id, 'email': email});
        await save();
        await api.post(
          'progress/goals',
          authenticated: true,
          data: {'title': '合成测试：待补交期', 'condition': '交付测试报告'},
        );
        final vm = ProgressViewModel(DioProgressRepository(api));
        await vm.load();
        expect(vm.error, isNull);
        expect(vm.data.pending, hasLength(1));
        expect(vm.data.goals, isEmpty);
        final item = vm.data.pending.single;
        expect(item.needsSide, isFalse);
        expect(item.needsDeadline, isTrue);
        expect(
          await vm.completeMissing(
            item,
            deadline: DateTime.parse('2026-11-05T23:59:00+08:00'),
          ),
          isTrue,
        );
        expect(vm.data.pending, isEmpty);
        expect(vm.data.goals, hasLength(1));
        final fresh = await DioProgressRepository(api).load();
        expect(fresh.goals.single.id, item.id);
        expect(
          fresh.goals.single.deadline!.toUtc(),
          DateTime.parse('2026-11-05T15:59:00Z'),
        );
        checks['pending_preserved_before_completion'] = true;
        checks['completion_persisted_and_visible_after_reload'] = true;
        checks['completion_does_not_claim_fulfillment'] =
            fresh.goals.single.status.name == 'pending';
        await save();
        vm.dispose();
      } finally {
        await auth.logout();
      }
    },
    skip: !const bool.fromEnvironment('RUN_PROGRESS_COMPLETION_BACKEND'),
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
