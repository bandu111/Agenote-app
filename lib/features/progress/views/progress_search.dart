import '../../../shared/widgets/content_skeleton.dart';
import 'dart:async';
import 'package:provider/provider.dart';
import '../../meeting/meeting_view_model.dart';
import '../../../core/network/unified_search.dart';
import '../../../core/network/api_config.dart';
import '../repositories/dio_progress_repository.dart';
import 'package:flutter/material.dart';
import '../viewmodels/progress_view_model.dart';
import '../../knowledge/widgets/knowledge_components.dart';

class ProgressSearch extends SearchDelegate<String?> {
  ProgressSearch(this.model) : super(searchFieldLabel: '搜索会议、进展与知识库');
  final ProgressViewModel model;
  @override
  List<Widget> buildActions(BuildContext context) => [
    IconButton(
      tooltip: '清空搜索',
      onPressed: () => query = '',
      icon: const Icon(Icons.clear),
    ),
  ];
  @override
  Widget buildLeading(BuildContext context) =>
      BackButton(onPressed: () => close(context, null));
  @override
  Widget buildResults(BuildContext context) => _results(context);
  @override
  Widget buildSuggestions(BuildContext context) => _results(context);
  Widget _results(BuildContext context) => ProgressSearchResults(
    model: model,
    query: query,
    onOpen: (path) => close(context, path),
  );
}

class ProgressSearchResults extends StatelessWidget {
  const ProgressSearchResults({
    super.key,
    required this.model,
    required this.query,
    required this.onOpen,
  });
  final ProgressViewModel model;
  final String query;
  final ValueChanged<String> onOpen;
  void _open(BuildContext context, String path) {
    final meeting = context.read<MeetingViewModel?>();
    final uri = Uri.parse(path);
    if (uri.path == '/meeting' &&
        meeting?.active == true &&
        uri.queryParameters['id'] != meeting?.record?.id) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('当前会议仍在录音，结束后可查看其他会议原话。')));
      return;
    }
    onOpen(path);
  }

  @override
  Widget build(BuildContext context) {
    if (query.trim().isEmpty) {
      return const Center(child: Text('输入会议、目标、承诺或资料关键词'));
    }
    final repository = model.repository;
    if (repository is DioProgressRepository) {
      return _UnifiedResults(
        key: ValueKey(model.accountScopeRevision),
        query: query,
        repository: UnifiedSearchRepository(repository.client),
        onOpen: (path) => _open(context, path),
      );
    }
    final hits = model.search(query);
    if (hits.isEmpty) return const Center(child: Text('没有找到相关进展'));
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      itemCount: hits.length,
      itemBuilder: (context, index) {
        final hit = hits[index];
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: KnowledgeSurface(
            padding: 0,
            child: ListTile(
              title: Text(hit.title),
              subtitle: Text(
                '${hit.kind} · ${hit.subtitle}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _open(context, hit.path),
            ),
          ),
        );
      },
    );
  }
}

class _UnifiedResults extends StatefulWidget {
  const _UnifiedResults({
    super.key,
    required this.query,
    required this.repository,
    required this.onOpen,
  });
  final String query;
  final UnifiedSearchRepository repository;
  final ValueChanged<String> onOpen;
  @override
  State<_UnifiedResults> createState() => _UnifiedResultsState();
}

class _UnifiedResultsState extends State<_UnifiedResults> {
  Timer? _timer;
  int _revision = 0;
  bool _loading = true;
  String? _error;
  List<UnifiedSearchHit> _hits = [];
  @override
  void initState() {
    super.initState();
    _schedule();
  }

  @override
  void didUpdateWidget(covariant _UnifiedResults oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.query != widget.query) _schedule();
  }

  void _schedule() {
    final revision = ++_revision;
    _timer?.cancel();
    _loading = true;
    _error = null;
    _hits = [];
    _timer = Timer(const Duration(milliseconds: 300), () async {
      try {
        final result = await widget.repository.search(widget.query);
        if (!mounted || revision != _revision) return;
        setState(() {
          _hits = result;
          _loading = false;
        });
      } on ApiFailure catch (error) {
        if (mounted && revision == _revision) {
          setState(() {
            _error = error.message;
            _loading = false;
          });
        }
      } catch (_) {
        if (mounted && revision == _revision) {
          setState(() {
            _error = '检索未完成，请重试';
            _loading = false;
          });
        }
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    ++_revision;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const ContentSkeleton(label: '正在搜索相关资料');
    if (_error != null) {
      return Center(
        child: TextButton(
          onPressed: () => setState(_schedule),
          child: Text(_error!),
        ),
      );
    }
    if (_hits.isEmpty) return const Center(child: Text('没有找到匹配来源'));
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      itemCount: _hits.length,
      itemBuilder: (context, index) {
        final hit = _hits[index];
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: KnowledgeSurface(
            padding: 0,
            child: ListTile(
              title: Text(hit.title),
              subtitle: Text(
                '${hit.kindLabel}${hit.displayStatus.isEmpty ? '' : ' · ${hit.displayStatus}'} · ${hit.text}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => widget.onOpen(hit.path),
            ),
          ),
        );
      },
    );
  }
}
