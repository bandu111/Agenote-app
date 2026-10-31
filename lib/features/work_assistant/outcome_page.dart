import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:go_router/go_router.dart';
import '../../core/network/api_client.dart';
import '../profile/viewmodels/profile_view_model.dart';
import 'pdf_button.dart';

String _text(Object? value) => value is String ? value : '';
Map<String, dynamic> _map(Object? value) => value is Map
    ? {
        for (final e in value.entries)
          if (e.key is String) e.key as String: e.value,
      }
    : {};
List<Map<String, dynamic>> _rows(Object? value) =>
    value is List ? value.whereType<Map>().map(_map).toList() : [];
List<String> _strings(Object? value) =>
    value is List ? value.whereType<String>().toList() : [];

String _status(String? value) => switch (value) {
  'succeeded' => '分析已完成',
  'queued' => '等待分析',
  'running' => '分析中',
  'retryable' => '等待重试',
  'failed' => '分析失败',
  'skipped' => '未发现需要额外分析的问题',
  'expired' => '已失效',
  'stale' => '会议依据已变更',
  'cancelled' => '已取消',
  _ => '状态待核对',
};

String _delivery(Map? value) => switch (value?['status']) {
  'accepted' => '摘要已由微信通道接收',
  'sending' || 'uncertain' => '微信发送结果待核对，不会自动重复发送',
  'retryable' => '微信发送暂未成功，将有限重试',
  'suppressed' => '本次未主动推送',
  _ => '尚未发送到微信',
};

String? _sourcePath(Object? value) {
  if (value is! String || value.length > 500 || value.contains(r'\')) {
    return null;
  }
  final uri = Uri.tryParse(value);
  if (uri == null ||
      uri.hasScheme ||
      uri.hasAuthority ||
      uri.fragment.isNotEmpty ||
      !uri.path.startsWith('/')) {
    return null;
  }
  late final List<String> segments;
  try {
    segments = uri.pathSegments;
  } on FormatException {
    return null;
  }
  if (segments.any(
    (segment) =>
        segment.isEmpty ||
        segment == '.' ||
        segment == '..' ||
        segment.contains('/') ||
        segment.contains(r'\') ||
        segment.runes.any((rune) => rune < 0x20 || rune == 0x7f),
  )) {
    return null;
  }
  if (uri.path == '/meeting') {
    if (uri.queryParameters.keys.any((key) => key != 'id') ||
        _text(uri.queryParameters['id']).isEmpty) {
      return null;
    }
    return value;
  }
  if (segments.length == 3 &&
      segments[0] == 'knowledge' &&
      segments[1] == 'documents' &&
      segments[2].isNotEmpty) {
    const allowedQuery = {
      'version',
      'start',
      'end',
      'hash',
      'relation',
      'relationQuery',
      'quote',
    };
    return uri.queryParameters.keys.every(allowedQuery.contains) ? value : null;
  }
  return null;
}

class OutcomePage extends StatelessWidget {
  const OutcomePage({
    super.key,
    required this.row,
    required this.owner,
    required this.client,
  });
  final Map<String, dynamic> row;
  final String owner;
  final ApiClient client;

  @override
  Widget build(BuildContext context) {
    if (context.watch<ProfileViewModel>().data.accountId != owner) {
      return const Scaffold(body: Center(child: Text('账号已切换，请返回重新打开成果')));
    }
    if (row['kind'] == 'meeting_preparation') {
      return Scaffold(
        appBar: AppBar(title: const Text('会前准备')),
        body: _MeetingPreparation(row: row),
      );
    }
    return Scaffold(
      appBar: AppBar(title: const Text('分析成果')),
      body: _RoleOutcome(row: row, owner: owner, client: client),
    );
  }
}

class _MeetingPreparation extends StatelessWidget {
  const _MeetingPreparation({required this.row});
  final Map<String, dynamic> row;

  @override
  Widget build(BuildContext context) {
    final report = _map(row['result']);
    final meeting = _map(report['meeting']);
    final sources = _rows(report['sources']);
    final sourcesById = <String, Map<String, dynamic>>{
      for (final source in sources)
        if (_text(source['id']).isNotEmpty) _text(source['id']): source,
    };
    final title = _text(report['title']);
    final summary = _text(report['summary']);
    final meetingTitle = _text(meeting['title']);
    final meetingStart = _text(meeting['start']);
    final timeZone = _text(meeting['timeZone']);
    final agenda = _text(meeting['agenda']);
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text(_status(_text(row['status']))),
        if (row['error'] != null) Text('失败原因：${row['error']}'),
        if (title.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text(title, style: Theme.of(context).textTheme.headlineSmall),
        ],
        if (summary.isNotEmpty) ...[const SizedBox(height: 12), Text(summary)],
        if (meeting.isNotEmpty) ...[
          const SizedBox(height: 20),
          Text('会议', style: Theme.of(context).textTheme.titleMedium),
          if (meetingTitle.isNotEmpty) Text(meetingTitle),
          if (meetingStart.isNotEmpty || timeZone.isNotEmpty)
            Text(
              [
                meetingStart,
                timeZone,
              ].where((value) => value.isNotEmpty).join(' · '),
            ),
          if (agenda.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text('议程：$agenda'),
          ],
        ],
        for (final section in _rows(report['sections'])) ...[
          if (_text(section['title']).isNotEmpty ||
              _text(section['content']).isNotEmpty) ...[
            const SizedBox(height: 20),
            if (_text(section['title']).isNotEmpty)
              Text(
                _text(section['title']),
                style: Theme.of(context).textTheme.titleMedium,
              ),
            if (_text(section['content']).isNotEmpty)
              Text(_text(section['content'])),
          ],
        ],
        if (_rows(report['checklist']).isNotEmpty) ...[
          const SizedBox(height: 20),
          Text('准备清单', style: Theme.of(context).textTheme.titleMedium),
          for (final item in _rows(report['checklist']))
            if (_text(item['text']).isNotEmpty)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.checklist_rounded),
                title: Text(_text(item['text'])),
                subtitle: Text(
                  item['status'] == 'needs_confirmation' ? '待确认' : '建议准备',
                ),
              ),
        ],
        if (_rows(report['reading']).isNotEmpty) ...[
          const SizedBox(height: 20),
          Text('建议阅读', style: Theme.of(context).textTheme.titleMedium),
          for (final item in _rows(report['reading']))
            if (_text(item['title']).isNotEmpty)
              _ReadingItem(
                item: item,
                source: sourcesById[_text(item['sourceId'])],
              ),
        ],
        if (_strings(report['dataGaps']).isNotEmpty) ...[
          const SizedBox(height: 20),
          Text('数据缺口', style: Theme.of(context).textTheme.titleMedium),
          for (final gap in _strings(report['dataGaps']))
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text('• $gap'),
            ),
        ],
        if (sources.isNotEmpty) ...[
          const SizedBox(height: 20),
          Text('资料依据', style: Theme.of(context).textTheme.titleMedium),
          for (final source in sources) _PreparationSource(source: source),
        ],
      ],
    );
  }
}

