import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:crypto/crypto.dart';
import 'package:device_calendar/device_calendar.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../knowledge/models/knowledge_models.dart';

class CalendarExecutionFailure implements Exception {
  const CalendarExecutionFailure(this.message);
  final String message;
}

class _CalendarCommand {
  const _CalendarCommand({
    required this.id,
    required this.fingerprint,
    required this.operation,
    required this.title,
    required this.startText,
    required this.endText,
    required this.start,
    required this.end,
    this.targetEventId,
    this.targetCalendarId,
  });

  final String id;
  final String fingerprint;
  final String operation;
  final String title;
  final String startText;
  final String endText;
  final DateTime start;
  final DateTime end;
  final String? targetEventId;
  final String? targetCalendarId;

  factory _CalendarCommand.parse(Map<String, dynamic> action) {
    String? text(String key) {
      final value = action[key];
      return value is String && value.trim().isNotEmpty ? value : null;
    }

    final id = text('id');
    final fingerprint = text('fingerprint');
    final title = text('title');
    final startText = text('start');
    final endText = text('end');
    final operation = action['operation'] == null
        ? 'create'
        : text('operation');
    final start = DateTime.tryParse(startText ?? '');
    final end = DateTime.tryParse(endText ?? '');
    bool hasTimeZone(String? value) => value != null &&
        RegExp(r'(?:Z|[+-]\d{2}:\d{2})$', caseSensitive: false).hasMatch(value);
    if (id == null ||
        fingerprint == null ||
        title == null ||
        startText == null ||
        endText == null ||
        !hasTimeZone(startText) ||
        !hasTimeZone(endText) ||
        start == null ||
        end == null ||
        !end.isAfter(start) ||
        !{'create', 'reschedule', 'cancel'}.contains(operation)) {
      throw const CalendarExecutionFailure('日历操作参数无法核对，已停止设备操作');
    }
    if (operation == 'create') {
      return _CalendarCommand(
        id: id,
        fingerprint: fingerprint,
        operation: operation!,
        title: title,
        startText: startText,
        endText: endText,
        start: start,
        end: end,
      );
    }
    final rawTarget = action['target'];
    if (rawTarget is! Map) {
      throw const CalendarExecutionFailure('原日程标识缺失，已停止设备操作');
    }
    final target = Map<String, dynamic>.from(rawTarget);
    final eventId = target['eventId'];
    final calendarId = target['calendarId'];
    final targetDevice = target['deviceId'];
    final approvedDevice = action['deviceId'];
    if (eventId is! String ||
        eventId.trim().isEmpty ||
        (calendarId != null &&
            (calendarId is! String || calendarId.trim().isEmpty)) ||
        (targetDevice != null &&
            approvedDevice != null &&
            targetDevice != approvedDevice)) {
      throw const CalendarExecutionFailure('原日程标识无法核对，已停止设备操作');
    }
    return _CalendarCommand(
      id: id,
      fingerprint: fingerprint,
      operation: operation!,
      title: title,
      startText: startText,
      endText: endText,
      start: start,
      end: end,
      targetEventId: eventId,
      targetCalendarId: calendarId as String?,
    );
  }
}

/// 原生连接器只接收已批准的精确参数；每次副作用后都回读核验。
class DeviceCalendarExecutor {
  DeviceCalendarExecutor({
    DeviceCalendarPlugin? plugin,
    FlutterSecureStorage? storage,
    String namespace = '',
  }) : plugin = plugin ?? DeviceCalendarPlugin(),
       _namespace =
           namespace.isEmpty || namespace == 'http://127.0.0.1:8001/api/v1/'
           ? ''
           : '${sha256.convert(utf8.encode(namespace))}.',
       storage = storage ?? const FlutterSecureStorage();

  final DeviceCalendarPlugin plugin;
  final FlutterSecureStorage storage;
  final String _namespace;
  static const _compat = MethodChannel('yanshu/calendar_compat');

  bool _needsCompat<T>(Result<T>? value) =>
      !kIsWeb &&
      defaultTargetPlatform == TargetPlatform.android &&
      value?.isSuccess != true &&
      (value?.errors.any(
            (error) => error.errorMessage.contains(
              "Couldn't retrieve the Calendar with ID",
            ),
          ) ??
          false);

