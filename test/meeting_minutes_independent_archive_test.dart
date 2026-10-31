import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:yanshu/core/network/api_config.dart';
import 'package:yanshu/features/meeting/meeting_models.dart';
import 'package:yanshu/features/meeting/meeting_store.dart';
import 'package:yanshu/features/meeting/meeting_view_model.dart';
import 'package:yanshu/features/knowledge/viewmodels/knowledge_view_model.dart';
import 'package:yanshu/features/meeting/minutes/meeting_minutes_page.dart';
import 'meeting_remote_test.dart' show FakeMeetingRemote, createMeeting;

class AnalysisFailureRemote extends FakeMeetingRemote {
  int archives = 0;
  @override
  Future<Map<String, dynamic>> analyze(MeetingRecord record) async {
    throw const ApiFailure('测试用分析格式失败');
  }

  @override
  Future<Map<String, dynamic>> archive(MeetingRecord record) async {
    archives++;
    final result = await super.archive(record);
    savedArchive = result;
    return result;
  }
}

void main() {
  testWidgets('analysis failure does not block independent minutes archive', (
    tester,
  ) async {
    final remote = AnalysisFailureRemote();
    final store = MemoryMeetingStore();
    final vm = await createMeeting(remote, store);
    vm.record = MeetingRecord(
      id: 'minutes-independent-test',
      startedAt: DateTime.now(),
      demo: false,
      ownerId: remote.accountId,
      ended: true,
      elapsed: const Duration(seconds: 70),
      utterances: const [
        MeetingUtterance(
          id: 'u1',
          speaker: '发言人 A',
          raw: '明确的测试原话',
          at: Duration(seconds: 1),
        ),
      ],
    );
    await store.save(vm.record!);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<MeetingViewModel>.value(value: vm),
          ChangeNotifierProvider<KnowledgeViewModel>.value(value: vm.knowledge),
        ],
        child: const MaterialApp(
          home: MeetingMinutesPage(id: 'minutes-independent-test'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(remote.archives, 1);
    expect(vm.record!.cloudMinutes, contains('明确的测试原话'));
    expect(find.text('测试用分析格式失败'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
}
