import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:yanshu/app/app.dart';
import 'package:yanshu/core/network/api_config.dart';
import 'package:yanshu/features/knowledge/repositories/knowledge_repository.dart';
import 'package:yanshu/features/profile/repositories/profile_repository.dart';
import 'package:yanshu/features/meeting/meeting_store.dart';
import 'package:yanshu/features/meeting/meeting_models.dart';
import 'package:yanshu/features/meeting/meeting_view_model.dart';
import 'package:yanshu/features/meeting/local_speech.dart';
import 'package:yanshu/features/meeting/meeting_completion_panel.dart';
import 'package:yanshu/features/meeting/meeting_completion.dart';
import 'package:yanshu/features/meeting/meeting_remote.dart';
import 'meeting_remote_test.dart' show FakeMeetingRemote;
import 'meeting_test.dart' show FakeMeetingRecorder;

class CompletionRemote extends FakeMeetingRemote
    implements MeetingCompletionRemote {
  bool available = true;
  int confirmations = 0;
  MeetingCompletionItem item = const MeetingCompletionItem(
    id: 'c',
    title: '报告',
    version: 1,
  );
  @override
  Future<List<MeetingCompletionItem>> completionItems(
    MeetingRecord record,
    List<String> sourceIds,
  ) async => !available || record.utterances.isEmpty
      ? []
      : [
          MeetingCompletionItem(
            id: item.id,
            title: item.title,
            version: item.version,
            side: item.side,
            deadline: item.deadline,
            confirmed: item.confirmed,
            sourceIds: record.utterances.map((u) => u.id).toList(),
          ),
        ];
  @override
  Future<MeetingCompletionItem> confirmCompletion(
    MeetingRecord record,
    MeetingCompletionItem item, {
    required String side,
    required DateTime deadline,
  }) async {
    confirmations++;
    return this.item = confirmed(item, side, deadline);
  }
}

MeetingCompletionItem confirmed(
  MeetingCompletionItem item,
  String side,
  DateTime deadline,
) => MeetingCompletionItem(
  id: item.id,
  title: item.title,
  version: item.version + 1,
  side: side,
  deadline: deadline,
  confirmed: true,
);

Future<void> pickDate(WidgetTester tester, {bool cancel = false}) async {
  await tester.ensureVisible(find.byKey(const ValueKey('completion-date-u')));
  await tester.tap(find.byKey(const ValueKey('completion-date-u')));
  await tester.pumpAndSettle();
  if (!cancel) await tester.tap(find.text('28').last);
  await tester.tap(find.text(cancel ? '取消' : '确定'));
  await tester.pump();
}

Widget panel({
  required Future<List<MeetingCompletionItem>> Function() load,
  required Future<MeetingCompletionItem> Function(
    MeetingCompletionItem,
    String,
    DateTime,
  )
  save,
  int revision = 0,
  bool analysisPending = false,
}) => MaterialApp(
  home: Scaffold(
    body: SingleChildScrollView(
      child: MeetingCompletionPanel(
        sourceId: 'u',
        loadItems: load,
        onConfirm: save,
        dataRevision: revision,
        analysisPending: analysisPending,
      ),
    ),
  ),
);

