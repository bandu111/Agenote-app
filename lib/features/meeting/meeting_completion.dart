/// 精确绑定会议原话的服务端履约项，不以相似文本猜测关联。
class MeetingCompletionItem {
  const MeetingCompletionItem({
    required this.id,
    required this.title,
    required this.version,
    this.side,
    this.deadline,
    this.confirmed = false,
    this.reviewPending = false,
    this.sourceIds = const [],
  });
  final String id, title;
  final int version;
  final String? side;
  final DateTime? deadline;
  final bool confirmed, reviewPending;
  final List<String> sourceIds;
  bool get needsSide => side == null;
  bool get needsDeadline => deadline == null;

  factory MeetingCompletionItem.fromJson(
    Map<String, dynamic> value,
  ) => MeetingCompletionItem(
    id: value['id'],
    title: value['title'],
    version: value['version'],
    sourceIds: {
      if (value['evidence']?['id'] is String) value['evidence']['id'] as String,
      for (final event in value['sourceEvents'] as List? ?? [])
        for (final id in event['evidence_ids'] as List? ?? [])
          if (id is String) id,
    }.toList(),
    side: ['ours', 'theirs'].contains(value['side']) ? value['side'] : null,
    deadline: DateTime.tryParse(value['deadline'] ?? '')?.toLocal(),
    confirmed:
        ['ours', 'theirs'].contains(value['side']) &&
        DateTime.tryParse(value['deadline'] ?? '') != null &&
        value['reviewPending'] != true &&
        value['reason'] != '原话已变更，等待重新核对' &&
        value['authorizationStatus'] == 'owner_confirmed' &&
        ['planned', 'active', 'claimed', 'verified'].contains(value['status']),
    reviewPending:
        value['reviewPending'] == true || value['reason'] == '原话已变更，等待重新核对',
  );
}
