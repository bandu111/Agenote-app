import 'dart:async';
import 'package:flutter/foundation.dart';
import '../models/schedule_item.dart';
import '../repositories/schedule_repository.dart';
import '../repositories/dio_home_repository.dart';

abstract interface class ScheduleClock {
  DateTime get now;
  DateTime toLocal(DateTime instant);
  DateTime get nextMidnight;
}

class DeviceScheduleClock implements ScheduleClock {
  @override
  DateTime get now => DateTime.now();
  @override
  DateTime toLocal(DateTime instant) => instant.toLocal();
  @override
  DateTime get nextMidnight {
    final time = now;
    return DateTime(time.year, time.month, time.day + 1);
  }
}

/// A debug-only controllable clock. Release builds use DeviceScheduleClock.
class PreviewScheduleClock extends DeviceScheduleClock {
  PreviewScheduleClock({DateTime? initialTime})
    : _anchor = initialTime?.toLocal();
  DateTime? _anchor;
  final Stopwatch _elapsed = Stopwatch()..start();
  @override
  DateTime get now => _anchor?.add(_elapsed.elapsed) ?? super.now;
  void advance(Duration delta) {
    _anchor = now.add(delta);
    _elapsed.reset();
  }

  void reset() {
    _anchor = null;
    _elapsed.reset();
  }
}

class ScheduleViewModel extends ChangeNotifier {
  ScheduleViewModel(
    this.repository, {
    ScheduleClock? clock,
    this.listenToTime = true,
    this.taskChecklist = false,
  }) : clock = clock ?? DeviceScheduleClock() {
    if (repository is DioHomeRepository) {
      _syncTimer = Timer.periodic(const Duration(seconds: 30), (_) {
        if (_active && _accountScope != null && !loading && savingId == null) {
          unawaited(refresh());
        }
      });
    }
  }
  final ScheduleRepository repository;
  final ScheduleClock clock;
  final bool listenToTime;
  final bool taskChecklist;
  List<ScheduleItem> _items = [];
  List<ScheduleEntry> entries = [];
  bool expanded = false;
  bool loading = true;
  String? error;
  String? savingId;
  Timer? _timer;
  Timer? _syncTimer;
  final _completionTimers = <String, Timer>{};
  bool _disposed = false;
  bool _active = true;
  int _revision = 0;
  String? _accountScope;
  void refreshAccount() {
    if (repository is! DioHomeRepository) return;
    final owner = (repository as DioHomeRepository).accountId;
    if (_accountScope == owner) return;
    _accountScope = owner;
    savingId = null;
    _selectedDate = null;
    for (final timer in _completionTimers.values) {
      timer.cancel();
    }
    _completionTimers.clear();
    ++_revision;
    _items = [];
    entries = [];
    error = null;
    scheduleMicrotask(() {
      if (!_disposed) notifyListeners();
    });
    scheduleMicrotask(() {
      if (!_disposed) unawaited(refresh());
    });
  }

  Future<void> refresh({bool resetDateToToday = false}) async {
    final revision = ++_revision;
    if (resetDateToToday) _selectedDate = null;
    loading = true;
    error = null;
    notifyListeners();
    try {
      final items = await repository.load();
      if (_disposed || revision != _revision) return;
      if (repository is DioHomeRepository &&
          (repository as DioHomeRepository).accountId != _accountScope) {
        return;
      }
      if (items.map((item) => item.id).toSet().length != items.length) {
        throw StateError('安排 ID 重复');
      }
      _items = items;
      _derive();
    } catch (_) {
      if (_disposed || revision != _revision) return;
      error = taskChecklist ? '任务清单加载失败，请重试。' : '安排加载失败，请重试。';
    }
    loading = false;
    _armTimer();
    notifyListeners();
  }

  ScheduleStatus _status(ScheduleItem item, DateTime now) {
    if (item.completed) return ScheduleStatus.completed;
    if (item.kind == ScheduleKind.task) {
      if (!item.hasDeadline) return ScheduleStatus.upcoming;
      return now.isBefore(item.startsAt)
          ? ScheduleStatus.upcoming
          : ScheduleStatus.overdue;
    }
    if (now.isBefore(item.startsAt)) return ScheduleStatus.upcoming;
    if (item.endsAt == null) {
      final local = clock.toLocal(now);
      final start = clock.toLocal(item.startsAt);
      return DateTime(
            local.year,
            local.month,
            local.day,
          ).isAfter(DateTime(start.year, start.month, start.day))
          ? ScheduleStatus.ended
          : ScheduleStatus.needsReview;
    }
    return now.isBefore(item.endsAt!)
        ? ScheduleStatus.ongoing
        : ScheduleStatus.ended;
  }