void main() {
  testWidgets('没有实际缺项时隐藏补全入口，新业务结果到达后才自动出现', (tester) async {
    final recorder = FakeMeetingRecorder();
    final remote = CompletionRemote()..available = false;
    await tester.pumpWidget(
      YanShuApp(
        initialLocation: '/meeting?record=1',
        profileRepository: ProfileRepository(MemoryProfileStore()),
        knowledgeRepository: KnowledgeRepository(MemoryKnowledgeStore()),
        meetingStore: MemoryMeetingStore(),
        meetingRecorder: recorder,
        meetingRemote: remote,
      ),
    );
    await tester.pumpAndSettle();
    final vm = tester
        .element(find.byKey(const ValueKey('meeting-finish')))
        .read<MeetingViewModel>();
    recorder.transcriptEvents.add(
      const MeetingTranscript(
        0,
        '今天先讨论项目情况。',
        isFinal: true,
        speakerId: 'scope:a',
        speakerSeparated: true,
      ),
    );
    await vm.syncCloud();
    await tester.pumpAndSettle();
    final id = vm.record!.utterances.first.id;
    expect(find.byKey(ValueKey('complete-info-$id')), findsNothing);
    expect(find.text('补全 ›'), findsNothing);
    remote.available = true;
    recorder.transcriptEvents.add(
      const MeetingTranscript(
        1,
        '我们会提交报告，交期稍后确认。',
        isFinal: true,
        speakerId: 'scope:b',
        speakerSeparated: true,
      ),
    );
    await vm.syncCloud();
    await tester.pumpAndSettle();
    expect(find.text('补全 ›'), findsWidgets);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('仅缺交期只显示日期，选择后立即保存且收到结果后才显示已确认', (tester) async {
    const item = MeetingCompletionItem(
      id: 'c',
      title: '报告',
      version: 1,
      side: 'ours',
    );
    final gate = Completer<MeetingCompletionItem>();
    var saves = 0;
    await tester.pumpWidget(
      panel(
        load: () async => [item],
        save: (item, side, date) {
          saves++;
          expect(side, 'ours');
          return gate.future;
        },
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('履约方'), findsNothing);
    expect(find.text('交期'), findsOneWidget);
    expect(find.text('确认并执行'), findsNothing);
    expect(find.text('刷新信息'), findsNothing);
    await pickDate(tester);
    expect(saves, 1);
    expect(find.text('保存中…'), findsOneWidget);
    expect(find.text('已确认'), findsNothing);
    gate.complete(confirmed(item, 'ours', DateTime(2026, 11, 28)));
    await tester.pumpAndSettle();
    expect(find.text('已确认'), findsOneWidget);
    expect(find.byKey(const ValueKey('completion-date-u')), findsNothing);
    expect(saves, 1);
  });

  testWidgets('仅缺履约方不显示日期，选择后沿用已有准确交期自动保存', (tester) async {
    final deadline = DateTime(2026, 11, 1, 14, 30);
    final item = MeetingCompletionItem(
      id: 'c',
      title: '报告',
      version: 1,
      deadline: deadline,
    );
    var saves = 0;
    await tester.pumpWidget(
      panel(
        load: () async => [item],
        save: (item, side, date) async {
          saves++;
          expect(side, 'theirs');
          expect(date, deadline);
          return confirmed(item, side, date);
        },
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('交期'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('completion-side-u-对方履约')));
    await tester.pumpAndSettle();
    expect(saves, 1);
    expect(find.text('已确认'), findsOneWidget);
  });

  testWidgets('两项都缺必须全部选齐，取消日期不提交，失败保留选择且不循环重放', (tester) async {
    var version = 1, saves = 0;
    await tester.pumpWidget(
      panel(
        load: () async => [
          MeetingCompletionItem(id: 'c', title: '报告', version: version),
        ],
        save: (item, side, date) async {
          saves++;
          if (item.version == 1) {
            version = 2;
            throw const ApiFailure('conflict', status: 409);
          }
          return confirmed(item, side, date);
        },
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('completion-side-u-我方履约')));
    await tester.pumpAndSettle();
    expect(saves, 0);
    await pickDate(tester, cancel: true);
    await tester.pumpAndSettle();
    expect(saves, 0);
    await pickDate(tester);
    await tester.pumpAndSettle();
    expect(saves, 1);
    expect(find.text('已确认'), findsNothing);
    expect(find.textContaining('重新选择'), findsOneWidget);
    await tester.pump(const Duration(seconds: 20));
    expect(saves, 1);
    await tester.tap(find.byKey(const ValueKey('completion-side-u-我方履约')));
    await tester.pumpAndSettle();
    expect(saves, 2);
    expect(find.text('已确认'), findsOneWidget);
  });

  testWidgets('空结果不渲染固定表单不视为报错，后续业务版本到达自动更新', (tester) async {
    var items = <MeetingCompletionItem>[];
    var reads = 0, saves = 0;
    Future<List<MeetingCompletionItem>> load() async {
      reads++;
      return items;
    }

    Future<MeetingCompletionItem> save(
      MeetingCompletionItem item,
      String side,
      DateTime date,
    ) async {
      saves++;
      return confirmed(item, side, date);
    }

    await tester.pumpWidget(panel(load: load, save: save));
    await tester.pumpAndSettle();
    expect(find.text('这段发言暂无待补全信息'), findsOneWidget);
    expect(find.text('履约方'), findsNothing);
    expect(find.text('交期'), findsNothing);
    expect(find.text('刷新信息'), findsNothing);
    await tester.pump(const Duration(seconds: 60));
    expect(reads, 1);
    items = [
      const MeetingCompletionItem(
        id: 'c',
        title: '报告',
        version: 1,
        side: 'ours',
      ),
    ];
    await tester.pumpWidget(panel(load: load, save: save, revision: 1));
    await tester.pumpAndSettle();
    expect(find.text('交期'), findsOneWidget);
    expect(find.text('履约方'), findsNothing);
    expect(saves, 0);
  });

  testWidgets('打开信息齐全或核对中的记录不会冒充用户授权自动提交', (tester) async {
    var saves = 0;
    await tester.pumpWidget(
      panel(
        load: () async => [
          MeetingCompletionItem(
            id: 'c',
            title: '报告',
            version: 1,
            side: 'ours',
            deadline: DateTime(2026, 11, 1),
          ),
        ],
        save: (item, side, date) async {
          saves++;
          return confirmed(item, side, date);
        },
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('相关信息已齐全，无需重复填写'), findsOneWidget);
    expect(find.text('已确认'), findsNothing);
    expect(saves, 0);
  });

  testWidgets('上下文与补全互斥，收起保留草稿；全部补好自动保存且原话不变', (tester) async {
    tester.view.physicalSize = const Size(390, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final recorder = FakeMeetingRecorder();
    final remote = CompletionRemote();
    await tester.pumpWidget(
      YanShuApp(
        initialLocation: '/meeting?record=1',
        profileRepository: ProfileRepository(MemoryProfileStore()),
        knowledgeRepository: KnowledgeRepository(MemoryKnowledgeStore()),
        meetingStore: MemoryMeetingStore(),
        meetingRecorder: recorder,
        meetingRemote: remote,
      ),
    );
    await tester.pumpAndSettle();
    final vm = tester
        .element(find.byKey(const ValueKey('meeting-finish')))
        .read<MeetingViewModel>();
    recorder.transcriptEvents.add(
      const MeetingTranscript(
        0,
        '我们负责提交报告，交期稍后确认。',
        isFinal: true,
        speakerId: 'scope:a',
        speakerSeparated: true,
      ),
    );
    final id = vm.record!.utterances.first.id;
    vm.record = vm.record!.copy(
      insights: [
        MeetingInsight(
          id: 'inline',
          kind: InsightKind.question,
          title: 'AI 补充',
          body: '交期待确认',
          evidenceIds: [id],
        ),
      ],
    );
    recorder.transcriptEvents.add(
      const MeetingTranscript(
        1,
        '先谈预算',
        isFinal: false,
        speakerId: 'scope:b',
        speakerSeparated: true,
      ),
    );
    await tester.pump();
    await vm.syncCloud();
    await tester.pumpAndSettle();
    final raw = vm.record!.utterances.first.toJson();
    await tester.tap(find.byKey(ValueKey('complete-info-$id')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('completion-side-$id-我方履约')));
    await tester.tap(find.byKey(ValueKey('ai-context-$id')));
    await tester.pumpAndSettle();
    expect(find.byKey(ValueKey('completion-panel-$id')), findsNothing);
    expect(find.text('收起上下文'), findsOneWidget);
    await tester.tap(find.byKey(ValueKey('complete-info-$id')));
    await tester.pumpAndSettle();
    expect(find.byKey(ValueKey('ai-suggestions-$id')), findsNothing);
    await tester.tap(find.byKey(ValueKey('completion-date-$id')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('28').last);
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(remote.confirmations, 1);
    expect(find.text('已确认'), findsOneWidget);
    expect(find.byKey(ValueKey('complete-info-$id')), findsNothing);
    expect(find.text('确认并执行'), findsNothing);
    expect(find.text('刷新信息'), findsNothing);
    expect(vm.record!.utterances.first.toJson(), raw);
    // 晚到的旧版本不能让已保存的履约项重新出现为待补全。
    remote.item = const MeetingCompletionItem(id: 'c', title: '报告', version: 1);
    recorder.transcriptEvents.add(
      const MeetingTranscript(
        1,
        '继续讨论预算。',
        isFinal: true,
        speakerId: 'scope:b',
        speakerSeparated: true,
      ),
    );
    await vm.syncCloud();
    await tester.pumpAndSettle();
    expect(find.byKey(ValueKey('complete-info-$id')), findsNothing);
    expect(find.text('已确认'), findsOneWidget);
    expect(remote.confirmations, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
