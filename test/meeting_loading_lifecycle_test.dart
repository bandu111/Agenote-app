import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:yanshu/features/meeting/meeting_completion.dart';
import 'package:yanshu/features/meeting/meeting_models.dart';
import 'package:yanshu/features/meeting/meeting_remote.dart';
import 'package:yanshu/features/meeting/meeting_store.dart';
import 'meeting_remote_test.dart' show FakeMeetingRemote, createMeeting;

class LoadingRemote extends FakeMeetingRemote
    implements StreamingMeetingAnalysis, MeetingCompletionRemote {
  bool pendingInput = false;
  void Function(Map<String, dynamic>)? preview;
  final finish = Completer<Map<String, dynamic>>();
  @override
  Future<Map<String, dynamic>> analyzeWithUpdates(
    MeetingRecord record,
    void Function(Map<String, dynamic>) onPreview,
  ) {
    preview = onPreview;
    return finish.future;
  }

  @override
  Future<List<MeetingCompletionItem>> completionItems(
    MeetingRecord record,
    List<String> sourceIds,
  ) async => !pendingInput || record.utterances.isEmpty
      ? []
      : [
          MeetingCompletionItem(
            id: 'c',
            title: '报告',
            version: 1,
            sourceIds: record.utterances.map((u) => u.id).toList(),
          ),
        ];
  @override
  Future<MeetingCompletionItem> confirmCompletion(
    MeetingRecord record,
    MeetingCompletionItem item, {
    required String side,
    required DateTime deadline,
  }) => throw StateError('user has not chosen');
}

class EmptyLiveRemote extends FakeMeetingRemote implements LiveMeetingAnalysis {
  final closing = Completer<void>();
  bool delivered = false;
  @override
  Future<void> liveHints(
    MeetingRecord record,
    void Function(Map<String, dynamic>) onUpdate,
  ) async {
    delivered = true;
    onUpdate({'event': 'done', 'insights': [], 'repairs': []});
    await closing.future;
  }
}

void main() {
  for (final preview in [
    {'actions_prepared': true, 'kind': 'action_preparation'},
    {
      'agents_completed': ['state'],
      'insights': [],
      'repairs': [],
    },
  ]) {
    testWidgets('只有待确认事项或空角色结果也停止骨架，后台未结束仍可继续发布正文: $preview', (tester) async {
      final remote = LoadingRemote();
      final vm = await createMeeting(
        remote,
        MemoryMeetingStore(),
        disposeViewModel: false,
      );
      await vm.start(demo: false);
      await vm.addManual('发言人 A', '我们会提交评估报告，交期待确认。');
      await tester.pump(const Duration(seconds: 4));
      await tester.pump();
      expect(remote.preview, isNotNull);
      expect(vm.cloudAnalyzing, isTrue);
      expect(vm.coreHintsLoading, isTrue);
      // 初始空快照不代表分析已完成。
      remote.preview!({'insights': [], 'repairs': []});
      expect(vm.coreHintsLoading, isTrue);
      remote.preview!(preview);
      await tester.pump();
      expect(vm.coreHintsLoading, isFalse);
      await tester.pump(const Duration(seconds: 45));
      expect(vm.cloudAnalyzing, isTrue);
      expect(vm.coreHintsLoading, isFalse);
      remote.preview!({
        'insights': [
          {
            'id': 'later',
            'kind': 'risk',
            'title': '后续风险',
            'body': '交期仍需核对',
            'evidence_ids': [vm.record!.utterances.first.id],
          },
        ],
      });
      expect(vm.record!.insights.any((i) => i.id == 'later'), isTrue);
      vm.dispose();
      remote.finish.complete({'insights': [], 'repairs': []});
      await tester.pump();
    });
  }

  testWidgets('用户没有填写实际待补项时保持静态等待，不显示生成骨架', (tester) async {
    final remote = LoadingRemote()..pendingInput = true;
    final vm = await createMeeting(
      remote,
      MemoryMeetingStore(),
      disposeViewModel: false,
    );
    await vm.start(demo: false);
    await vm.addManual('发言人 A', '我们会提交报告。');
    await vm.completionItems([vm.record!.utterances.first.id]);
    await tester.pump(const Duration(seconds: 4));
    await tester.pump();
    expect(vm.hasCompletion([vm.record!.utterances.first.id]), isTrue);
    expect(vm.cloudAnalyzing, isTrue);
    expect(vm.coreHintsLoading, isFalse);
    await tester.pump(const Duration(seconds: 45));
    expect(vm.coreHintsLoading, isFalse);
    expect(remote.finish.isCompleted, isFalse);
    vm.dispose();
    remote.finish.complete({'insights': [], 'repairs': []});
    await tester.pump();
  });

  testWidgets('建议流明确返回空结果后不等待连接关闭才停骨架', (tester) async {
    final remote = EmptyLiveRemote();
    final vm = await createMeeting(
      remote,
      MemoryMeetingStore(),
      disposeViewModel: false,
    );
    await vm.start(demo: false);
    await vm.addManual('发言人 A', '报告交期待确认。');
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(remote.delivered, isTrue);
    expect(remote.closing.isCompleted, isFalse);
    expect(vm.liveHintsLoading, isFalse);
    vm.dispose();
    remote.closing.complete();
    await tester.pump();
  });
}