  int _group(ScheduleStatus status) => switch (status) {
    ScheduleStatus.ongoing || ScheduleStatus.needsReview => 0,
    ScheduleStatus.upcoming => 1,
    _ => 2,
  };

  bool _pendingTask(ScheduleItem item) =>
      item.kind == ScheduleKind.task &&
      !item.completed &&
      (!item.hasDeadline || clock.now.isBefore(item.startsAt));
  int get pendingTaskCount => _items.where(_pendingTask).length;
  List<ScheduleEntry> get pendingTaskEntries =>
      allTaskEntries.where((entry) => _pendingTask(entry.item)).toList();
  // Includes completed rows so an open overview can offer undo without removing
  // the item the instant its completion request succeeds.
  List<ScheduleEntry> get allTaskEntries =>
      _items
          .where((item) => item.kind == ScheduleKind.task)
          .map(
            (item) => ScheduleEntry(
              item,
              _status(item, clock.now),
              clock.toLocal(item.startsAt),
            ),
          )
          .toList()
        ..sort((a, b) {
          final date = (calendarDateFor(a.item) ?? DateTime(9999)).compareTo(
            calendarDateFor(b.item) ?? DateTime(9999),
          );
          return date != 0 ? date : a.item.id.compareTo(b.item.id);
        });

  DateTime? calendarDateFor(ScheduleItem item) {
    if (!item.hasCalendarDate) return null;
    final date =
        item.kind == ScheduleKind.task &&
            !item.hasDeadline &&
            item.sourceMeetingDate != null
        ? item.sourceMeetingDate!
        : clock.toLocal(item.startsAt);
    return DateTime(date.year, date.month, date.day);
  }

  DateTime? _selectedDate;
  DateTime get selectedDate => _selectedDate ?? clock.toLocal(clock.now);
  List<ScheduleEntry> entriesOn(DateTime date) =>
      _items
          .where((item) {
            final start = calendarDateFor(item);
            return start != null &&
                start.year == date.year &&
                start.month == date.month &&
                start.day == date.day;
          })
          .map(
            (item) => ScheduleEntry(
              item,
              _status(item, clock.now),
              clock.toLocal(item.startsAt),
            ),
          )
          .toList()
        ..sort((a, b) => a.item.startsAt.compareTo(b.item.startsAt));
  List<ScheduleEntry> get selectedEntries => entriesOn(selectedDate);
  List<ScheduleEntry> get undatedTasks => _items
      .where((i) => i.kind == ScheduleKind.task && !i.hasDeadline)
      .map(
        (i) => ScheduleEntry(
          i,
          ScheduleStatus.upcoming,
          clock.toLocal(i.startsAt),
        ),
      )
      .toList();
  void selectDate(DateTime date) {
    _selectedDate = DateTime(date.year, date.month, date.day);
    notifyListeners();
  }

