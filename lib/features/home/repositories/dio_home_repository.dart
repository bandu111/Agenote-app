import '../../../core/network/api_client.dart';
import '../../../core/network/api_config.dart';
import '../models/schedule_item.dart';
import 'schedule_repository.dart';

String? _optionalString(Object? value) =>
    value is String && value.trim().isNotEmpty ? value : null;

DateTime? _optionalDate(Object? value) =>
    value is String ? DateTime.tryParse(value) : null;

/// 首页与日程共用认证客户端，不回退到演示安排。
class DioHomeRepository
    implements ScheduleRepository, ReversibleScheduleRepository {
  DioHomeRepository(this.client);
  final ApiClient client;
  String? get accountId => client.accountId?.call();
  Future<Map<String, dynamic>>? _pending;
  String? _pendingOwner;
  void invalidateSnapshot() {
    _pending = null;
    _pendingOwner = null;
  }

  final _taskVersions = <String, int>{};
  String? _taskOwner;
  Future<Map<String, dynamic>> snapshot() async {
    final owner = accountId;
    if (owner == null) return {};
    if (_pending != null && _pendingOwner == owner) return _pending!;
    _pendingOwner = owner;
    final request = _read(owner);
    _pending = request;
    try {
      return await request;
    } finally {
      if (identical(_pending, request)) _pending = null;
    }
  }

  Future<Map<String, dynamic>> _read(String owner) async {
    final response = await client.get(
      'home',
      authenticated: true,
      accountId: owner,
    );
    if (accountId != owner) throw const ApiFailure('账户已切换');
    return Map<String, dynamic>.from(response['data']);
  }

  @override
  Future<List<ScheduleItem>> load() async {
    final owner = accountId;
    final data = await snapshot();
    if (accountId != owner) throw const ApiFailure('账户已切换');
    final tasks = List<Map<String, dynamic>>.from(
      (data['tasks'] as List? ?? []).map(
        (item) => Map<String, dynamic>.from(item),
      ),
    );
    _taskOwner = owner;
    _taskVersions
      ..clear()
      ..addEntries(
        tasks.map(
          (item) => MapEntry(item['id'] as String, item['version'] as int),
        ),
      );
    return [
      for (final raw in data['schedules'] as List? ?? [])
        if (raw is Map &&
            raw['kind'] == 'meeting' &&
            DateTime.tryParse(
                  raw['startsAt'] is String ? raw['startsAt'] : '',
                ) !=
                null)
          ScheduleItem(
            id: raw['id'],
            title: raw['title'],
            startsAt: DateTime.parse(raw['startsAt']),
            endsAt: _optionalDate(raw['endsAt']),
            kind: ScheduleKind.meeting,
            reviewPending: raw['reviewPending'] == true,
            notes: raw['notes'] is String ? raw['notes'] : '',
            sourceLabel: raw['source'] is String ? raw['source'] : '会议安排',
            sourceRoute: raw['sourceRoute'] is String
                ? raw['sourceRoute']
                : '/notifications',
            preparationId: _optionalString(raw['preparationId']),
            preparationStatus: _optionalString(raw['preparationStatus']),
            preparationSummary: _optionalString(raw['preparationSummary']),
            preparationRoute: validatedPreparationRoute(
              raw['preparationRoute'],
              preparationId: _optionalString(raw['preparationId']),
            ),
            agenda: _optionalString(raw['agenda']),
            timeZone: _optionalString(raw['timeZone']),
            authority: _optionalString(raw['authority']),
            actionVersion: raw['actionVersion'] is int
                ? raw['actionVersion']
                : null,
            verifiedAt: _optionalDate(raw['verifiedAt']),
          ),
      for (final item in tasks)
        ScheduleItem(
          id: item['id'],
          title: item['title'],
          startsAt:
              DateTime.tryParse(item['deadline'] ?? '') ??
              DateTime.tryParse(item['createdAt'] ?? '') ??
              DateTime.utc(1970),
          kind: ScheduleKind.task,
          sourceMeetingDate: _sourceMeetingDate(item),
          hasDeadline: DateTime.tryParse(item['deadline'] ?? '') != null,
          deadlineHasTime: item['deadlineHasTime'] != false,
          hasCalendarDate:
              DateTime.tryParse(item['deadline'] ?? '') != null ||
              _sourceMeetingDate(item) != null,
          reviewPending: item['reviewPending'] == true,
          completed: item['completed'] == true,
          notes: item['notes'] ?? '',
          sourceTimeZone: '来源时间按设备时区显示',
          sourceLabel: item['source'] ?? '账户数据',
          sourceRoute:
              item['sourceRoute'] ??
              (item['sessionId'] != null
                  ? '/meeting?id=${Uri.encodeComponent(item['sessionId'])}'
                  : '/affairs'),
        ),
    ];
  }

  DateTime? _sourceMeetingDate(Map<String, dynamic> item) {
    final source =
        _optionalDate(item['sourceMeetingDate']) ??
        _optionalDate(item['createdAt']);
    return source == null
        ? null
        : DateTime(source.year, source.month, source.day);
  }

  @override
  Future<void> markCompleted(String id) async {
    await setCompleted(id, true);
  }

  @override
  Future<void> setCompleted(String id, bool completed) async {
    final owner = accountId;
    final version = _taskVersions[id];
    if (owner == null || owner != _taskOwner || version == null) {
      throw const ApiFailure('任务信息已变化，请刷新后重试');
    }
    final response = await client.post(
      'home/tasks/${Uri.encodeComponent(id)}/${completed ? 'complete' : 'reopen'}',
      data: {'version': version},
      authenticated: true,
      accountId: owner,
    );
    if (accountId != owner) throw const ApiFailure('账户已切换');
    final saved = Map<String, dynamic>.from(response['data']);
    if (saved['id'] != id || saved['completed'] != completed) {
      throw const ApiFailure('完成状态尚未保存');
    }
    _taskVersions[id] = saved['version'];
    invalidateSnapshot();
  }
}
