import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yanshu/features/home/viewmodels/home_view_model.dart';
import 'package:yanshu/features/progress/widgets/goal_topology.dart';

Map<String, dynamic> goal({String? deadline}) => {
  'id': 'shared-goal',
  'title': '工单上线验收',
  'condition': '完成工单系统上线验收',
  'acceptance': '核心流程通过',
  'phase': '试点',
  'status': 'active',
  'deadline': deadline,
  'milestones': [
    {
      'title': '需求范围确认',
      'weight': 1,
      'status': 'completed',
      'statusBasis': 'meeting_reported',
    },
    {
      'title': '核心模块开发',
      'weight': 1,
      'status': 'active',
      'statusBasis': 'meeting_reported',
    },
    {'title': '客户上线验收', 'weight': 1, 'status': 'pending'},
  ],
};

void main() {
  test('无交期目标继续显示，进度取真实节点而非固定示例百分比', () {
    final home = HomeViewModel()..data = {'situationGoal': goal()};
    addTearDown(home.dispose);
    final current = home.situationGoal!;
    expect(current.deadline, isNull);
    expect(current.deadlineLabel(DateTime.now()), '交期待明确');
    expect(current.progress, closeTo(1 / 3, .001));
    expect(current.milestones.first.statusBasis, 'meeting_reported');
  });

  test('到期首页不显示拓扑，同一目标新进度保留身份', () {
    final home = HomeViewModel()
      ..data = {'situationGoal': goal(deadline: '2020-01-01T00:00:00Z')};
    addTearDown(home.dispose);
    expect(home.situationGoal, isNull);
    home.data = {'situationGoal': goal(deadline: '2035-01-01T00:00:00Z')};
    expect(home.situationGoal!.id, 'shared-goal');
  });

  testWidgets('原拓扑组件显示缺交期及会议陈述说明', (tester) async {
    final home = HomeViewModel()..data = {'situationGoal': goal()};
    addTearDown(home.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: GoalTopology(goal: home.situationGoal!),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('目标拓扑图'), findsOneWidget);
    expect(find.text('含会议陈述的进度，尚未完成履约核验'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