class _ReadingItem extends StatelessWidget {
  const _ReadingItem({required this.item, this.source});
  final Map<String, dynamic> item;
  final Map<String, dynamic>? source;

  @override
  Widget build(BuildContext context) {
    final reason = _text(item['reason']);
    final path = _sourcePath(source?['path']);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(_text(item['title'])),
      subtitle: reason.isEmpty ? null : Text(reason),
      trailing: path == null
          ? null
          : TextButton(
              onPressed: () => context.push(path),
              child: const Text('查看资料'),
            ),
    );
  }
}

class _PreparationSource extends StatelessWidget {
  const _PreparationSource({required this.source});
  final Map<String, dynamic> source;

  @override
  Widget build(BuildContext context) {
    final title = _text(source['title']);
    final quote = _text(source['quote']);
    final path = _sourcePath(source['path']);
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (title.isNotEmpty)
            Text(title, style: Theme.of(context).textTheme.titleSmall),
          if (quote.isNotEmpty) SelectableText(quote),
          if (path != null)
            TextButton(
              onPressed: () => context.push(path),
              child: const Text('查看资料'),
            ),
        ],
      ),
    );
  }
}

class _RoleOutcome extends StatelessWidget {
  const _RoleOutcome({
    required this.row,
    required this.owner,
    required this.client,
  });
  final Map<String, dynamic> row;
  final String owner;
  final ApiClient client;