  Future<Result<List<Event>>> _readEvents(
    String id,
    RetrieveEventsParams params,
    String marker,
  ) async {
    final result = await plugin.retrieveEvents(id, params);
    if (!kIsWeb &&
        defaultTargetPlatform == TargetPlatform.android &&
        !result.isSuccess) {
      try {
        final rows = await _compat.invokeListMethod<dynamic>('read', {
          'calendarId': id,
          'marker': marker,
          'eventIds': params.eventIds,
        });
        if (rows != null) {
          return Result<List<Event>>()
            ..data = rows
                .map(
                  (row) =>
                      Event.fromJson(Map<String, dynamic>.from(row as Map)),
                )
                .toList();
        }
      } on PlatformException {
        // 系统权限仍不通过时保留失败，不跳过回读。
      }
    }
    return Result<List<Event>>()
      ..data = result.data?.toList()
      ..errors.addAll(result.errors);
  }

  Future<Result<String>?> _createEvent(Event event, String marker) async {
    final result = await plugin.createOrUpdateEvent(event);
    if (_needsCompat(result)) {
      try {
        final id = await _compat.invokeMethod<String>('create', {
          'calendarId': event.calendarId,
          'marker': marker,
          'title': event.title,
          'start': event.start!.millisecondsSinceEpoch,
          'end': event.end!.millisecondsSinceEpoch,
        });
        if (id != null) return Result<String>()..data = id;
      } on PlatformException {
        // 兼容创建失败时交给通知重试；更新和删除绝不退化为创建。
      }
    }
    return result;
  }

  Future<String> deviceId() async {
    final saved = await storage.read(
      key: '${_namespace}yanshu-calendar-device',
    );
    if (saved != null) return saved;
    final id = '${knowledgeId()}-${knowledgeId()}';
    await storage.write(key: '${_namespace}yanshu-calendar-device', value: id);
    return id;
  }

  String _recordKey(String owner, _CalendarCommand command) {
    final scope = jsonEncode([owner, command.id, command.fingerprint]);
    return '${_namespace}yanshu-calendar-action-${sha256.convert(utf8.encode(scope))}';
  }

  String _legacyRecordKey(String owner, _CalendarCommand command) =>
      '${_namespace}yanshu-calendar-$owner-${command.id}';

  Future<Map<String, dynamic>?> _readRecord(String key) async {
    final saved = await storage.read(key: key);
    if (saved == null) return null;
    try {
      final decoded = jsonDecode(saved);
      if (decoded is! Map) throw const FormatException();
      return Map<String, dynamic>.from(decoded);
    } catch (_) {
      throw const CalendarExecutionFailure('本机日历操作记录无法核对，已停止重复操作');
    }
  }

  Future<void> _writeRecord(
    String key,
    _CalendarCommand command, {
    required String state,
    String? eventId,
    String? calendarId,
  }) => storage.write(
    key: key,
    value: jsonEncode({
      'operation': command.operation,
      'fingerprint': command.fingerprint,
      'targetEventId': command.targetEventId,
      'eventId': eventId,
      'calendarId': calendarId,
      'state': state,
    }),
  );

  void _validateRecord(Map<String, dynamic>? saved, _CalendarCommand command) {
    if (saved == null) return;
    if (saved['fingerprint'] != command.fingerprint ||
        (saved['operation'] != null &&
            saved['operation'] != command.operation) ||
        (saved['targetEventId'] != null &&
            saved['targetEventId'] != command.targetEventId)) {
      throw const CalendarExecutionFailure('日历操作内容已经变化，请刷新后重新核对');
    }
  }

