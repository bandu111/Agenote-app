import 'package:flutter_test/flutter_test.dart';
import 'package:yanshu/features/progress/models/progress_models.dart';

void main() {
  ProgressGoal goal(GoalStatus status) => ProgressGoal(
    id: 'goal',
    title: '交付',
    code: '',
    phase: '',
    condition: '',
    acceptance: '',
    deadline: DateTime(2026, 10, 23, 18),
    status: status,
    milestones: const [],
    history: const [],
  );
  test('到期不再出现负数，保留已完成状态', () {
    final item = goal(GoalStatus.active);
    expect(item.deadlineLabel(DateTime(2026, 10, 22, 12)), '剩余 1 天');
    expect(item.deadlineLabel(DateTime(2026, 10, 23, 12)), '今天到期');
    expect(item.deadlineLabel(DateTime(2026, 10, 23, 18)), '已过期');
    expect(item.deadlineLabel(DateTime(2026, 10, 25)), '已过期');
    expect(
      goal(GoalStatus.completed).deadlineLabel(DateTime(2026, 10, 25)),
      '已完成',
    );
  });
}
