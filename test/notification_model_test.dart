import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:yanshu/features/notifications/notification_model.dart';
import 'package:yanshu/features/notifications/device_calendar_executor.dart';
import 'package:yanshu/core/network/api_config.dart';
import 'package:yanshu/features/progress/models/progress_models.dart';
import 'package:yanshu/features/progress/repositories/progress_repository.dart';
import 'package:yanshu/features/progress/viewmodels/progress_view_model.dart';

void main() {
  test('通知显示日历权限和已失效来源的明确原因，不伪装执行成功', () async {
    final model = NotificationModel();
    addTearDown(model.dispose);
    model.receive(
      const ActionNotice(
        id: 'calendar-error',
        title: '创建日程',
        instruction: '写入日历',
      ),
      onAllow: () async => throw const CalendarExecutionFailure('请允许系统日历权限后重试'),
    );
    expect(await model.decide('calendar-error', allow: true), isFalse);
    expect(model.error('calendar-error'), '请允许系统日历权限后重试');
    model.receive(
      const ActionNotice(
        id: 'source-error',
        title: '创建任务',
        instruction: '核对来源',
      ),
      onAllow: () async => throw const ApiFailure('相关依据已变更，等待重新核对后再确认'),
    );
    expect(await model.decide('source-error', allow: true), isFalse);
    expect(model.error('source-error'), contains('依据已变更'));
    expect(model.pendingCount, 0);
  });
  test(
    'existing deliverables become short requests; confirmation only approves that version',
    () async {
      final progress = ProgressViewModel(MockProgressRepository());
      final model = NotificationModel()..bind(progress);
      addTearDown(model.dispose);
      addTearDown(progress.dispose);
      await progress.load();
      expect(model.items.length, 7); // 成果通知及信息完整的承诺确认。
      expect(model.pendingCount, 1);
      expect(
        model.prompt,
        isNull,
      ); // Historical inbox entries do not interrupt on every launch.
      expect(
        await model.decide('artifact:artifact-0:v1.2', allow: true),
        isTrue,
      );
      expect(model.pendingCount, 1);
      expect(progress.artifact('artifact-0')!.status, ArtifactStatus.approved);
      expect(
        await model.decide('artifact:artifact-0:v1.2', allow: true),
        isFalse,
      );
      await progress.load();
      expect(model.pendingCount, 1);
    },
  );

  test(
    'global requests prompt once, deduplicate, reject without running, and retry failures',
    () async {
      final model = NotificationModel();
      addTearDown(model.dispose);
      const notice = ActionNotice(
        id: 'permission-1',
        kind: NoticeKind.completion,
        title: '使用麦克风',
        instruction: '录制这次会话。',
      );
      var calls = 0;
      Future<bool> action() async {
        calls++;
        return false;
      }

      model.receive(notice, onAllow: action);
      expect(model.prompt?.id, notice.id);
      expect(model.promptRevision, 1);
      model.receive(notice, onAllow: action);
      expect(model.promptRevision, 1);
      model.dismissPrompt();
      expect(model.pendingCount, 1);
      expect(await model.decide(notice.id, allow: true), isFalse);
      expect(model.pendingCount, 1);
      expect(model.error(notice.id), isNotNull);
      expect(await model.decide(notice.id, allow: false), isTrue);
      expect(calls, 1);
      model.receive(notice, onAllow: action);
      expect(model.pendingCount, 0);
    },
  );

  test('double taps cannot execute the same permission twice', () async {
    final model = NotificationModel();
    addTearDown(model.dispose);
    final completion = Completer<bool>();
    var calls = 0;
    model.receive(
      const ActionNotice(id: 'once', title: '保存文件', instruction: '保存到知识库。'),
      onAllow: () {
        calls++;
        return completion.future;
      },
    );
    final first = model.decide('once', allow: true);
    expect(await model.decide('once', allow: true), isFalse);
    expect(await model.decide('once', allow: false), isFalse);
    completion.complete(true);
    expect(await first, isTrue);
    expect(calls, 1);
    expect(model.pendingCount, 0);
  });
}
