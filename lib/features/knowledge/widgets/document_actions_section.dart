import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../notifications/knowledge_assistance.dart';

/// 候选只在资料内聚合；采用后才进入真实进展的补全流程。
class DocumentActionsSection extends StatefulWidget {
  const DocumentActionsSection({
    super.key,
    required this.documentId,
    required this.versionId,
  });
  final String documentId, versionId;
  @override
  State<DocumentActionsSection> createState() => _DocumentActionsSectionState();
}

class _DocumentActionsSectionState extends State<DocumentActionsSection> {
  KnowledgeAssistance? _service;
  Future<Map<String, dynamic>>? _future;
  final _busy = <String>{};
  String? _error;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final service = context.watch<KnowledgeAssistance?>();
    if (service != _service) {
      _busy.clear();
      _error = null;
      _service = service;
      _future = service?.documentActions(widget.documentId, widget.versionId);
    }
  }

  @override
  void didUpdateWidget(covariant DocumentActionsSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.documentId != widget.documentId ||
        oldWidget.versionId != widget.versionId) {
      _busy.clear();
      _error = null;
      _future = _service?.documentActions(widget.documentId, widget.versionId);
    }
  }

  Future<void> _record(Map<String, dynamic> item) async {
    final service = _service;
    final documentId = widget.documentId, versionId = widget.versionId;
    final id = item['id'] as String;
    if (service == null || _busy.contains(id)) return;
    bool current() =>
        mounted &&
        identical(service, _service) &&
        documentId == widget.documentId &&
        versionId == widget.versionId;
    setState(() {
      _busy.add(id);
      _error = null;
    });
    try {
      if (await service.recordDocumentAction(item) != true) {
        throw StateError('not recorded');
      }
      if (current()) {
        setState(() {
          _future = service.documentActions(
            widget.documentId,
            widget.versionId,
          );
        });
      }
    } catch (_) {
      if (current()) setState(() => _error = '记录未完成，请重试');
    } finally {
      if (current()) setState(() => _busy.remove(id));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_future == null) return const SizedBox.shrink();
    return FutureBuilder<Map<String, dynamic>>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return TextButton(
            onPressed: () => setState(() {
              _future = _service?.documentActions(
                widget.documentId,
                widget.versionId,
              );
            }),
            child: const Text('资料行动暂不可用，点击重试'),
          );
        }
        final rawActions = snapshot.data?['actions'];
        final actions = (rawActions is List ? rawActions : const [])
            .whereType<Map>()
            .where(
              (a) =>
                  a['id'] is String &&
                  a['title'] is String &&
                  (a['title'] as String).trim().isNotEmpty &&
                  a['quote'] is String,
            )
            .map((a) => Map<String, dynamic>.from(a))
            .toList();
        if (actions.isEmpty) return const SizedBox.shrink();
        final theme = Theme.of(context);
        return Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: theme.colorScheme.surface,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: theme.colorScheme.outlineVariant),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '资料中的行动 · ${actions.length}',
                  style: theme.textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                Text('核对原文后，可将需要跟进的事项记录到进展。', style: theme.textTheme.bodySmall),
                for (final item in actions)
                  Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          item['title'] as String,
                          style: theme.textTheme.bodyLarge,
                        ),
                        const SizedBox(height: 6),
                        Text(
                          item['quote'] as String,
                          style: theme.textTheme.bodySmall,
                        ),
                        Row(
                          children: [
                            Expanded(
                              child: Text(switch (item['modality']) {
                                'proposal' => '建议 · 尚未承诺',
                                'conditional' => '附带条件 · 需核对',
                                _ => '待核对',
                              }, style: theme.textTheme.labelSmall),
                            ),
                            if (item['state'] == 'pending')
                              TextButton(
                                onPressed: _busy.contains(item['id'])
                                    ? null
                                    : () => _record(item),
                                child: Text(
                                  _busy.contains(item['id']) ? '正在记录' : '记录到进展',
                                ),
                              )
                            else
                              const Text('已处理'),
                          ],
                        ),
                      ],
                    ),
                  ),
                if (_error != null)
                  Text(
                    _error!,
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}
