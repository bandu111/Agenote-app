enum ScheduleKind { meeting, task }

enum ScheduleStatus {
  upcoming,
  ongoing,
  ended,
  overdue,
  completed,
  needsReview,
}

String? validatedPreparationRoute(Object? value, {String? preparationId}) {
  if (value is! String || value.length > 500) return null;
  final match = RegExp(r'^/outcomes/([^/?#]+)$').firstMatch(value);
  if (match == null) return null;
  String id;
  try {
    id = Uri.decodeComponent(match.group(1)!);
  } on FormatException {
    return null;
  }
  if (id.isEmpty ||
      id == '.' ||
      id == '..' ||
      id.contains('/') ||
      id.contains(r'\') ||
      id.runes.any((rune) => rune < 0x20 || rune == 0x7f) ||
      (preparationId != null && id != preparationId)) {
    return null;
  }
  return '/outcomes/${Uri.encodeComponent(id)}';
}

class ScheduleItem {
  ScheduleItem({
    required this.id,
    required this.title,
    required DateTime startsAt,
    DateTime? endsAt,
    required this.kind,
    this.completed = false,
    this.sourceTimeZone = '设备本地时区',
    this.notes = '',
    this.sourceLabel = '演示数据 · 仅保存在本次运行中',
    this.sourceRoute,
    this.hasDeadline = true,
    this.deadlineHasTime = true,
    this.hasCalendarDate = true,
    this.sourceMeetingDate,
    this.reviewPending = false,
    this.preparationId,
    this.preparationStatus,
    this.preparationSummary,
    String? preparationRoute,
    this.agenda,
    this.timeZone,
    this.authority,
    this.actionVersion,
    DateTime? verifiedAt,
  }) : startsAt = startsAt.toUtc(),
       endsAt = endsAt?.toUtc(),
       preparationRoute = validatedPreparationRoute(
         preparationRoute,
         preparationId: preparationId,
       ),
       verifiedAt = verifiedAt?.toUtc() {
    if (id.isEmpty || title.trim().isEmpty) throw ArgumentError('安排必须有 ID 和标题');
    if (this.endsAt != null && this.endsAt!.isBefore(this.startsAt)) {
      throw ArgumentError('结束时间不能早于开始时间');
    }
  }
  final String id;
  final String title;
  final DateTime startsAt;
  final DateTime? endsAt;
  final ScheduleKind kind;
  final bool completed;
  final String sourceTimeZone;
  final String notes;
  final String sourceLabel;
  final String? sourceRoute;
  final bool hasDeadline;
  final bool deadlineHasTime;
  final bool hasCalendarDate;
  // Date shown by the source minutes, not an instant to shift across timezones.
  final DateTime? sourceMeetingDate;
  final bool reviewPending;
  final String? preparationId;
  final String? preparationStatus;
  final String? preparationSummary;
  final String? preparationRoute;
  final String? agenda;
  final String? timeZone;
  final String? authority;
  final int? actionVersion;
  final DateTime? verifiedAt;

  ScheduleItem complete({bool completed = true}) => ScheduleItem(
    id: id,
    title: title,
    startsAt: startsAt,
    endsAt: endsAt,
    kind: kind,
    completed: completed,
    sourceTimeZone: sourceTimeZone,
    notes: notes,
    sourceLabel: sourceLabel,
    sourceRoute: sourceRoute,
    hasDeadline: hasDeadline,
    deadlineHasTime: deadlineHasTime,
    hasCalendarDate: hasCalendarDate,
    sourceMeetingDate: sourceMeetingDate,
    reviewPending: reviewPending,
    preparationId: preparationId,
    preparationStatus: preparationStatus,
    preparationSummary: preparationSummary,
    preparationRoute: preparationRoute,
    agenda: agenda,
    timeZone: timeZone,
    authority: authority,
    actionVersion: actionVersion,
    verifiedAt: verifiedAt,
  );
}

class ScheduleEntry {
  const ScheduleEntry(this.item, this.status, this.localStart);
  final ScheduleItem item;
  final ScheduleStatus status;
  final DateTime localStart;
  String get timeLabel =>
      '${localStart.hour.toString().padLeft(2, '0')}:${localStart.minute.toString().padLeft(2, '0')}';
  String get statusLabel => switch (status) {
    ScheduleStatus.upcoming => item.kind == ScheduleKind.task ? '待完成' : '待开始',
    ScheduleStatus.ongoing => '进行中',
    ScheduleStatus.ended => '已过期',
    ScheduleStatus.overdue => '已过期',
    ScheduleStatus.completed => '已完成',
    ScheduleStatus.needsReview => '待确认结束',
  };
  bool get isPast =>
      status == ScheduleStatus.ended ||
      status == ScheduleStatus.overdue ||
      status == ScheduleStatus.completed;
}