  Future<Map<String, dynamic>> execute(
    String owner,
    Map<String, dynamic> action, {
    required bool Function() isCurrent,
  }) async {
    final command = _CalendarCommand.parse(action);
    if (!isCurrent()) throw StateError('账户已切换');
    final permission = await plugin.requestPermissions();
    if (permission.data != true) {
      throw const CalendarExecutionFailure('请允许系统日历权限后重试');
    }
    if (!isCurrent()) throw StateError('账户已切换');
    final inventory = await plugin.retrieveCalendars();
    if (!inventory.isSuccess || inventory.data == null) {
      throw const CalendarExecutionFailure('系统日历读取失败，请检查权限后重试');
    }
    final allCalendars = inventory.data!
        .where((calendar) => calendar.id != null)
        .toList();
    var calendars = allCalendars
        .where((calendar) => calendar.isReadOnly == false)
        .toList();
    if (command.operation != 'create') {
      if (allCalendars.isEmpty) {
        throw const CalendarExecutionFailure('设备没有可安全修改的日历，已停止操作');
      }
      return _executeMutation(owner, command, allCalendars, isCurrent);
    }
    if (calendars.isEmpty) {
      if (!isCurrent()) throw StateError('账户已切换');
      final created = await plugin.createCalendar('言枢', localAccountName: '言枢');
      if (!created.isSuccess || created.data == null) {
        throw const CalendarExecutionFailure('设备没有可写日历，请在系统日历中启用账户后重试');
      }
      if (!isCurrent()) throw StateError('账户已切换');
      final reloaded = await plugin.retrieveCalendars();
      calendars =
          reloaded.data
              ?.where(
                (calendar) =>
                    calendar.isReadOnly == false && calendar.id != null,
              )
              .toList() ??
          [];
      if (!reloaded.isSuccess || calendars.isEmpty) {
        throw const CalendarExecutionFailure('专用日历尚未就绪，请稍后重试');
      }
    }
    return _executeCreate(owner, command, calendars, isCurrent);
  }

  Future<Map<String, dynamic>> _executeCreate(
    String owner,
    _CalendarCommand command,
    List<Calendar> available,
    bool Function() isCurrent,
  ) async {
    final marker = '[yanshu:$owner:${command.id}:${command.fingerprint}]';
    final key = _recordKey(owner, command);
    var saved = await _readRecord(key);
    if (saved == null) {
      saved = await _readRecord(_legacyRecordKey(owner, command));
      if (saved != null) {
        _validateRecord(saved, command);
        await storage.write(key: key, value: jsonEncode(saved));
      }
    }
    _validateRecord(saved, command);
    String? eventId = saved?['eventId'] is String
        ? saved!['eventId'] as String
        : null;
    String? calendarId = saved?['calendarId'] is String
        ? saved!['calendarId'] as String
        : null;
    final savedEventMalformed = saved?['eventId'] != null && eventId == null;
    final savedCalendarMalformed =
        saved?['calendarId'] != null && calendarId == null;
    if (savedEventMalformed || savedCalendarMalformed) {
      throw const CalendarExecutionFailure('本机日历标识无法核对，已停止重复创建');
    }
    var trustedNativeId = eventId != null;
    final creationUncertain = saved != null && eventId == null;
    bool hasMarker(Event event) => (event.description ?? '')
        .replaceAll(RegExp(r'\s+'), '')
        .contains(marker);
    final recovered = <(String, String)>[];
    final readable = <Calendar>[];
    for (final calendar in available) {
      final events = await _readEvents(
        calendar.id!,
        RetrieveEventsParams(
          startDate: command.start.subtract(const Duration(days: 1)),
          endDate: command.end.add(const Duration(days: 1)),
        ),
        marker,
      );
      if (!events.isSuccess) {
        if (calendarId == calendar.id) {
          throw const CalendarExecutionFailure('原日程所在日历暂不可访问，已停止重复创建');
        }
        continue;
      }
      readable.add(calendar);
      for (final event in events.data ?? <Event>[]) {
        if (!trustedNativeId && hasMarker(event) && event.eventId != null) {
          recovered.add((calendar.id!, event.eventId!));
        }
      }
    }
    if (!trustedNativeId && recovered.isNotEmpty) {
      if (recovered.toSet().length != 1) {
        throw const CalendarExecutionFailure('发现多个相同来源日程，请先核对系统日历，已停止重复创建');
      }
      calendarId = recovered.single.$1;
      eventId = recovered.single.$2;
      trustedNativeId = true;
    }
    if (creationUncertain && eventId == null) {
      throw const CalendarExecutionFailure('上次日历写入结果尚未核实，请检查系统日历，已停止重复创建');
    }
    if (calendarId != null &&
        !readable.any((calendar) => calendar.id == calendarId)) {
      throw const CalendarExecutionFailure('原日程所在日历已不可用，已停止重复创建');
    }
    if (readable.isEmpty) {
      if (!isCurrent()) throw StateError('账户已切换');
      final created = await plugin.createCalendar('言枢', localAccountName: '言枢');
      if (!created.isSuccess || created.data == null) {
        throw const CalendarExecutionFailure('系统日历不可访问，请在系统日历中启用可写账户');
      }
      final verifyCalendar = await _readEvents(
        created.data!,
        RetrieveEventsParams(
          startDate: command.start.subtract(const Duration(days: 1)),
          endDate: command.end.add(const Duration(days: 1)),
        ),
        marker,
      );
      if (!verifyCalendar.isSuccess) {
        throw const CalendarExecutionFailure('新建日历仍不可访问，请检查系统日历权限');
      }
      readable.add(Calendar(id: created.data, name: '言枢', isReadOnly: false));
    }
    if (!isCurrent()) throw StateError('账户已切换');
    if (eventId == null) {
      final calendar = readable.firstWhere(
        (value) => calendarId != null
            ? value.id == calendarId
            : value.isDefault == true,
        orElse: () => readable.first,
      );
      calendarId = calendar.id;
      await _writeRecord(
        key,
        command,
        state: 'pending',
        calendarId: calendarId,
      );
      final result = await _createEvent(
        Event(
          calendarId,
          title: command.title,
          description: marker,
          start: TZDateTime.from(command.start, UTC),
          end: TZDateTime.from(command.end, UTC),
        ),
        marker,
      );
      if (result?.isSuccess != true || result?.data == null) {
        throw const CalendarExecutionFailure('系统日历创建失败，请检查日历权限后重试');
      }
      eventId = result!.data;
      trustedNativeId = true;
      await _writeRecord(
        key,
        command,
        state: 'written',
        eventId: eventId,
        calendarId: calendarId,
      );
    }
    final readback = await _readEvents(
      calendarId!,
      RetrieveEventsParams(eventIds: [eventId!]),
      marker,
    );
    final matches =
        readback.data
            ?.where(
              (event) =>
                  event.eventId == eventId &&
                  event.title == command.title &&
                  (trustedNativeId || hasMarker(event)) &&
                  event.start?.millisecondsSinceEpoch ==
                      command.start.millisecondsSinceEpoch &&
                  event.end?.millisecondsSinceEpoch ==
                      command.end.millisecondsSinceEpoch,
            )
            .toList() ??
        [];
    if (!readback.isSuccess || matches.length != 1) {
      throw const CalendarExecutionFailure('创建结果未通过回读核验，重试会先检查已有日程');
    }
    if (!isCurrent()) throw StateError('账户已切换');
    await _writeRecord(
      key,
      command,
      state: 'verified',
      eventId: eventId,
      calendarId: calendarId,
    );
    return _receipt(
      command,
      eventId: eventId,
      calendarId: calendarId,
      previousEventId: null,
      deleted: false,
    );
  }

