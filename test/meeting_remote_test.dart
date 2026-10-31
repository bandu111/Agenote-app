import 'dart:async';
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yanshu/core/network/api_client.dart';
import 'package:yanshu/core/network/api_config.dart';
import 'package:yanshu/features/meeting/meeting_models.dart';
import 'package:yanshu/features/meeting/meeting_remote.dart';
import 'package:yanshu/features/meeting/meeting_store.dart';
import 'package:yanshu/features/meeting/meeting_view_model.dart';
import 'package:yanshu/features/knowledge/repositories/knowledge_repository.dart';
import 'package:yanshu/features/knowledge/viewmodels/knowledge_view_model.dart';
import 'package:yanshu/features/home/viewmodels/home_view_model.dart';
import 'package:yanshu/features/notifications/notification_model.dart';
import 'dio_auth_repository_test.dart' show TestAdapter, envelope;
import 'meeting_test.dart' show FakeMeetingRecorder, FakeMeetingCalendar;
import 'package:yanshu/features/meeting/local_speech.dart';
import 'package:yanshu/features/meeting/speech_turn.dart';

class FakeTranscriptPolisher extends FakeMeetingRemote
    implements MeetingTranscriptPolisher {
  Completer<String>? gate;
  bool unavailable = false;
  @override
  Future<String> polish(
    MeetingRecord record,
    MeetingUtterance utterance,
  ) async {
    if (unavailable) throw const ApiFailure('服务不可用');
    return gate?.future ?? '我们先评估，不能承诺周三交付。';
  }
}

class FakeMeetingRemote implements MeetingRemoteRepository {
  @override
  String? accountId = 'account-a';
  final sent = <MeetingRecord>[];
  final pauses = <bool>[];
  bool fail = false;
  int analyses = 0;
  List<MeetingRecord> historyRecords = [];
  Map<String, dynamic>? savedArchive;
  Completer<Map<String, dynamic>>? pending;
  final analyzing = Completer<void>();
  @override
  Future<void> sync(MeetingRecord record, {required bool paused}) async {
    if (fail) throw const ApiFailure('断网');
    sent.add(record);
    pauses.add(paused);
  }

  @override
  Future<Map<String, dynamic>> analyze(MeetingRecord record) async {
    analyses++;
    if (!analyzing.isCompleted) analyzing.complete();
    final wait = pending;
    pending = null;
    if (wait != null) return wait.future;
    return {
      'insights': [
        {
          'id': 'current',
          'kind': 'risk',
          'title': '当前结果',
          'body': '评估不等于同意',
          'evidence_ids': [record.utterances.last.id],
        },
      ],
      'repairs': [],
      'withdrawals': [],
    };
  }

  @override
  Future<Map<String, dynamic>> archive(MeetingRecord record) async => {
    'documentId': 'server-document',
    'title': '会议纪要',
    'markdown': '# 云端纪要\n${record.utterances.map((u) => u.raw).join('\n')}',
  };
  @override
  Future<Map<String, dynamic>?> readArchive(MeetingRecord record) async =>
      savedArchive;
  @override
  Future<List<MeetingRecord>> history() async => historyRecords;
}

Future<MeetingViewModel> createMeeting(
  FakeMeetingRemote remote,
  MemoryMeetingStore store, {
  FakeMeetingRecorder? recorder,
  Duration turnQuiet = const Duration(seconds: 5),
  Duration unfinishedQuiet = const Duration(seconds: 9),
  bool disposeViewModel = true,
  Future<void> Function()? onProgressChanged,
  Future<void> Function()? onNoticesChanged,
}) async {
  final knowledge = KnowledgeViewModel(
    KnowledgeRepository(MemoryKnowledgeStore(), seedExamples: true),
  );
  await knowledge.load();
  final vm = MeetingViewModel(
    store: store,
    recorder: recorder ?? FakeMeetingRecorder(),
    calendar: FakeMeetingCalendar(),
    knowledge: knowledge,
    notifications: NotificationModel(),
    home: HomeViewModel(),
    remote: remote,
    onProgressChanged: onProgressChanged,
    onNoticesChanged: onNoticesChanged,
    turnQuiet: turnQuiet,
    unfinishedQuiet: unfinishedQuiet,
  );
  addTearDown(() {
    if (disposeViewModel) vm.dispose();
    knowledge.dispose();
    vm.notifications.dispose();
    vm.home.dispose();
  });
  return vm;
}

class BatchedMeetingRemote extends FakeMeetingRemote {
  final gates = List.generate(3, (_) => Completer<Map<String, dynamic>>());
  final started = List.generate(3, (_) => Completer<void>());
  @override
  Future<Map<String, dynamic>> analyze(MeetingRecord record) async {
    final index = analyses++;
    if (index >= gates.length) return {'insights': []};
    started[index].complete();
    return gates[index].future;
  }
}

Map<String, dynamic> batchFinding(String id, String source) => {
  'insights': [
    {
      'id': id,
      'kind': 'risk',
      'title': id,
      'body': '有原话依据的待核对提示',
      'evidence_ids': [source],
    },
  ],
  'repairs': [],
  'withdrawals': [],
};

class CorePreviewRemote extends FakeMeetingRemote
    implements StreamingMeetingAnalysis {
  final coreReady = Completer<void>();
  final auxiliary = Completer<Map<String, dynamic>>();
  @override
  Future<Map<String, dynamic>> analyzeWithUpdates(
    MeetingRecord record,
    void Function(Map<String, dynamic>) onPreview,
  ) async {
    onPreview(batchFinding('核心风险先显示', record.utterances.first.id));
    coreReady.complete();
    return auxiliary.future;
  }
}

class IndependentLiveRemote extends FakeMeetingRemote
    implements LiveMeetingAnalysis {
  int liveCalls = 0;
  @override
  Future<void> liveHints(
    MeetingRecord record,
    void Function(Map<String, dynamic>) onUpdate,
  ) async {
    liveCalls++;
    onUpdate(
      batchFinding(
        'live-${record.utterances.last.id}',
        record.utterances.last.id,
      ),
    );
  }
}

class NoisyMeetingRecorder extends FakeMeetingRecorder {
  final amplitudes = StreamController<double>.broadcast(sync: true);
  @override
  Stream<double> get levels => amplitudes.stream;
  @override
  Future<void> dispose() async {
    await amplitudes.close();
  }
}

class ChunkedLiveRemote extends FakeMeetingRemote
    implements LiveMeetingAnalysis {
  final started = Completer<void>();
  final release = Completer<void>();
  void Function(Map<String, dynamic>)? emit;
  @override
  Future<void> liveHints(
    MeetingRecord record,
    void Function(Map<String, dynamic>) onUpdate,
  ) async {
    emit = onUpdate;
    if (!started.isCompleted) started.complete();
    await release.future;
    onUpdate({'event': 'done', 'insights': []});
  }
}

