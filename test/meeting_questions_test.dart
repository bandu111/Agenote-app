import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:yanshu/features/meeting/meeting_models.dart';
import 'package:yanshu/features/meeting/meeting_questions.dart';
import 'package:yanshu/features/meeting/meeting_store.dart';
import 'package:yanshu/features/meeting/meeting_question_widgets.dart';
import 'package:yanshu/features/meeting/minutes/meeting_evidence_link.dart';
import 'meeting_remote_test.dart' show createMeeting, FakeMeetingRemote;
import 'meeting_test.dart' show FakeMeetingRecorder;

MeetingRecord record({List<MeetingUtterance> utterances = const []}) =>
    MeetingRecord(
      id: 'questions-test',
      startedAt: DateTime(2026),
      demo: false,
      utterances: utterances,
    );

MeetingUtterance speech(
  String id,
  int start,
  int end, {
  String path = '/audio/part.wav',
}) => MeetingUtterance(
  id: id,
  speaker: 'A',
  raw: '原始发言',
  at: Duration(milliseconds: end + 9000),
  audioPath: path,
  audioStart: Duration(milliseconds: start),
  audioEnd: Duration(milliseconds: end),
);

Map<String, dynamic> anchor(int ms) => {
  'atMs': ms + 9000,
  'part': 'part.wav',
  'sample': ms * 16,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('transcript badge opens reusable sheet filtered to its own source', (tester) async {
    final questions = MeetingQuestions(MemoryMeetingStore(), null);
    addTearDown(questions.dispose);
    final r = record(utterances: [speech('u1', 1000, 2000), speech('u2', 20000, 21000)]);
    final first = await questions.create(r, atMs: 10500);
    final second = await questions.create(r, atMs: 29500);
    await questions.edit(r, first, text: '第一段疑问');
    await questions.edit(r, second, text: '第二段疑问');
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: MeetingQuestionList(
      questions: questions, record: r, sourceIds: const ['u1'], transcriptBadge: true,
    ))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('疑问'));
    await tester.pumpAndSettle();
    expect(find.text('本段 1 处'), findsOneWidget);
    expect(find.text('第一段疑问'), findsOneWidget);
    expect(find.text('第二段疑问'), findsNothing);
    await tester.tap(find.text('第一段疑问'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('编辑疑问'));
    await tester.pumpAndSettle();
    expect(find.byKey(ValueKey('live-question-draft-$first')), findsOneWidget);
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'toolbar opens only current meeting marks without explanatory copy or all entry',
    (tester) async {
      final questions = MeetingQuestions(MemoryMeetingStore(), null);
      addTearDown(questions.dispose);
      final current = record();
      final other = MeetingRecord(
        id: 'other-meeting',
        startedAt: DateTime(2026),
        demo: false,
      );
      final id = await questions.create(current, atMs: 12000);
      await questions.edit(current, id, text: '本场的问题');
      final otherId = await questions.create(other, atMs: 1000);
      await questions.edit(other, otherId, text: '其他会议的问题');
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            appBar: AppBar(
              actions: [
                MeetingQuestionList(
                  questions: questions,
                  record: current,
                  toolbar: true,
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('meeting-my-questions')));
      await tester.pumpAndSettle();
      expect(find.text('我的疑问'), findsOneWidget);
      expect(find.text('本场 1 处'), findsOneWidget);
      expect(find.text('本场的问题'), findsOneWidget);
      expect(find.text('其他会议的问题'), findsNothing);
      expect(find.text('查看全部疑问'), findsNothing);
      expect(find.text('会中只留时间点，问题现在补或结束后补都行。'), findsNothing);
      expect(find.text('编辑疑问'), findsNothing);
      await tester.tap(find.text('本场的问题'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('编辑疑问'));
      await tester.pumpAndSettle();
      final field = find.byKey(ValueKey('live-question-draft-$id'));
      expect(field, findsOneWidget);
      expect(find.byType(BottomSheet), findsOneWidget);
      await tester.enterText(field, '修改后的疑问');
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(questions.item(current, id)!['content']['text'], '本场的问题');
      await tester.tap(find.text('编辑疑问'));
      await tester.pumpAndSettle();
      await tester.enterText(field, '修改后的疑问');
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(questions.item(current, id)!['content']['text'], '修改后的疑问');
      expect(field, findsNothing);
      expect(find.text('修改后的疑问'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );



  testWidgets('minutes puts resolved marks last without changing timeline or expanded identity', (tester) async {
    final questions = MeetingQuestions(MemoryMeetingStore(), null);
    addTearDown(questions.dispose);
    final r = record();
    final first = await questions.create(r, atMs: 1000);
    final resolved = await questions.create(r, atMs: 2000);
    final last = await questions.create(r, atMs: 3000);
    await questions.edit(r, first, text: '第一个问题');
    await questions.edit(r, resolved, text: '已解决的问题', status: 'resolved');
    await questions.edit(r, last, text: '后来的问题');
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SingleChildScrollView(
      child: MeetingQuestionList(questions: questions, record: r, minutesStyle: true)))));
    await tester.pumpAndSettle();
    Finder row(String id) => find.byKey(ValueKey('meeting-question-$id'));
    expect(tester.getTopLeft(row(first)).dy, lessThan(tester.getTopLeft(row(last)).dy));
    expect(tester.getTopLeft(row(last)).dy, lessThan(tester.getTopLeft(row(resolved)).dy));
    expect(questions.items(r).map((q) => q['id']), [first, resolved, last]);
    await tester.tap(find.text('第一个问题'));
    await tester.pumpAndSettle();
    expect(find.text('00:01  ·  尚未关联原文'), findsOneWidget);
    await tester.tap(find.text('编辑疑问'));
    await tester.pumpAndSettle();
    final draft = find.byKey(ValueKey('live-question-draft-$first'));
    expect(draft, findsOneWidget);
    expect(find.byType(BottomSheet), findsNothing);
    await tester.enterText(draft, '纪要中编辑后的问题');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(questions.item(r, first)!['content']['text'], '纪要中编辑后的问题');
    expect(draft, findsNothing);
    await questions.edit(r, first, status: 'resolved');
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(row(last)).dy, lessThan(tester.getTopLeft(row(first)).dy));
    expect(tester.getTopLeft(row(first)).dy, lessThan(tester.getTopLeft(row(resolved)).dy));
    expect(find.text('00:01  ·  尚未关联原文'), findsOneWidget);
    expect(find.text('00:03  ·  尚未关联原文'), findsNothing);
    await questions.edit(r, first, status: 'pending');
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(row(first)).dy, lessThan(tester.getTopLeft(row(last)).dy));
    expect(tester.takeException(), isNull);
  });

  testWidgets('recording question list retains chronological order', (tester) async {
    final questions = MeetingQuestions(MemoryMeetingStore(), null);
    addTearDown(questions.dispose);
    final r = record();
    final first = await questions.create(r, atMs: 1000);
    final last = await questions.create(r, atMs: 2000);
    await questions.edit(r, first, status: 'resolved');
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: MeetingQuestionList(questions: questions, record: r))));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.byKey(ValueKey('meeting-question-$first'))).dy,
      lessThan(tester.getTopLeft(find.byKey(ValueKey('meeting-question-$last'))).dy));
  });

  testWidgets('minutes puts mark time and deduplicated evidence links below details', (tester) async {
    final questions = MeetingQuestions(MemoryMeetingStore(), null);
    addTearDown(questions.dispose);
    final r = record(utterances: [speech('u1', 2000, 3000), speech('u2', 4000, 5000)]);
    final id = await questions.create(r, atMs: 12000);
    await questions.edit(r, id, text: '这里具体指什么？');
    questions.item(r, id)!['analysis'] = {'candidates': [], 'answers': [
      {'text': '会议中的参考回答', 'coverage': 'partial', 'evidence': [
        {'id': 'u1', 'atMs': 12000, 'raw': '原始发言'},
        {'id': 'u2', 'atMs': 14000, 'raw': '后续回答原文'},
      ]}
    ]};
    String? opened;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SingleChildScrollView(
      child: MeetingQuestionList(questions: questions, record: r, minutesStyle: true,
        onSource: (id) => opened = id)))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('这里具体指什么？'));
    await tester.pumpAndSettle();
    expect(find.textContaining('标记时间'), findsNothing);
    expect(find.text('查看原始发言'), findsNothing);
    expect(find.byType(MeetingEvidenceLink), findsNWidgets(2));
    final markLink = find.text('00:12  ·  查看原始依据');
    expect(tester.getTopLeft(markLink).dy, greaterThan(tester.getTopLeft(find.text('后续回答原文')).dy));
    expect(find.text('00:13  ·  查看原始依据'), findsOneWidget);
    await tester.ensureVisible(markLink);
    await tester.tap(markLink);
    expect(opened, 'u1');
    expect(tester.takeException(), isNull);
  });

  testWidgets('minutes details use tinted border and label only AI content on narrow dark screen', (tester) async {
    final questions = MeetingQuestions(MemoryMeetingStore(), null);
    addTearDown(questions.dispose);
    final r = record();
    final id = await questions.create(r, atMs: 1000);
    questions.item(r, id)!['analysis'] = {'candidates': ['这项交付具体包含哪些内容？'], 'answers': []};
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(theme: ThemeData.dark(), home: Scaffold(body: SingleChildScrollView(
      child: MeetingQuestionList(questions: questions, record: r, minutesStyle: true)))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('00:01 的疑问 · 尚未填写'));
    await tester.pumpAndSettle();
    expect(find.text('AI 候选问题 · 未经用户确认'), findsOneWidget);
    expect(find.text('AI 推测·未经会议确认'), findsNothing);
    expect(find.byType(Card), findsNothing);
    final containers = tester.widgetList<Container>(find.byType(Container));
    expect(containers.any((c) => c.decoration is BoxDecoration &&
      ((c.decoration as BoxDecoration).border as Border?)?.left.width == 2), isTrue);
    expect(tester.takeException(), isNull);
  });

  test(
    'paused recording accepts marks without restarting or stopping capture',
    () async {
      final recorder = FakeMeetingRecorder();
      final vm = await createMeeting(
        FakeMeetingRemote(),
        MemoryMeetingStore(),
        recorder: recorder,
      );
      await vm.start(demo: false);
      await vm.pause();
      expect(await vm.markQuestion(), isFalse);
      expect(vm.questions.items(vm.record!), isEmpty);
      await vm.addManual('发言人 A', '需要确认交付时间');
      expect(await vm.markQuestion(), isTrue);
      expect(await vm.markQuestion(), isFalse);
      expect(vm.questions.items(vm.record!).length, 1);
      expect(vm.phase, MeetingPhase.paused);
      expect(recorder.starts, 1);
      expect(recorder.stops, 0);
      expect(recorder.resumes, 0);
    },
  );

  testWidgets('unassociated mark is visible and can be edited without AI', (
    tester,
  ) async {
    final questions = MeetingQuestions(MemoryMeetingStore(), null);
    addTearDown(questions.dispose);
    final r = record();
    await questions.create(r, atMs: 12000);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: MeetingQuestionList(questions: questions, record: r),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('我的疑问'), findsOneWidget);
    await tester.tap(find.text('00:12 的疑问 · 尚未填写'));
    await tester.pumpAndSettle();
    expect(find.text('尚未关联转写，时间标记已保留'), findsOneWidget);
    await tester.tap(find.text('编辑疑问'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '这个计划覆盖哪个版本？');
    await tester.ensureVisible(find.text('保存'));
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(questions.items(r).single['content']['text'], '这个计划覆盖哪个版本？');
  });

  test(
    'mark without transcript survives subsequent question edits and deletion',
    () async {
      final questions = MeetingQuestions(MemoryMeetingStore(), null);
      addTearDown(questions.dispose);
      final r = record();
      final id = await questions.create(r, atMs: 12000);
      expect(questions.items(r).single['content']['sourceIds'], isEmpty);
      await questions.edit(r, id, text: '何时交付？');
      await questions.edit(r, id, status: 'resolved');
      expect(questions.item(r, id)!['content']['text'], '何时交付？');
      expect(questions.item(r, id)!['content']['status'], 'resolved');
      await questions.edit(r, id, deleted: true);
      expect(questions.items(r), isEmpty);
    },
  );

  test('sample position wins over a delayed display clock', () {
    final result = questionAssociation({
      ...anchor(2500),
      'atMs': 80000,
    }, record(utterances: [speech('u1', 2000, 3000)]));
    expect(result['sourceIds'], ['u1']);
    expect(result['association'], 'exact');
  });

  test('short gap and exact boundary prefer the preceding speech', () {
    final r = record(
      utterances: [speech('before', 1000, 2000), speech('after', 2000, 3000)],
    );
    expect(questionAssociation(anchor(2000), r)['sourceIds'], ['before']);
    final gap = record(
      utterances: [speech('before', 1000, 2000), speech('after', 4000, 5000)],
    );
    expect(questionAssociation(anchor(3000), gap)['sourceIds'], ['before']);
  });

  test('large gaps and other audio parts stay unassociated', () {
    expect(
      questionAssociation(
        anchor(12000),
        record(utterances: [speech('old', 0, 1000)]),
      )['sourceIds'],
      isEmpty,
    );
    expect(
      questionAssociation(
        anchor(500),
        record(
          utterances: [speech('other', 0, 1000, path: '/audio/other.wav')],
        ),
      )['sourceIds'],
      isEmpty,
    );
  });

  test('cloud audio IDs do not erase a valid local association', () {
    final content = {
      ...anchor(2500),
      'sourceIds': ['u1'],
      'association': 'exact',
    };
    final cloud = record(
      utterances: [speech('u1', 2000, 3000, path: 'yanshu-audio:cloud-id')],
    );
    expect(questionAssociation(content, cloud)['sourceIds'], ['u1']);
  });

  test(
    'editing before archive remains eligible for the first AI analysis',
    () async {
      final questions = MeetingQuestions(MemoryMeetingStore(), null);
      addTearDown(questions.dispose);
      final r = record();
      final id = await questions.create(r, atMs: 1);
      await questions.edit(r, id, text: '交期是什么？');
      expect(questions.item(r, id)!['analysisDue'], isTrue);
      final ended = r.copy(ended: true, cloudMinutes: '已归档');
      await questions.load(ended);
      await questions.edit(ended, id, text: '交付范围是什么？');
      expect(questions.item(r, id)!['analysisDue'], isFalse);
    },
  );

  test(
    'recovered segment replaces derived link without erasing user text',
    () async {
      final questions = MeetingQuestions(MemoryMeetingStore(), null);
      addTearDown(questions.dispose);
      final r = record();
      final id = await questions.create(
        r,
        atMs: 11500,
        part: 'part.wav',
        sample: 40000,
      );
      await questions.edit(r, id, text: '具体指哪个版本？');
      final restored = record(utterances: [speech('recovered-1', 2000, 3000)]);
      await questions.associate(restored);
      expect(questions.item(r, id)!['content']['sourceIds'], ['recovered-1']);
      expect(questions.item(r, id)!['content']['text'], '具体指哪个版本？');
      expect(questions.item(r, id)!['pending'], isTrue);
    },
  );

  test('deleting the meeting hides independent question records', () async {
    final questions = MeetingQuestions(MemoryMeetingStore(), null);
    addTearDown(questions.dispose);
    final r = record();
    await questions.create(r, atMs: 1000);
    await questions.forget(r);
    expect(questions.items(r), isEmpty);
  });
}
