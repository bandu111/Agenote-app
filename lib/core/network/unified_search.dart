import 'api_client.dart';
import 'api_config.dart';

class UnifiedSearchHit {
  const UnifiedSearchHit({
    required this.id,
    required this.kind,
    required this.title,
    required this.text,
    required this.path,
    this.matchPercent,
    this.displayStatus = '',
  });
  final String id, kind, title, text, path, displayStatus;
  final int? matchPercent;
  String get kindLabel => switch (kind) {
    'document' => '资料',
    'goal' => '目标',
    'commitment' => '承诺',
    'task' => '任务',
    'utterance' => '原始发言',
    'meeting' => '会议',
    _ => '来源',
  };
}

class UnifiedSearchRepository {
  const UnifiedSearchRepository(this.client);
  final ApiClient client;
  Future<List<UnifiedSearchHit>> search(String query) async {
    final owner = client.accountId?.call();
    if (owner == null) throw const ApiFailure('请先登录账户');
    final response = await client.post(
      'search',
      authenticated: true,
      accountId: owner,
      receiveTimeout: const Duration(seconds: 45),
      data: {'query': query.trim(), 'limit': 24},
    );
    if (owner != client.accountId?.call()) throw const ApiFailure('账户已切换');
    return [
      for (final value in response['data'] as List)
        if (value is Map &&
            value['id'] is String &&
            value['kind'] is String &&
            value['title'] is String &&
            value['path'] is String &&
            _safePath(value['path']))
          UnifiedSearchHit(
            id: value['id'],
            kind: value['kind'],
            title: value['title'],
            text: value['text'] as String? ?? '',
            path: value['path'],
            displayStatus: value['displayStatus'] as String? ?? '',
            matchPercent: value['matchPercent'] is int
                ? (value['matchPercent'] as int).clamp(0, 100)
                : null,
          ),
    ];
  }

  bool _safePath(String value) {
    final uri = Uri.tryParse(value);
    return uri != null &&
        !uri.hasScheme &&
        !uri.hasAuthority &&
        (uri.path.startsWith('/knowledge/documents/') ||
            uri.path.startsWith('/progress/goals/') ||
            uri.path.startsWith('/progress/commitments/') ||
            uri.path == '/meeting' ||
            uri.path == '/home' ||
            uri.path == '/notifications');
  }
}