class BusinessMeetingRemote extends FakeMeetingRemote
    implements RealtimeMeetingBusiness {
  bool previewBeforeReview = false;
  final firstBusiness = Completer<void>();
  final release = Completer<void>();
  final businessSources = <MeetingRecord>[];
  @override
  Future<void> updateBusiness(
    MeetingRecord record,
    void Function(Map<String, dynamic>) onUpdate,
  ) async {
    businessSources.add(record);
    if (previewBeforeReview) {
      onUpdate({
        'event': 'preview',
        'business_updated': true,
        'review_pending': true,
      });
    }
    if (!firstBusiness.isCompleted) {
      firstBusiness.complete();
      await release.future;
    }
    onUpdate({'event': 'done', 'business_updated': true});
  }
}

class BusinessCorePreviewRemote extends BusinessMeetingRemote
    implements StreamingMeetingAnalysis {
  final fullRelease = Completer<void>();
  void Function(Map<String, dynamic>)? emitCore;
  MeetingRecord? fullSource;
  @override
  Future<Map<String, dynamic>> analyzeWithUpdates(
    MeetingRecord record,
    void Function(Map<String, dynamic>) onPreview,
  ) async {
    analyses++;
    fullSource = record;
    emitCore = onPreview;
    await fullRelease.future;
    return {'insights': []};
  }
}

