import 'dart:convert';
import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:yanshu/features/notifications/notification_model.dart';

void main() {
  test('同一待确认事项换版本和措辞不重复弹层，真正新事项仍提醒', () async {
    final model = NotificationModel();
    addTearDown(model.dispose);
    await model.configureInbox('cloud:A');
    const first = ActionNotice(
      id: 'progress-pending:task:1',
      title: '补全报告',
      instruction: '补交期',
      kind: NoticeKind.completion,
    );
    model.receive(first, onAllow: () async => true);
    final revision = model.promptRevision;
    model.dismissPrompt();
    model.receive(
      const ActionNotice(
        id: 'progress-pending:task:2',
        title: '报告的资料待完善',
        instruction: '请确认提交时间',
        kind: NoticeKind.completion,
      ),
      onAllow: () async => true,
    );
    expect(model.promptRevision, revision);
    expect(model.prompt, isNull);
    model.receive(
      const ActionNotice(
        id: 'progress-pending:new:1',
        title: '新任务',
        instruction: '补全',
        kind: NoticeKind.completion,
      ),
      onAllow: () async => true,
    );
    expect(model.promptRevision, revision + 1);
  });

  test('A 账号审批迟到返回不能修改 B 账号同 ID 通知', () async {
    final model = NotificationModel();
    addTearDown(model.dispose);
    final oldResult = Completer<bool>();
    await model.configureInbox('cloud:A');
    model.receive(
      const ActionNotice(id: 'same-id', title: 'A', instruction: 'A'),
      onAllow: () => oldResult.future,
    );
    final oldAction = model.decide('same-id', allow: true);
    await model.configureInbox('cloud:B');
    model.receive(
      const ActionNotice(id: 'same-id', title: 'B', instruction: 'B'),
      onAllow: () async => true,
    );
    oldResult.complete(true);
    expect(await oldAction, isFalse);
    expect(model.items.single.title, 'B');
    expect(model.items.single.state, NoticeState.pending);
  });
  test('切换账号立即清除所有来源通知与回调，清除记录分别隔离', () async {
    final saved = <String, String>{};
    NotificationModel create() => NotificationModel(
      readInbox: (key) async => saved[key],
      writeInbox: (key, value) async {
        saved[key] = value;
      },
    );
    final model = create();
    addTearDown(model.dispose);
    await model.configureInbox('cloud:A');
    for (final id in ['assistance:risk:1', 'meeting:1', 'action:task:1:3']) {
      model.receive(
        ActionNotice(
          id: id,
          title: 'A 的通知',
          instruction: 'A 私有内容',
          kind: NoticeKind.warning,
        ),
        onAllow: () async => true,
      );
    }
    expect(model.items.length, 3);
    await model.configureInbox('cloud:B');
    expect(model.items, isEmpty);
    expect(model.prompt, isNull);
    expect(model.pendingCount, 0);
    expect(await model.decide('meeting:1', allow: true), isFalse);
    const b = ActionNotice(
      id: 'progress-pending:b:1',
      title: 'B 的任务',
      instruction: '补交期',
      kind: NoticeKind.completion,
    );
    model.receive(b, onAllow: () async => true);
    model.clearAll();
    await model.flushInbox();
    expect(model.pendingRemoteClears, {'progress-pending:b'});
    await model.configureInbox('cloud:A');
    model.receive(b, onAllow: () async => true);
    expect(model.items.length, 1); // B 清除的墓碑不能影响 A。
    await model.configureInbox('cloud:B');
    model.receive(
      const ActionNotice(
        id: 'progress-pending:b:9',
        title: '同一任务换了标题',
        instruction: '模型换措辞',
        kind: NoticeKind.completion,
      ),
      onAllow: () async => true,
    );
    expect(model.items, isEmpty);
    expect(jsonDecode(saved['notice-inbox:cloud:B']!)['version'], 5);
  });

  test('清除失败补交队列持久保存，服务端同步不影响新事项', () async {
    final saved = <String, String>{};
    NotificationModel create() => NotificationModel(
      readInbox: (key) async => saved[key],
      writeInbox: (key, value) async {
        saved[key] = value;
      },
    );
    var model = create();
    await model.configureInbox('cloud:A');
    const notice = ActionNotice(
      id: 'progress-pending:task:2',
      title: '旧任务',
      instruction: '补全',
      kind: NoticeKind.completion,
    );
    model.receive(notice, onAllow: () async => true);
    model.clearAll();
    await model.flushInbox();
    model.dispose();
    model = create();
    addTearDown(model.dispose);
    await model.configureInbox('cloud:A');
    expect(model.pendingRemoteClears, {'progress-pending:task'});
    model.applyRemoteCleared(
      {'progress-pending:task'},
      synced: {'progress-pending:task'},
    );
    expect(model.pendingRemoteClears, isEmpty);
    model.receive(notice, onAllow: () async => true);
    model.receive(
      const ActionNotice(
        id: 'progress-pending:new:1',
        title: '新任务',
        instruction: '补全',
        kind: NoticeKind.completion,
      ),
      onAllow: () async => true,
    );
    expect(model.items.single.title, '新任务');
  });
}
