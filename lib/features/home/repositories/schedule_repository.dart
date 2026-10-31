import '../models/schedule_item.dart';

abstract interface class ScheduleRepository {
  Future<List<ScheduleItem>> load();
  Future<void> markCompleted(String id);
}

abstract interface class ReversibleScheduleRepository {
  Future<void> setCompleted(String id, bool completed);
}

/// 没有账户安排时是真实空状态，不生成固定会议或截止日期。
class EmptyScheduleRepository implements ScheduleRepository {
  @override
  Future<List<ScheduleItem>> load() async => const [];
  @override
  Future<void> markCompleted(String id) async => throw StateError('安排不存在');
}

/// Explicitly local, in-memory demonstration data; not a backend or hardware state.
class HomeMockScheduleRepository
    implements ScheduleRepository, ReversibleScheduleRepository {
  HomeMockScheduleRepository(List<ScheduleItem> items)
    : _items = List.of(items);
  factory HomeMockScheduleRepository.forDay(DateTime localDay) {
    DateTime at(int hour) =>
        DateTime(localDay.year, localDay.month, localDay.day, hour);
    return HomeMockScheduleRepository([
      ScheduleItem(
        id: 'meeting-progress',
        title: '项目进度对齐',
        startsAt: at(14),
        endsAt: at(15),
        kind: ScheduleKind.meeting,
        notes: '会议室 · 线上会议',
      ),
      ScheduleItem(
        id: 'meeting-review',
        title: '产品方案评审',
        startsAt: at(16),
        endsAt: at(17),
        kind: ScheduleKind.meeting,
        notes: '讨论产品方案与下一步安排',
      ),
      ScheduleItem(
        id: 'task-login',
        title: '登录模块开发截止',
        startsAt: at(18),
        kind: ScheduleKind.task,
        notes: '截止时间经过不会自动标记完成',
      ),
    ]);
  }
  final List<ScheduleItem> _items;
  @override
  Future<List<ScheduleItem>> load() async => List.unmodifiable(_items);
  @override
  Future<void> markCompleted(String id) async {
    await setCompleted(id, true);
  }

  @override
  Future<void> setCompleted(String id, bool completed) async {
    final index = _items.indexWhere((item) => item.id == id);
    if (index < 0) throw StateError('安排不存在');
    _items[index] = _items[index].complete(completed: completed);
  }
}