void main() {
  testWidgets('一直说话仍在会中分析关键片段，不暂停且不拆同一发言组', (tester) async {
    final remote = BusinessCorePreviewRemote();
    remote.release.complete();
    final recorder = NoisyMeetingRecorder();
    final vm = await createMeeting(
      remote,
      MemoryMeetingStore(),
      recorder: recorder,
      disposeViewModel: false,
    );
    await vm.start(demo: false);
    final voice = Timer.periodic(
      const Duration(milliseconds: 200),
      (_) => recorder.amplitudes.add(.025),
    );
    recorder.transcriptEvents.add(
      const MeetingTranscript(
        0,
        '我们现在还不能承诺下周上线，ERP接口仍然超时，验收必须先通过。',
        isFinal: true,
        speakerId: 'a',
        speakerSeparated: true,
        audioStart: Duration.zero,
        audioEnd: Duration(seconds: 8),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
    expect(vm.record!.utterances.single.turnStatus, 'pending');
    recorder.transcriptEvents.add(
      const MeetingTranscript(1, '接下来我们还要继续讨论', isFinal: false),
    );
    // 麦克风持续有声音，临时字幕也一直非空；不等待静音或按结束。
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(seconds: 1));
      recorder.transcriptEvents.add(
        MeetingTranscript(1, '接下来我们继续讨论其他第$i个事项', isFinal: false),
      );
    }
    expect(
      vm.record!.utterances.single.turnStatus,
      'complete',
      reason: '只放行已完整的关键片段',
    );
    expect(remote.businessSources, isNotEmpty);
    expect(remote.analyses, 1);
    expect(remote.fullRelease.isCompleted, isFalse);
    final id = vm.record!.utterances.single.id;
    remote.emitCore!({
      'insights': [
        {
          'id': 'during-meeting',
          'kind': 'risk',
          'title': '上线条件需核对',
          'body': '接口超时尚未解决，不应直接确认上线。',
          'evidence_ids': [id],
          'streaming': true,
        },
      ],
    });
    await tester.pump();
    expect(vm.record!.insights.any((i) => i.id == 'during-meeting'), isTrue);
    expect(vm.partial, isNotEmpty);
    recorder.transcriptEvents.add(
      const MeetingTranscript(
        1,
        '接下来我们继续讨论其他事项。',
        isFinal: true,
        speakerId: 'a',
        speakerSeparated: true,
        audioStart: Duration(seconds: 8),
        audioEnd: Duration(seconds: 14),
      ),
    );
    await tester.pump();
    expect(speechTurnGroups(vm.record!.utterances), hasLength(1));
    expect(vm.phase, MeetingPhase.recording);
    expect(recorder.pauses, 0);
    expect(recorder.stops, 0);
    voice.cancel();
    vm.dispose();
    remote.fullRelease.complete();
    await tester.pump();
  });

  testWidgets('关键片段合批限频，半句和接着说话不逐句启动完整分析', (tester) async {
    final remote = FakeMeetingRemote();
    final recorder = NoisyMeetingRecorder();
    final vm = await createMeeting(
      remote,
      MemoryMeetingStore(),
      recorder: recorder,
      disposeViewModel: false,
    );
    await vm.start(demo: false);
    final voice = Timer.periodic(
      const Duration(milliseconds: 200),
      (_) => recorder.amplitudes.add(.025),
    );
    final events = recorder.transcriptEvents;
    events.add(const MeetingTranscript(0, '验收标准我们就按', isFinal: true));
    await tester.pump(const Duration(seconds: 2));
    expect(remote.analyses, 0);
    expect(vm.record!.utterances.single.turnStatus, 'pending');
    events.add(
      const MeetingTranscript(1, '双方确认的功能清单，尚未批准新增平台。', isFinal: true),
    );
    await tester.pump(const Duration(milliseconds: 1300));
    expect(
      vm.record!.utterances.take(2).every((u) => u.turnStatus == 'complete'),
      isTrue,
    );
    events.add(
      const MeetingTranscript(2, '我们还不能承诺下周上线，ERP问题尚未解决。', isFinal: true),
    );
    await tester.pump(const Duration(milliseconds: 1300));
    expect(
      vm.record!.utterances.last.turnStatus,
      'pending',
      reason: '新片段先合批，不逐句发起模型工作',
    );
    // 保持持续字幕，阻止静音收尾，冷却到期仍自动放行下一段。
    events.add(const MeetingTranscript(3, '我们继续说', isFinal: false));
    await tester.pump(const Duration(seconds: 9));
    expect(vm.record!.utterances.last.turnStatus, 'complete');
    expect(remote.analyses, lessThanOrEqualTo(2));
    expect(recorder.pauses, 0);
    voice.cancel();
    vm.dispose();
  });

  testWidgets('持续讨论不需要十秒静默，早先原话有效就继续显示风险及拼图', (tester) async {
    final remote = BusinessCorePreviewRemote();
    remote.release.complete();
    final vm = await createMeeting(
      remote,
      MemoryMeetingStore(),
      disposeViewModel: false,
    );
    await vm.start(demo: false);
    await vm.addManual('发言人 A', '验收标准我们就按……');
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(seconds: 1));
      await vm.addManual('发言人 B', '继续讨论第$i个问题。');
    }
    expect(remote.analyses, 1, reason: '固定批次启动，不被持续发言重置');
    final original = remote.fullSource!.utterances.first;
    expect(vm.coreHintsLoading, isTrue, reason: '正文还没返回时展示独立骨架');
    final placeholderAnchor = vm.coreHintAnchorId;
    remote.emitCore!({
      'insights': [
        {
          'id': 'verified-risk',
          'kind': 'risk',
          'title': '验收条件未明确',
          'body': '验',
          'evidence_ids': [original.id],
          'streaming': true,
        },
      ],
    });
    await tester.pump();
    expect(vm.coreHintsLoading, isFalse, reason: '收到第一个正文字符就显示，不等待最终结果');
    expect(vm.record!.insights.single.body, '验');
    expect(remote.fullRelease.isCompleted, isFalse);
    expect(vm.coreHintAnchorId, placeholderAnchor, reason: '新发言不带走当前加载位置');
    remote.emitCore!({
      'insights': [
        {
          'id': 'verified-risk',
          'kind': 'risk',
          'title': '验收条件未明确',
          'body': '需核对验收指标。',
          'evidence_ids': [original.id],
        },
        {
          'id': 'verified-forecast',
          'kind': 'prediction',
          'title': '后续讨论方向',
          'body': '对方可能追问通过率。',
          'evidence_ids': [original.id],
        },
      ],
      'repairs': [
        {
          'target_id': original.id,
          'start': original.raw.length,
          'end': original.raw.length,
          'text': '需要确认的验收指标',
          'evidence_ids': [original.id],
        },
      ],
    });
    await tester.pump();
    expect(vm.record!.insights, hasLength(1), reason: '追问同一验收指标不重复显示成前瞻卡片');
    expect(vm.record!.insights.single.id, 'verified-risk');
    expect(vm.record!.utterances.first.repair?.text, '需要确认的验收指标');
    // 新发言不能丢掉旧来源的有效预览，但人工纠错后必须拒绝旧快照。
    await vm.correct(original.id, '人工确认的新验收要求');
    remote.emitCore!({
      'insights': [
        {
          'id': 'stale',
          'kind': 'risk',
          'title': '旧结果',
          'body': '过期',
          'evidence_ids': [original.id],
        },
      ],
    });
    expect(vm.record!.insights.any((i) => i.id == 'stale'), isFalse);
    vm.dispose();
    remote.fullRelease.complete();
    await tester.pump();
  });

  testWidgets('行动候选就绪立即刷新通知，不等待完整分析或后续复核', (tester) async {
    final remote = BusinessMeetingRemote()..previewBeforeReview = true;
    var notices = 0;
    final vm = await createMeeting(
      remote,
      MemoryMeetingStore(),
      disposeViewModel: false,
      onNoticesChanged: () async {
        notices++;
      },
    );
    await vm.start(demo: false);
    await vm.addManual('发言人 A', '确认明天下午两点到两点半评审，请创建日程。');
    await tester.pump(const Duration(milliseconds: 500));
    expect(remote.businessSources, hasLength(1));
    expect(remote.release.isCompleted, isFalse);
    expect(notices, 1, reason: '日程、任务、撤回等审批共用全局通知刷新');
    remote.release.complete();
    await tester.pump();
    expect(notices, 2);
    vm.dispose();
  });

  testWidgets('中间字幕缺少话者编号不能把同一个人的连续发言切开', (tester) async {
    final recorder = FakeMeetingRecorder();
    final remote = FakeMeetingRemote();
    final vm = await createMeeting(
      remote,
      MemoryMeetingStore(),
      recorder: recorder,
      disposeViewModel: false,
    );
    await vm.start(demo: false);
    final events = recorder.transcriptEvents;
    events.add(
      const MeetingTranscript(
        0,
        '今天我们主要讨论三个事情。',
        isFinal: true,
        speakerId: 'a',
        speakerSeparated: true,
        audioStart: Duration.zero,
        audioEnd: Duration(seconds: 4),
      ),
    );
    await tester.pump(const Duration(seconds: 1));
    events.add(
      const MeetingTranscript(
        1,
        '第一个是',
        isFinal: false,
        audioStart: Duration(seconds: 5),
        audioEnd: Duration(seconds: 6),
      ),
    );
    await tester.pump(const Duration(seconds: 6));
    expect(vm.record!.utterances.single.turnStatus, 'pending');
    expect(vm.partialSpeaker, '待区分发言人', reason: '不能把未知身份字幕猜成A');
    expect(vm.partial, '第一个是');
    events.add(
      const MeetingTranscript(
        1,
        '第一个是工单试点的情况。',
        isFinal: true,
        speakerId: 'a',
        speakerSeparated: true,
        audioStart: Duration(seconds: 5),
        audioEnd: Duration(seconds: 11),
      ),
    );
    await tester.pump();
    expect(
      vm.record!.utterances.every((u) => u.turnStatus == 'pending'),
      isTrue,
    );
    expect(speechTurnGroups(vm.record!.utterances), hasLength(1));
    expect(remote.analyses, 0);
    events.add(const MeetingTranscript(2, '等一下', isFinal: false));
    await tester.pump();
    events.add(
      const MeetingTranscript(
        2,
        '等一下，我补充一个风险。',
        isFinal: true,
        speakerId: 'b',
        speakerSeparated: true,
      ),
    );
    await tester.pump();
    expect(
      speechTurnGroups(vm.record!.utterances),
      hasLength(2),
      reason: '最终确认B后及时分开',
    );
    expect(vm.record!.utterances.last.speaker, '发言人 B');
    vm.dispose();
  });

  testWidgets('最终片段缺少身份不假装换人，也不把匿名原话标成前一个人', (tester) async {
    final recorder = FakeMeetingRecorder();
    final vm = await createMeeting(
      FakeMeetingRemote(),
      MemoryMeetingStore(),
      recorder: recorder,
      disposeViewModel: false,
    );
    await vm.start(demo: false);
    final events = recorder.transcriptEvents;
    events.add(
      const MeetingTranscript(
        0,
        '今天先讨论试点。',
        isFinal: true,
        speakerId: 'a',
        speakerSeparated: true,
      ),
    );
    events.add(const MeetingTranscript(1, '还有没有解决的问题。', isFinal: true));
    events.add(
      const MeetingTranscript(
        2,
        '最后讨论下周上线。',
        isFinal: true,
        speakerId: 'a',
        speakerSeparated: true,
      ),
    );
    await tester.pump();
    expect(vm.record!.utterances.map((u) => u.turnId).toSet(), hasLength(1));
    expect(
      vm.record!.utterances.every((u) => u.turnStatus == 'pending'),
      isTrue,
    );
    expect(vm.record!.utterances[1].speakerSeparated, isFalse);
    expect(vm.record!.utterances[1].speaker, '待区分发言人');
    expect(
      speechTurnGroups(vm.record!.utterances),
      hasLength(3),
      reason: '不把未确认身份混入A的展示',
    );
    vm.dispose();
  });

  testWidgets('虚构会议开场27秒：实时保存ASR分句，慢速停顿不提前分析', (tester) async {
    final recorder = NoisyMeetingRecorder();
    final remote = FakeMeetingRemote();
    final vm = await createMeeting(
      remote,
      MemoryMeetingStore(),
      recorder: recorder,
      disposeViewModel: false,
    );
    await vm.start(demo: false);
    // 来自用户提供的虚构会议稿；仅回放事件，不预置进应用或账户数据。
    final sentences = [
      '好，人应该都到齐了吧？那我们开始。',
      '今天会议尽量控制在十分钟左右，主要讨论三个事情。',
      '第一个是目前工单系统试点运行的情况，',
      '第二个是还没有解决的问题，',
      '第三个就是下周到底能不能正式上线。',
      '我们今天最好把具体时间和负责人定下来，避免后面又反复沟通。',
      '乙，你先说一下技术这边的进度吧。',
    ];
    final ends = [5, 9, 13, 16, 18, 25, 27];
    var previous = 0;
    for (var i = 0; i < sentences.length; i++) {
      for (var t = previous; t < ends[i]; t++) {
        // 句间留出三秒正常思考停顿，其余时段仍在讲话。
        if (t - previous >= 3) recorder.amplitudes.add(.025);
        await tester.pump(const Duration(seconds: 1));
      }
      recorder.transcriptEvents.add(
        MeetingTranscript(
          i,
          sentences[i],
          isFinal: true,
          speakerId: 'session:a',
          speakerSeparated: true,
          audioStart: Duration(seconds: previous),
          audioEnd: Duration(seconds: ends[i]),
        ),
      );
      await tester.pump();
      expect(vm.record!.utterances.length, i + 1, reason: '稳定原话立即可见');
      expect(
        vm.record!.utterances.every((u) => u.turnStatus == 'pending'),
        isTrue,
      );
      expect(remote.analyses, 0, reason: '不能把ASR句号当成发言完成');
      expect(speechTurnGroups(vm.record!.utterances), hasLength(1));
      previous = ends[i];
    }
    recorder.transcriptEvents.add(
      const MeetingTranscript(
        7,
        '好的。目前系统主要功能基本都已经开发完成了。',
        isFinal: true,
        speakerId: 'session:b',
        speakerSeparated: true,
        audioStart: Duration(seconds: 27),
        audioEnd: Duration(seconds: 32),
      ),
    );
    await tester.pump();
    expect(
      vm.record!.utterances.take(7).every((u) => u.turnStatus == 'complete'),
      isTrue,
    );
    expect(vm.record!.utterances.last.turnStatus, 'pending');
    expect(speechTurnGroups(vm.record!.utterances), hasLength(2));
    expect(vm.record!.utterances.take(7).map((u) => u.raw), sentences);
    expect(recorder.pauses, 0);
    vm.dispose();
  });

  testWidgets('慢速句间停顿、真正打断及静音收尾分别处理', (tester) async {
    final recorder = FakeMeetingRecorder();
    final vm = await createMeeting(
      FakeMeetingRemote(),
      MemoryMeetingStore(),
      recorder: recorder,
      disposeViewModel: false,
    );
    await vm.start(demo: false);
    recorder.transcriptEvents.add(
      const MeetingTranscript(
        0,
        '我们今天先讨论试点情况。',
        isFinal: true,
        speakerId: 'a',
        speakerSeparated: true,
      ),
    );
    await tester.pump(const Duration(seconds: 3));
    expect(vm.record!.utterances.single.turnStatus, 'pending');
    recorder.transcriptEvents.add(
      const MeetingTranscript(
        1,
        '第二个事情是',
        isFinal: true,
        speakerId: 'a',
        speakerSeparated: true,
      ),
    );
    await tester.pump(const Duration(seconds: 6));
    expect(
      vm.record!.utterances.every((u) => u.turnStatus == 'pending'),
      isTrue,
    );
    recorder.transcriptEvents.add(
      const MeetingTranscript(
        2,
        '等一下，这个我补充一下。',
        isFinal: true,
        speakerId: 'b',
        speakerSeparated: true,
      ),
    );
    await tester.pump();
    expect(
      vm.record!.utterances.take(2).every((u) => u.turnStatus == 'interrupted'),
      isTrue,
    );
    expect(speechTurnGroups(vm.record!.utterances), hasLength(2));
    await tester.pump(const Duration(seconds: 5));
    expect(vm.record!.utterances.last.turnStatus, 'complete');
    expect(recorder.pauses, 0);
    vm.dispose();
  });
  test('短促插话即刻收尾为中断，不等待静音也不自动猜测同一人', () async {
    final remote = FakeMeetingRemote();
    final vm = await createMeeting(remote, MemoryMeetingStore());
    await vm.start(demo: false);
    final events = (vm.recorder as FakeMeetingRecorder).transcriptEvents;
    events.add(
      const MeetingTranscript(
        0,
        '验收标准我们就按',
        isFinal: true,
        speakerId: 'a',
        speakerSeparated: true,
        audioStart: Duration.zero,
        audioEnd: Duration(milliseconds: 800),
      ),
    );
    events.add(
      const MeetingTranscript(
        1,
        '先说账号。',
        isFinal: true,
        speakerId: 'b',
        speakerSeparated: true,
        audioStart: Duration(milliseconds: 810),
        audioEnd: Duration(milliseconds: 1600),
      ),
    );
    expect(vm.record!.utterances.first.turnStatus, 'interrupted');
    expect(vm.record!.utterances.last.turnStatus, 'pending');
    expect(vm.record!.utterances.map((u) => u.turnId).toSet(), hasLength(2));
    expect(vm.record!.utterances.first.raw, '验收标准我们就按');
    expect(vm.phase, MeetingPhase.recording);
  });
  TestWidgetsFlutterBinding.ensureInitialized();
  test('候选就绪时刷新业务，不等待独立复核结束', () async {
    final remote = BusinessMeetingRemote()..previewBeforeReview = true;
    var refreshes = 0;
    final vm = await createMeeting(
      remote,
      MemoryMeetingStore(),
      onProgressChanged: () async {
        refreshes++;
      },
    );
    await vm.start(demo: false);
    await vm.addManual('发言人 A', '本期目标完成双端测试。');
    await remote.firstBusiness.future.timeout(const Duration(seconds: 2));
    expect(remote.release.isCompleted, isFalse);
    expect(refreshes, 1);
    remote.release.complete();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(refreshes, 2);
  });
  test('业务分析等待时后续发言继续上传，并合并最新批次立即刷新进展和首页', () async {
    final remote = BusinessMeetingRemote();
    var refreshes = 0;
    final vm = await createMeeting(
      remote,
      MemoryMeetingStore(),
      onProgressChanged: () async {
        refreshes++;
      },
    );
    await vm.start(demo: false);
    await vm.addManual('发言人 A', '本期目标完成双端测试。');
    await remote.firstBusiness.future.timeout(const Duration(seconds: 2));
    await vm.addManual('发言人 B', '对方周五提供测试账号。');
    await Future<void>.delayed(const Duration(milliseconds: 700));
    expect(remote.release.isCompleted, isFalse);
    expect(remote.sent.last.utterances.length, 2, reason: '不能排在上一轮模型等待之后');
    expect(remote.businessSources.length, 1);
    expect(
      remote.sent.map((s) => s.syncRevision).toSet().length,
      remote.sent.length,
    );
    remote.release.complete();
    final deadline = DateTime.now().add(const Duration(seconds: 2));
    while (refreshes < 2 && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(remote.businessSources.last.utterances.length, 2);
    expect(refreshes, 2);
    expect(remote.analyses, 0, reason: '会中小批次不等完整分析或问卷');
    expect((vm.recorder as FakeMeetingRecorder).pauses, 0);
  });

  test('会中业务晚返回不得越过账户切换刷新其他账户', () async {
    final remote = BusinessMeetingRemote();
    var refreshes = 0;
    final vm = await createMeeting(
      remote,
      MemoryMeetingStore(),
      onProgressChanged: () async {
        refreshes++;
      },
    );
    await vm.start(demo: false);
    await vm.addManual('发言人 A', '本期交付双端。');
    await remote.firstBusiness.future.timeout(const Duration(seconds: 2));
    remote.accountId = 'other-account';
    remote.release.complete();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(refreshes, 0);
  });
  test('只有补句增量也立即收起骨架，并在原发言缺口持续增长', () async {
    final remote = ChunkedLiveRemote();
    final vm = await createMeeting(remote, MemoryMeetingStore());
    await vm.start(demo: false);
    await vm.addManual('发言人 A', '现在确认……');
    await remote.started.future.timeout(const Duration(seconds: 2));
    expect(vm.liveHintsLoading, isTrue);
    final sourceId = vm.record!.utterances.first.id;
    expect(vm.liveHintAnchorId, sourceId);
    await vm.addManual('发言人 B', '我们先继续讨论预算。');
    expect(vm.liveHintAnchorId, sourceId, reason: '新发言不能带走旧发言的加载位置');
    void prefix(String text, {bool complete = false}) => remote.emit!({
      'event': complete ? 'done' : 'preview',
      'insights': [],
      'repairs': [
        {
          'target_id': sourceId,
          'start': 4,
          'end': 6,
          'text': text,
          'evidence_ids': [sourceId],
          'streaming': !complete,
        },
      ],
    });
    prefix('功能');
    expect(remote.release.isCompleted, isFalse);
    expect(vm.liveHintsLoading, isFalse);
    expect(vm.record!.utterances.first.repair!.text, '功能');
    expect(vm.record!.utterances.first.repair!.streaming, isTrue);
    prefix('功能清单');
    expect(vm.record!.utterances.first.repair!.text, '功能清单');
    expect(vm.record!.utterances.first.repairContext, ('现在确认', ''));
    prefix('功能清单', complete: true);
    expect(vm.record!.utterances.first.repair!.streaming, isFalse);
    expect(vm.record!.utterances.first.repair!.interrupted, isFalse);
    expect(vm.record!.utterances.first.raw, '现在确认……');
    remote.release.complete();
    await Future<void>.delayed(const Duration(milliseconds: 20));
  });
  test('模型首段替换骨架，继续说话保留半截卡片，末帧缺失标明中断', () async {
    final remote = ChunkedLiveRemote();
    final vm = await createMeeting(remote, MemoryMeetingStore());
    await vm.start(demo: false);
    await vm.addManual('发言人 A', '新增范围还没批准。');
    await remote.started.future.timeout(const Duration(seconds: 2));
    expect(vm.liveHintsLoading, isTrue);
    final sourceId = vm.record!.utterances.first.id;
    remote.emit!({
      'event': 'preview',
      'insights': [
        {
          'id': 'partial-live',
          'kind': 'risk',
          'title': '范围',
          'body': '可能增加',
          'evidence_ids': [sourceId],
          'streaming': true,
        },
      ],
    });
    expect(vm.liveHintsLoading, isFalse);
    expect(vm.record!.insights.single.streaming, isTrue);
    await vm.addManual('发言人 B', '我们继续讨论预算。');
    expect(vm.record!.insights.single.body, '可能增加');
    remote.release.complete();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(vm.record!.insights.single.interrupted, isTrue);
    expect(vm.record!.insights.single.streaming, isFalse);
    expect(vm.record!.utterances.first.raw, '新增范围还没批准。');
  });
  test('完整分析未结束时，新发言仍走独立提示通道', () async {
    final gate = Completer<Map<String, dynamic>>();
    final remote = IndependentLiveRemote()..pending = gate;
    final vm = await createMeeting(remote, MemoryMeetingStore());
    await vm.start(demo: false);
    await vm.addManual('发言人 A', '旧交期维持三十天。');
    final work = vm.syncCloud();
    await remote.analyzing.future;
    try {
      await vm.addManual('发言人 A', '新范围还没批准，请先核对。');
      final latestId = vm.record!.utterances.last.id;
      await Future<void>.delayed(const Duration(milliseconds: 2300));
      expect(gate.isCompleted, isFalse);
      expect(remote.liveCalls, greaterThan(0));
      expect(vm.record!.insights.any((i) => i.id == 'live-$latestId'), isTrue);
      expect(vm.record!.commitments, isEmpty);
    } finally {
      gate.complete({'insights': []});
      await work;
    }
    expect(
      vm.record!.insights.any((i) => i.id.startsWith('live-')),
      isTrue,
      reason: '完整分析空结果不能清掉先到的实时提示',
    );
    final sourceId = vm.record!.utterances.last.id;
    await vm.correct(sourceId, '人工修正后需要重新核对');
    expect(
      vm.record!.insights.any((i) => i.id == 'live-$sourceId'),
      isFalse,
      reason: '人工改变对应原话时才清除失效提示',
    );
  });

  test('持续背景音不阻塞收尾，多发言人自动转写分析且不暂停重启', () async {
    final remote = FakeMeetingRemote();
    final recorder = NoisyMeetingRecorder();
    final vm = await createMeeting(
      remote,
      MemoryMeetingStore(),
      recorder: recorder,
      turnQuiet: const Duration(milliseconds: 40),
      unfinishedQuiet: const Duration(milliseconds: 120),
    );
    await vm.start(demo: false);
    final noise = Timer.periodic(
      const Duration(milliseconds: 5),
      (_) => recorder.amplitudes.add(.08),
    );
    addTearDown(noise.cancel);
    recorder.transcriptEvents.add(
      const MeetingTranscript(
        0,
        '原交付范围维持不变。',
        isFinal: true,
        speakerId: 's:0',
        speakerSeparated: true,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 220));
    expect(vm.record!.utterances.single.turnStatus, 'complete');
    recorder.transcriptEvents.add(
      const MeetingTranscript(
        1,
        '桌面端还需要',
        isFinal: false,
        speakerId: 's:1',
        speakerSeparated: true,
      ),
    );
    expect(vm.partial, '桌面端还需要');
    await Future<void>.delayed(const Duration(milliseconds: 180));
    expect(vm.record!.utterances.length, 1);
    recorder.transcriptEvents.add(
      const MeetingTranscript(
        1,
        '桌面端还需要评估，尚未批准。',
        isFinal: true,
        speakerId: 's:1',
        speakerSeparated: true,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 220));
    recorder.transcriptEvents.add(
      const MeetingTranscript(
        2,
        '我们继续按原计划推进。',
        isFinal: true,
        speakerId: 's:0',
        speakerSeparated: true,
      ),
    );
    await Future<void>.delayed(const Duration(seconds: 4));
    expect(vm.record!.utterances.map((u) => u.speaker), [
      '发言人 A',
      '发言人 B',
      '发言人 A',
    ]);
    expect(
      vm.record!.utterances.every((u) => u.turnStatus == 'complete'),
      isTrue,
    );
    expect(remote.analyses, greaterThan(0));
    expect(recorder.pauses, 0);
    expect(recorder.resumes, 0);
    expect(recorder.starts, 1);
    expect(vm.phase, MeetingPhase.recording);
    noise.cancel();
  });

  test('未配置服务与未认证状态明确显示，不冒充AI已经连接', () async {
    final remote = FakeMeetingRemote()..accountId = null;
    final vm = await createMeeting(remote, MemoryMeetingStore());
    expect(vm.analysisStatus, '请登录以启用会议AI');
    remote.accountId = 'account-a';
    expect(vm.analysisStatus, '等待完整发言后自动分析');
    expect(vm.recordingStatus, isNot(contains('待接入')));
  });

  test('同步失败后没有新发言也自动恢复分析，不需要暂停或重新开始', () async {
    final remote = FakeMeetingRemote()..fail = true;
    final recorder = NoisyMeetingRecorder();
    final vm = await createMeeting(
      remote,
      MemoryMeetingStore(),
      recorder: recorder,
      turnQuiet: const Duration(milliseconds: 40),
      unfinishedQuiet: const Duration(milliseconds: 120),
    );
    await vm.start(demo: false);
    recorder.transcriptEvents.add(
      const MeetingTranscript(0, '范围尚未批准，保持原计划。', isFinal: true),
    );
    await Future<void>.delayed(const Duration(milliseconds: 70));
    await vm.syncCloud();
    expect(vm.cloudError, isNotNull);
    remote.fail = false;
    await Future<void>.delayed(const Duration(seconds: 6));
    expect(remote.analyses, greaterThan(0));
    expect(vm.cloudError, isNull);
    expect(recorder.starts, 1);
    expect(recorder.pauses, 0);
    expect(vm.analysisStatus, contains('已分析'));
  });

  test('核心提示先返回，不等待问卷完成，不改变原话或停止录音', () async {
    final remote = CorePreviewRemote();
    final vm = await createMeeting(remote, MemoryMeetingStore());
    await vm.start(demo: false);
    await vm.addManual('发言人 A', '新增Windows尚未批准，原计划保留。');
    final work = vm.syncCloud();
    await remote.coreReady.future;
    expect(vm.record!.insights.single.title, '核心风险先显示');
    expect(vm.cloudAnalyzing, isTrue);
    expect(vm.analysisStatus, contains('核心提示已返回'));
    expect(vm.record!.utterances.single.raw, '新增Windows尚未批准，原计划保留。');
    expect(vm.phase, MeetingPhase.recording);
    remote.auxiliary.complete(
      batchFinding('最终提示', vm.record!.utterances.first.id),
    );
    await work;
    expect(vm.record!.insights.map((i) => i.title), ['最终提示']);
    expect(vm.record!.insights, hasLength(1), reason: '相同来源和内容的最终复核更新原建议');
    expect(
      vm.notifications.items.where((n) => n.title.startsWith('会议预警')),
      isEmpty,
      reason: '只读建议留在上下文，不制造需要用户确认的通知',
    );
    expect((vm.recorder as FakeMeetingRecorder).pauses, 0);
  });

  test('连续说话只同步证据，自动收尾后才分析，不需要暂停或发送', () async {
    final remote = FakeMeetingRemote();
    final vm = await createMeeting(remote, MemoryMeetingStore());
    await vm.start(demo: false);
    for (var i = 0; i < 5; i++) {
      (vm.recorder as FakeMeetingRecorder).transcriptEvents.add(
        MeetingTranscript(i, '连续发言$i', isFinal: true),
      );
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    expect(remote.sent, isNotEmpty);
    expect(remote.analyses, 0);
    expect(
      vm.record!.utterances.every((u) => u.turnStatus == 'pending'),
      isTrue,
    );
    await vm.waitForPolish();
    await vm.syncCloud();
    expect(remote.analyses, greaterThan(0));
    expect(vm.phase, MeetingPhase.recording);
    expect((vm.recorder as FakeMeetingRecorder).pauses, 0);
    expect(remote.pauses.every((paused) => !paused), isTrue);
  });

  test('短句等待续接，临时转写阻止提前收尾；半句和单字不产生完整业务发言', () async {
    final remote = FakeMeetingRemote();
    final vm = await createMeeting(
      remote,
      MemoryMeetingStore(),
      turnQuiet: const Duration(milliseconds: 80),
      unfinishedQuiet: const Duration(milliseconds: 180),
    );
    await vm.start(demo: false);
    final events = (vm.recorder as FakeMeetingRecorder).transcriptEvents;
    events.add(const MeetingTranscript(0, '我', isFinal: true));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(vm.record!.utterances.single.turnStatus, 'pending');
    events.add(const MeetingTranscript(1, '我们讨论的交期', isFinal: false));
    await Future<void>.delayed(const Duration(milliseconds: 220));
    await vm.syncCloud();
    expect(remote.analyses, 0);
    events.add(const MeetingTranscript(1, '们考虑下周三，但还没确定。', isFinal: true));
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(
      vm.record!.utterances.every((u) => u.turnStatus == 'complete'),
      isTrue,
    );
    expect(vm.record!.utterances.map((u) => u.turnId).toSet().length, 1);
    await vm.syncCloud();
    expect(remote.analyses, 1);
    events.add(const MeetingTranscript(2, '关于交付，我们需要', isFinal: true));
    await Future<void>.delayed(const Duration(milliseconds: 220));
    expect(vm.record!.utterances.last.turnStatus, 'interrupted');
    expect(vm.record!.utterances.last.raw, '关于交付，我们需要');
    expect(vm.phase, MeetingPhase.recording);
    expect((vm.recorder as FakeMeetingRecorder).pauses, 0);
  });

  test('连续追加发言时分批显示已完成分析，同时继续下一批，不丢原话或等待会议停顿', () async {
    final remote = BatchedMeetingRemote();
    final vm = await createMeeting(remote, MemoryMeetingStore());
    await vm.start(demo: false);
    await vm.addManual('发言人 A', '本期交付双端应用');
    final work = vm.syncCloud();
    await remote.started[0].future;
    final first = vm.record!.utterances.first.id;
    await vm.addManual('发言人 B', '桌面端先评估');
    remote.gates[0].complete(batchFinding('批次一', first));
    await remote.started[1].future;
    expect(vm.record!.insights.single.title, '批次一');
    expect(vm.cloudAnalyzed, isFalse);
    final second = vm.record!.utterances.last.id;
    await vm.addManual('发言人 A', '尚未批准增加范围');
    remote.gates[1].complete(batchFinding('批次二', second));
    await remote.started[2].future;
    expect(vm.record!.insights.map((i) => i.title), ['批次二']);
    expect(
      vm.record!.insights.single.evidenceIds,
      containsAll([first, second]),
    );
    expect(vm.record!.utterances.length, 3);
    remote.gates[2].complete(
      batchFinding('批次三', vm.record!.utterances.last.id),
    );
    await work;
    expect(vm.record!.insights.map((i) => i.title), ['批次三']);
    expect(vm.cloudAnalyzed, isTrue);
    expect(vm.phase, MeetingPhase.recording);
  });

  test('人工纠错后的旧批次不得显示，更新后的批次继续处理', () async {
    final remote = BatchedMeetingRemote();
    final vm = await createMeeting(remote, MemoryMeetingStore());
    await vm.start(demo: false);
    await vm.addManual('发言人 A', '批准增加范围');
    final work = vm.syncCloud();
    await remote.started[0].future;
    final id = vm.record!.utterances.first.id;
    await vm.correct(id, '未批准增加范围');
    remote.gates[0].complete(batchFinding('无效旧判断', id));
    await remote.started[1].future;
    expect(vm.record!.insights, isEmpty);
    remote.gates[1].complete(batchFinding('已依据纠错核对', id));
    await work;
    expect(vm.record!.insights.single.title, '已依据纠错核对');
  });
  test('每段语音定稿后由整理Agent回填，原话与原录音独立保留', () async {
    final remote = FakeTranscriptPolisher();
    final vm = await createMeeting(remote, MemoryMeetingStore());
    await vm.start(demo: false);
    const raw = '嗯，我们我们先评估，不能承诺周三交付。';
    (vm.recorder as FakeMeetingRecorder).transcriptEvents.add(
      const MeetingTranscript(0, raw, isFinal: true),
    );
    await vm.waitForPolish();
    expect(vm.record!.utterances.single.raw, raw);
    expect(vm.record!.utterances.single.cleaned, '我们先评估，不能承诺周三交付。');
    expect(vm.record!.audioPaths, isNotEmpty);
    expect(vm.polishError, isNull);
  });

  test('整理晚到不会覆盖人工纠错，失败也不影响继续收音', () async {
    final gate = Completer<String>();
    final remote = FakeTranscriptPolisher()..gate = gate;
    final vm = await createMeeting(remote, MemoryMeetingStore());
    await vm.start(demo: false);
    (vm.recorder as FakeMeetingRecorder).transcriptEvents.add(
      const MeetingTranscript(0, '嗯，我们先评估。', isFinal: true),
    );
    await vm.correct(vm.record!.utterances.single.id, '人工核对：暂未同意。');
    gate.complete('我们先评估。');
    await vm.waitForPolish();
    expect(vm.record!.utterances.single.display, '人工核对：暂未同意。');
    remote.unavailable = true;
    (vm.recorder as FakeMeetingRecorder).transcriptEvents.add(
      const MeetingTranscript(1, '新的原话', isFinal: true),
    );
    await vm.waitForPolish();
    expect(vm.phase, MeetingPhase.recording);
    expect(vm.record!.utterances.last.raw, '新的原话');
    expect(vm.polishError, isNotNull);
  });

  test('去除语气词后，记忆拼贴光标仍定位相同缺口', () {
    const item = MeetingUtterance(
      id: 'u',
      speaker: '我',
      raw: '嗯，我们我们在……确认。',
      cleaned: '我们在……确认。',
      at: Duration.zero,
      repair: SpeechRepair(start: 8, end: 10, text: '周三', evidenceIds: ['u']),
    );
    final actual = item.raw.indexOf('……');
    final withRepair = item.revise(
      repair: SpeechRepair(
        start: actual,
        end: actual + 2,
        text: '周三',
        evidenceIds: ['u'],
      ),
    );
    expect(withRepair.repairContext, ('我们在', '确认。'));
    expect(withRepair.raw, startsWith('嗯'));
  });
  test('同步白名单不携带录音、路径、本地建议和凭据', () {
    final record = MeetingRecord(
      id: 'm1',
      startedAt: DateTime(2026, 10, 19),
      demo: false,
      ownerId: 'account-a',
      audioPaths: ['/private/recording.wav'],
      syncRevision: 2,
      utterances: [
        const MeetingUtterance(
          id: 'u1',
          speaker: '我',
          raw: '验收……',
          at: Duration.zero,
          audioPath: '/private/recording.wav',
        ),
      ],
    );
    final payload = meetingSyncPayload(record, paused: false);
    final text = jsonEncode(payload);
    expect(text, isNot(contains('/private')));
    expect(text, isNot(contains('audio')));
    expect(text, isNot(contains('ownerId')));
    expect(payload['startedAt'], endsWith('Z'));
    expect(payload['revision'], 2);
  });

  test('切换账户后，原账户排队请求不允许带新凭据发出', () async {
    var requests = 0;
    final dio = Dio()
      ..httpClientAdapter = TestAdapter((options) async {
        requests++;
        return (200, envelope(null));
      });
    final client = ApiClient(baseUrl: 'https://test.example/', dio: dio)
      ..accountId = (() => 'new-account')
      ..accessToken = (() async => 'new-token');
    await expectLater(
      client.post(
        'meetings/sync',
        authenticated: true,
        accountId: 'old-account',
      ),
      throwsA(isA<ApiFailure>()),
    );
    expect(requests, 0);
  });

  test('轮询短任务接口取得结果，并复用当前账户认证', () async {
    final paths = <String>[];
    final dio = Dio()
      ..httpClientAdapter = TestAdapter((options) async {
        paths.add(options.path);
        expect(options.headers['Authorization'], 'Bearer token');
        if (options.path.endsWith('/jobs')) {
          return (
            202,
            envelope({
              'id': 'j1',
              'status': 'queued',
              'revision': 1,
            }, status: 202),
          );
        }
        return (
          200,
          envelope({
            'status': 'succeeded',
            'revision': 1,
            'result': {
              'analysis': {'insights': []},
            },
          }),
        );
      });
    final client = ApiClient(baseUrl: 'https://test.example/', dio: dio)
      ..accountId = (() => 'a')
      ..accessToken = (() async => 'token');
    final repo = DioMeetingRepository(client, pollInterval: Duration.zero);
    final report = await repo.analyze(
      MeetingRecord(
        id: 'm',
        startedAt: DateTime.now(),
        demo: false,
        ownerId: 'a',
        syncRevision: 1,
      ),
    );
    expect(report['insights'], isEmpty);
    // 先订阅任务事件；测试服务端不推送事件流，回退到查询同一任务。
    expect(paths, [
      'meetings/m/jobs',
      'meetings/jobs/j1/events',
      'meetings/jobs/j1',
    ]);
  });

  test('补句和撤回只改变展示副本，人工纠错和本地语音保留', () {
    final record = MeetingRecord(
      id: 'm',
      startedAt: DateTime.now(),
      demo: false,
      utterances: [
        const MeetingUtterance(
          id: 'u1',
          speaker: '我',
          raw: '😀验收……',
          at: Duration.zero,
          audioPath: '/local.wav',
        ),
        const MeetingUtterance(
          id: 'u2',
          speaker: '我',
          raw: '周五交付',
          at: Duration.zero,
          correction: '周四交付',
        ),
      ],
    );
    final result = applyMeetingAnalysis(record, {
      'insights': [],
      'repairs': [
        {
          'target_id': 'u1',
          'start': 4,
          'end': 6,
          'text': '周三确认',
          'evidence_ids': ['u1', 'u2'],
        },
      ],
      'withdrawals': [
        {
          'target_id': 'u2',
          'evidence_ids': ['u1'],
        },
      ],
    });
    expect(result.utterances.first.raw, '😀验收……');
    expect(result.utterances.first.audioPath, '/local.wav');
    expect(result.utterances.first.repair!.start, 4);
    expect(result.utterances.last.correction, '周四交付');
    expect(record.utterances.last.withdrawn, isFalse);
  });

  test('暂停同步和结束归档更新原知识库卡片，重复归档不重复建卡', () async {
    final remote = FakeMeetingRemote();
    final store = MemoryMeetingStore();
    final vm = await createMeeting(remote, store);
    await vm.start(demo: false);
    await vm.addManual('我', '先评估交期');
    await vm.pause();
    await vm.syncCloud();
    expect(remote.pauses.last, isTrue);
    expect(vm.record!.insights.single.title, '当前结果');
    await vm.resume();
    expect(await vm.finish(), isTrue);
    // Archive fixtures must meet the product's one-minute threshold.
    final endedId = vm.record!.id;
    await store.save(vm.record!.copy(elapsed: const Duration(seconds: 90)));
    await vm.open(endedId);
    await vm.syncCloud();
    final id = vm.record!.documentId;
    expect(remote.sent.last.ended, isTrue);
    expect(remote.analyses, 1, reason: '仅暂停、恢复、结束不重复推演同一批事实');
    expect(vm.cloudError, isNull, reason: vm.knowledge.actionError);
    expect(vm.record!.cloudMinutes, contains('云端纪要'));
    expect(vm.knowledge.document(id!)!.selected.content, contains('云端纪要'));
    expect(vm.knowledge.data.documents.where((d) => d.id == id).length, 1);
    final versions = vm.knowledge.document(id)!.versions.length;
    await vm.syncCloud();
    expect(vm.knowledge.document(id)!.versions.length, versions);
    expect(vm.record!.audioPaths, isNotEmpty);
  });

  test('断网不终止录音，也不丢弃原话或音频路径', () async {
    final remote = FakeMeetingRemote()..fail = true;
    final store = MemoryMeetingStore();
    final vm = await createMeeting(remote, store);
    await vm.start(demo: false);
    await vm.addManual('我', '原话保留');
    await vm.syncCloud();
    expect(vm.phase, MeetingPhase.recording);
    expect(store.records[vm.record!.id]!.utterances.single.raw, '原话保留');
    expect(vm.record!.audioPaths, isNotEmpty);
    expect(vm.cloudError, isNotNull);
  });

  test('分析期间出现新原话，旧结果不能覆盖，新批次随后同步', () async {
    final gate = Completer<Map<String, dynamic>>();
    final remote = FakeMeetingRemote()..pending = gate;
    final vm = await createMeeting(remote, MemoryMeetingStore());
    await vm.start(demo: false);
    await vm.addManual('我', '旧原话');
    final work = vm.syncCloud();
    await remote.analyzing.future;
    await vm.addManual('我', '新原话');
    final follower = vm.syncCloud();
    gate.complete({
      'insights': [
        {
          'id': 'old',
          'kind': 'risk',
          'title': '旧结果',
          'body': '旧结果',
          'evidence_ids': [vm.record!.utterances.first.id],
        },
      ],
    });
    await follower;
    await work;
    expect(remote.sent.length, 2);
    expect(vm.record!.utterances.length, 2);
    expect(
      vm.record!.insights.map((i) => i.title),
      containsAll(['旧结果', '当前结果']),
      reason: '新发言不删除仍有有效原话依据的历史提示',
    );
  });

  test('云端归档历史直接读取纪要，不重新调用模型', () async {
    final remote = FakeMeetingRemote()
      ..historyRecords = [
        MeetingRecord(
          id: 'saved',
          startedAt: DateTime.now(),
          demo: false,
          ownerId: 'account-a',
          syncRevision: 3,
          ended: true,
          elapsed: const Duration(seconds: 90),
        ),
      ]
      ..savedArchive = {'title': '历史纪要', 'markdown': '# 已归档内容'};
    final vm = await createMeeting(remote, MemoryMeetingStore());
    await vm.open('saved');
    expect(vm.record!.cloudMinutes, '# 已归档内容');
    expect(
      vm.knowledge.document(vm.record!.documentId!)!.selected.content,
      '# 已归档内容',
    );
    expect(remote.sent, isEmpty);
    expect(remote.analyzing.isCompleted, isFalse);
  });

  test('退出时停止本机收音，旧账户晚返回结果不进入新账户会议', () async {
    final gate = Completer<Map<String, dynamic>>();
    final remote = FakeMeetingRemote()..pending = gate;
    final store = MemoryMeetingStore();
    final vm = await createMeeting(remote, store);
    await vm.start(demo: false);
    await vm.addManual('我', '旧账户的原话');
    final oldId = vm.record!.id;
    final work = vm.syncCloud();
    await remote.analyzing.future;
    await vm.suspendForLogout();
    expect(
      vm.notifications.items.where((n) => n.id.startsWith('meeting:')),
      isEmpty,
    );
    remote.accountId = 'account-b';
    gate.complete({'insights': []});
    await work;
    expect(vm.record, isNull);
    expect((vm.recorder as FakeMeetingRecorder).stops, 1);
    expect(store.records[oldId]!.ownerId, 'account-a');
    await vm.open();
    expect(vm.record, isNull);
    await vm.start(demo: false);
    expect(vm.record!.ownerId, 'account-b');
    expect(vm.record!.utterances, isEmpty);
    expect(vm.phase, MeetingPhase.recording);
  });
}