  Future<Map<String, dynamic>> _executeMutation(
    String owner,
    _CalendarCommand command,
    List<Calendar> available,
    bool Function() isCurrent,
  ) async {
    final targetId = command.targetEventId!;
    final marker = '[yanshu:$owner:${command.id}:${command.fingerprint}]';
    final key = _recordKey(owner, command);
    final saved = await _readRecord(key);
    _validateRecord(saved, command);
    final savedCalendar = saved?['calendarId'];
    if (savedCalendar != null && savedCalendar is! String) {
      throw const CalendarExecutionFailure('本机日历标识无法核对，已停止设备操作');
    }
    if (command.targetCalendarId != null &&
        savedCalendar != null &&
        savedCalendar != command.targetCalendarId) {
      throw const CalendarExecutionFailure('原日程所在日历已经变化，已停止设备操作');
    }
    final candidates = command.targetCalendarId == null
        ? available
        : available
              .where((calendar) => calendar.id == command.targetCalendarId)
              .toList();
    if (candidates.isEmpty) {
      throw const CalendarExecutionFailure('原日程所在日历不可写或不存在，已停止设备操作');
    }
    final located = <(Calendar, Event)>[];
    for (final calendar in candidates) {
      final result = await _readEvents(
        calendar.id!,
        RetrieveEventsParams(eventIds: [targetId]),
        marker,
      );
      if (!result.isSuccess) {
        throw const CalendarExecutionFailure('原日程暂时无法回读，已停止设备操作');
      }
      for (final event in result.data ?? <Event>[]) {
        if (event.eventId == targetId) located.add((calendar, event));
      }
    }
    if (located.length > 1) {
      throw const CalendarExecutionFailure('发现多个目标日程，已停止设备操作');
    }
    if (located.isEmpty) {
      if (command.operation == 'cancel' &&
          saved != null &&
          {'pending', 'verified'}.contains(saved['state']) &&
          savedCalendar is String &&
          candidates.any((calendar) => calendar.id == savedCalendar)) {
        if (!isCurrent()) throw StateError('账户已切换');
        await _writeRecord(
          key,
          command,
          state: 'verified',
          eventId: targetId,
          calendarId: savedCalendar,
        );
        return _receipt(
          command,
          eventId: targetId,
          calendarId: savedCalendar,
          previousEventId: targetId,
          deleted: true,
        );
      }
      throw const CalendarExecutionFailure('未找到唯一的原日程，已停止设备操作');
    }
    final (calendar, existing) = located.single;
    final calendarId = calendar.id!;
    if (calendar.isReadOnly != false) {
      throw const CalendarExecutionFailure('原日程所在日历不可写，已停止设备操作');
    }
    if (savedCalendar != null && savedCalendar != calendarId) {
      throw const CalendarExecutionFailure('原日程所在日历已经变化，已停止设备操作');
    }
    if (command.operation == 'reschedule') {
      if (_matches(existing, command)) {
        await _writeRecord(
          key,
          command,
          state: 'verified',
          eventId: targetId,
          calendarId: calendarId,
        );
        return _receipt(
          command,
          eventId: targetId,
          calendarId: calendarId,
          previousEventId: targetId,
          deleted: false,
        );
      }
      await _writeRecord(
        key,
        command,
        state: 'pending',
        eventId: targetId,
        calendarId: calendarId,
      );
      if (!isCurrent()) throw StateError('账户已切换');
      final result = await plugin.createOrUpdateEvent(
        Event(
          calendarId,
          eventId: targetId,
          title: command.title,
          description: existing.description,
          start: TZDateTime.from(command.start, UTC),
          end: TZDateTime.from(command.end, UTC),
        ),
      );
      final readback = await _readEvents(
        calendarId,
        RetrieveEventsParams(eventIds: [targetId]),
        marker,
      );
      final matches =
          readback.data
              ?.where(
                (event) =>
                    event.eventId == targetId && _matches(event, command),
              )
              .toList() ??
          [];
      if (result?.isSuccess != true ||
          result?.data != targetId ||
          !readback.isSuccess ||
          matches.length != 1) {
        throw const CalendarExecutionFailure('系统日历未能安全更新原日程，且不会创建第二条日程');
      }
      if (!isCurrent()) throw StateError('账户已切换');
      await _writeRecord(
        key,
        command,
        state: 'verified',
        eventId: targetId,
        calendarId: calendarId,
      );
      return _receipt(
        command,
        eventId: targetId,
        calendarId: calendarId,
        previousEventId: targetId,
        deleted: false,
      );
    }
    if (!_matches(existing, command)) {
      throw const CalendarExecutionFailure('原日程内容已经变化，已停止删除');
    }
    await _writeRecord(
      key,
      command,
      state: 'pending',
      eventId: targetId,
      calendarId: calendarId,
    );
    if (!isCurrent()) throw StateError('账户已切换');
    final result = await plugin.deleteEvent(calendarId, targetId);
    final readback = await _readEvents(
      calendarId,
      RetrieveEventsParams(eventIds: [targetId]),
      marker,
    );
    final stillExists =
        readback.data?.any((event) => event.eventId == targetId) ?? false;
    if (!result.isSuccess ||
        result.data != true ||
        !readback.isSuccess ||
        stillExists) {
      throw const CalendarExecutionFailure('取消结果未通过回读核验，不能标记为已删除');
    }
    if (!isCurrent()) throw StateError('账户已切换');
    await _writeRecord(
      key,
      command,
      state: 'verified',
      eventId: targetId,
      calendarId: calendarId,
    );
    return _receipt(
      command,
      eventId: targetId,
      calendarId: calendarId,
      previousEventId: targetId,
      deleted: true,
    );
  }

  bool _matches(Event event, _CalendarCommand command) =>
      event.title == command.title &&
      event.start?.millisecondsSinceEpoch ==
          command.start.millisecondsSinceEpoch &&
      event.end?.millisecondsSinceEpoch == command.end.millisecondsSinceEpoch;

  Map<String, dynamic> _receipt(
    _CalendarCommand command, {
    required String eventId,
    required String calendarId,
    required String? previousEventId,
    required bool deleted,
  }) => {
    'verified': true,
    'eventId': eventId,
    'previousEventId': previousEventId,
    'calendarId': calendarId,
    'deleted': deleted,
    'fingerprint': command.fingerprint,
    'title': command.title,
    'start': command.startText,
    'end': command.endText,
  };
}