  @override
  Widget build(BuildContext context) {
    final report = _map(row['result']);
    final evidence = _map(report['evidence']);
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text(
          _text(report['title']).isEmpty ? '会议成果分析' : _text(report['title']),
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 12),
        Text(_status(_text(row['status']))),
        Text(_delivery(_map(row['delivery']))),
        if (row['status'] == 'succeeded' && _text(row['id']).isNotEmpty)
          OutcomePdfButton(
            client: client,
            owner: owner,
            runId: _text(row['id']),
          ),
        if (row['error'] != null) Text('失败原因：${row['error']}'),
        const SizedBox(height: 16),
        Text(_text(report['summary'])),
        if (report['analysis_goal'] is String) ...[
          const SizedBox(height: 20),
          Text('本次分析目标', style: Theme.of(context).textTheme.titleMedium),
          Text(report['analysis_goal'] as String),
        ],
        for (final metric in _rows(report['metrics'])) ...[
          const SizedBox(height: 14),
          Text(
            _text(metric['name']),
            style: Theme.of(context).textTheme.titleSmall,
          ),
          Text(
            metric['status'] == 'computed'
                ? '服务器计算：${metric['value']}'
                : metric['status'] == 'quoted'
                ? '原文引用：${metric['value']}'
                : '尚缺数据',
          ),
          Text(_text(metric['quote'] ?? metric['missing_data'])),
        ],
        for (final method in _rows(report['methods'])) ...[
          const SizedBox(height: 14),
          Text(
            '${method['name']} · ${method['status'] == 'performed' ? '已执行' : '尚未执行'}',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          Text(_text(method['detail'])),
        ],
        for (final section in _rows(report['sections'])) ...[
          const SizedBox(height: 20),
          Text(
            _text(section['title']),
            style: Theme.of(context).textTheme.titleMedium,
          ),
          Text(_text(section['content'])),
        ],
        for (final table in _rows(
          report['analysis_tables'],
        ).where((table) => _strings(table['columns']).isNotEmpty)) ...[
          const SizedBox(height: 20),
          Text(
            _text(table['title']),
            style: Theme.of(context).textTheme.titleMedium,
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              columns: [
                for (final column in _strings(table['columns']))
                  DataColumn(label: Text(column)),
              ],
              rows: [
                for (final cells
                    in (table['rows'] is List ? table['rows'] as List : [])
                        .whereType<List>()
                        .where(
                          (row) =>
                              row.length == _strings(table['columns']).length,
                        ))
                  DataRow(
                    cells: [
                      for (final cell in cells)
                        DataCell(Text(_text(_map(cell)['text']))),
                    ],
                  ),
              ],
            ),
          ),
          if (_text(table['interpretation']).isNotEmpty)
            Text(_text(table['interpretation'])),
        ],
        for (final risk in _rows(report['risks'])) ...[
          const SizedBox(height: 16),
          Text(
            '${switch (risk['severity']) {
              'high' => '高',
              'medium' => '中',
              _ => '低',
            }}风险 · ${risk['title']}',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          Text(_text(risk['detail'])),
        ],
        for (final action in _rows(report['actions'])) ...[
          const SizedBox(height: 16),
          Text(
            action['basis'] == 'meeting_confirmed' ? '会议已确认安排' : '行动建议 · 待确认',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          Text(_text(action['action'])),
          Text(
            '${_text(action['owner']).isEmpty ? '负责人待明确' : action['owner']} · ${_text(action['deadline']).isEmpty ? '期限待明确' : action['deadline']}',
          ),
          if (_text(action['expected_outcome']).isNotEmpty)
            Text(_text(action['expected_outcome'])),
        ],
        for (final finding in _rows(report['findings'])) ...[
          const SizedBox(height: 20),
          Text(switch (finding['certainty']) {
            'hypothesis' => '待验证假设',
            'correlation' => '相关性观察',
            'unverified' => '尚无法核验',
            _ => '证据观察',
          }, style: TextStyle(color: Theme.of(context).colorScheme.primary)),
          Text(_text(finding['text'])),
          for (final id in _strings(finding['evidence_ids']))
            TextButton(
              onPressed: () {
                final source = _map(evidence[id]);
                final path = source['path'];
                if (path is String &&
                    path.startsWith('/knowledge/documents/')) {
                  context.push(path);
                } else {
                  context.push(
                    '/meetings/${row['clientId'] ?? row['meetingId']}/minutes',
                  );
                }
              },
              child: const Text('查看原始依据'),
            ),
        ],
        for (final entry in [
          ('建议行动', 'next_steps'),
          ('数据缺口', 'data_gaps'),
        ]) ...[
          const SizedBox(height: 20),
          Text(entry.$1, style: Theme.of(context).textTheme.titleMedium),
          for (final text in _strings(report[entry.$2]))
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text('• $text'),
            ),
        ],
      ],
    );
  }
}