  void _derive() {
    final now = clock.now;
    final day = clock.toLocal(now);
    entries =
        _items
            .where((item) {
              if (taskChecklist) {
                return item.kind == ScheduleKind.task &&
                    (item.completed ||
                        !item.hasDeadline ||
                        now.isBefore(item.startsAt));
              }
              final start = clock.toLocal(item.startsAt);
              final end = item.endsAt == null
                  ? null
                  : clock.toLocal(item.endsAt!);
              final midnight = DateTime.utc(day.year, day.month, day.day);
              final next = midnight.add(const Duration(days: 1));
              DateTime calendar(DateTime time) => DateTime.utc(
                time.year,
                time.month,
                time.day,
                time.hour,
                time.minute,
                time.second,
              );
              // Include multi-day meetings that intersect today, and tasks due today.
              if (item.kind == ScheduleKind.meeting && end != null) {
                return calendar(start).isBefore(next) &&
                    calendar(end).isAfter(midnight);
              }
              return start.year == day.year &&
                  start.month == day.month &&
                  start.day == day.day;
            })
            .map(
              (item) => ScheduleEntry(
                item,
                _status(item, now),
                clock.toLocal(item.startsAt),
              ),
            )
            .toList()
          ..sort((a, b) {
            if (taskChecklist) {
              final due = (a.item.hasDeadline ? 0 : 1).compareTo(
                b.item.hasDeadline ? 0 : 1,
              );
              if (due != 0) return due;
              final time = a.item.startsAt.compareTo(b.item.startsAt);
              return time != 0 ? time : a.item.id.compareTo(b.item.id);
            }
            final group = _group(a.status).compareTo(_group(b.status));
            if (group != 0) return group;
            // Ended/overdue before manually completed, then time and immutable ID.
            if (a.isPast && b.isPast) {
              final completed = (a.status == ScheduleStatus.completed ? 1 : 0)
                  .compareTo(b.status == ScheduleStatus.completed ? 1 : 0);
              if (completed != 0) return completed;
            }
            final time = a.item.startsAt.compareTo(b.item.startsAt);
            return time != 0 ? time : a.item.id.compareTo(b.item.id);
          });
  }

  void checkTime() {
    if (_disposed) return;
    final previous = entries
        .map((entry) => '${entry.item.id}:${entry.status}:${entry.localStart}')
        .join('|');
    _derive();
    final next = entries
        .map((entry) => '${entry.item.id}:${entry.status}:${entry.localStart}')
        .join('|');
    if (previous != next || _items.any((i) => i.kind == ScheduleKind.meeting)) {
      notifyListeners();
    }
    _armTimer();
  }

  void _armTimer() {
    _timer?.cancel();
    if (_disposed || !_active || !listenToTime) return;
    final now = clock.now;
    var delay = const Duration(
      minutes: 1,
    ); // Clock/timezone changes, no per-second polling.
    final boundaries = [
      clock.nextMidnight,
      for (final item in _items) item.startsAt,
      for (final item in _items)
        if (item.endsAt != null) item.endsAt!,
    ];
    for (final boundary in boundaries) {
      final distance = boundary.difference(now);
      if (distance > Duration.zero && distance < delay) delay = distance;
    }
    _timer = Timer(delay, checkTime);
  }

  void pause() {
    _active = false;
    _timer?.cancel();
  }

  void resume() {
    _active = true;
    checkTime();
  }

  void toggleExpanded() {
    expanded = !expanded;
    notifyListeners();
  }

  Future<bool> complete(String id) async {
    if (savingId != null) return false;
    if (taskChecklist &&
        !entries
            .followedBy(selectedEntries)
            .followedBy(undatedTasks)
            .any(
              (entry) =>
                  entry.item.id == id &&
                  entry.item.kind == ScheduleKind.task &&
                  (entry.item.completed ||
                      !entry.item.hasDeadline ||
                      clock.now.isBefore(entry.item.startsAt)) &&
                  !entry.item.reviewPending,
            )) {
      return false;
    }
    final owner = _accountScope;
    savingId = id;
    error = null;
    notifyListeners();
    try {
      final selected = _items.firstWhere((item) => item.id == id);
      final completed = !selected.completed;
      final repo = repository;
      if (completed) {
        await repository.markCompleted(id);
      } else if (repo is ReversibleScheduleRepository) {
        await (repo as ReversibleScheduleRepository).setCompleted(id, false);
      } else {
        throw StateError('Undo unavailable');
      }
      if (_disposed || owner != _accountScope) {
        return false;
      }
      if (taskChecklist) {
        _items = [
          for (final item in _items)
            if (item.id == id) item.complete(completed: completed) else item,
        ];
        _derive();
        return true;
      }
      await refresh();
      return error == null;
    } catch (_) {
      if (!_disposed && owner == _accountScope) {
        error = '未能保存完成状态，请重试。';
        notifyListeners();
      }
      return false;
    } finally {
      if (!_disposed && owner == _accountScope) {
        savingId = null;
        notifyListeners();
      }
    }
  }

  // Completion is reversible and stays visible; retained for existing callers.
  void dismissCompleted(String id) {}

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _syncTimer?.cancel();
    for (final timer in _completionTimers.values) {
      timer.cancel();
    }
    super.dispose();
  }
}
