import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:yanshu/features/meeting/meeting_models.dart';
import 'package:yanshu/features/meeting/meeting_remote.dart';
import 'package:yanshu/features/meeting/meeting_store.dart';
import 'meeting_latency_test.dart' show IncrementalPreviewRemote;
import 'meeting_remote_test.dart' show createMeeting;

class ContinuousRiskRemote extends IncrementalPreviewRemote
    implements LiveMeetingRiskAnalysis {
  final full = Completer<Map<String, dynamic>>();
  Completer<void>? riskGate;
  final requests = <MeetingRecord>[];
  final callbacks = <void Function(Map<String, dynamic>)>[];
  int active = 0, peak = 0;

  @override
  Future<Map<String, dynamic>> analyzeWithUpdates(
    MeetingRecord record,
    void Function(Map<String, dynamic>) onPreview,
  ) => full.future;

  @override
  Future<void> liveRisks(
    MeetingRecord record,
    void Function(Map<String, dynamic>) onUpdate,
  ) async {
    requests.add(record);
    callbacks.add(onUpdate);
    active++;
    if (active > peak) peak = active;
    final gate = riskGate;
    riskGate = null;
    try {
      if (gate != null) await gate.future;
      onUpdate(risk(record));
    } finally {
      active--;
    }
  }

  Map<String, dynamic> risk(MeetingRecord record) => {
    'event': 'done',
    'insights': [
      {
        'id': 'risk-${record.utterances.last.id}',
        'kind': 'risk',
        'title': '第${record.utterances.length}项风险',
        'body': '交付受阻，需核实影响。',
        'evidence_ids': [record.utterances.last.id],
      },
    ],
  };
}

void main() {
  testWidgets('连续十轮风险各自到达，不等待上一轮完整分析，不停止录音', (tester) async {
    final remote = ContinuousRiskRemote();
    final vm = await createMeeting(
      remote,
      MemoryMeetingStore(),
      disposeViewModel: false,
    );
    await vm.start(demo: false);
    for (var n = 0; n < 10; n++) {
      await vm.addManual('发言人 A', '第$n个接口超时，可能导致交付延期${n + 1}天。');
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();
      final id = vm.record!.utterances.last.id;
      expect(remote.requests.length, n + 1);
      expect(
        vm.record!.insights.any(
          (i) => i.kind == InsightKind.risk && i.evidenceIds.contains(id),
        ),
        isTrue,
      );
      expect(remote.full.isCompleted, isFalse);
      expect(vm.phase, MeetingPhase.recording);
      await tester.pump(const Duration(seconds: 8));
    }
    expect(remote.peak, 1);
    vm.dispose();
    remote.full.complete({'insights': [], 'repairs': []});
    await tester.pump();
  });

  testWidgets('慢风险期间只保留最新批次，不逐句积压，旧来源纠错后不接收旧流', (tester) async {
    final remote = ContinuousRiskRemote();
    final gate = Completer<void>();
    remote.riskGate = gate;
    final vm = await createMeeting(
      remote,
      MemoryMeetingStore(),
      disposeViewModel: false,
    );
    await vm.start(demo: false);
    await vm.addManual('发言人 A', 'ERP接口超时，可能影响交付。');
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
    final first = vm.record!.utterances.first.id;
    for (var n = 0; n < 10; n++) {
      await vm.addManual('发言人 A', '第$n项发生上传失败，需要评估影响。');
      await tester.pump(const Duration(milliseconds: 100));
    }
    await vm.correct(first, 'ERP接口已恢复，不再阻塞交付。');
    gate.complete();
    await tester.pump();
    expect(
      vm.record!.insights.any((i) => i.evidenceIds.contains(first)),
      isFalse,
    );
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
    expect(remote.requests.length, 2);
    expect(remote.requests.last.utterances.length, 11);
    expect(remote.peak, 1);
    expect(
      vm.record!.insights.any(
        (i) => i.evidenceIds.contains(vm.record!.utterances.last.id),
      ),
      isTrue,
    );
    vm.dispose();
    remote.full.complete({'insights': [], 'repairs': []});
    await tester.pump();
  });
}
