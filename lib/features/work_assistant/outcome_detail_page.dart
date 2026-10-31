import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/network/api_client.dart';
import '../../core/network/api_config.dart';
import '../../shared/widgets/content_skeleton.dart';
import '../profile/viewmodels/profile_view_model.dart';
import 'outcome_page.dart';

class OutcomeDetailPage extends StatefulWidget {
  const OutcomeDetailPage({super.key, required this.runId});
  final String runId;

  @override
  State<OutcomeDetailPage> createState() => _OutcomeDetailPageState();
}

class _OutcomeDetailPageState extends State<OutcomeDetailPage> {
  ApiClient? _client;
  String? _owner;
  Map<String, dynamic>? _row;
  String? _error;
  bool _captured = false;
  bool _loading = false;
  bool _notFound = false;
  bool _switched = false;
  int _revision = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final profile = context.watch<ProfileViewModel>();
    if (!_captured) {
      if (!profile.ready) return;
      _captured = true;
      _owner = profile.data.accountId;
      _client = profile.repository.client;
      if (!profile.data.sessionActive ||
          _owner!.isEmpty ||
          _client == null ||
          _client!.accountId?.call() != _owner) {
        _error = '请登录云端账号后查看成果';
        return;
      }
      _loading = true;
      final revision = ++_revision;
      unawaited(_load(revision));
      return;
    }
    if (!_switched &&
        (_owner != profile.data.accountId ||
            !profile.data.sessionActive ||
            _client != profile.repository.client ||
            _client?.accountId?.call() != _owner)) {
      _switched = true;
      _row = null;
      _loading = false;
      ++_revision;
    }
  }

  bool _current(int revision) {
    if (!mounted || _switched || revision != _revision) return false;
    final profile = context.read<ProfileViewModel>();
    return profile.data.sessionActive &&
        profile.data.accountId == _owner &&
        profile.repository.client == _client &&
        _client?.accountId?.call() == _owner;
  }

  Future<void> _load(int revision) async {
    final client = _client;
    final owner = _owner;
    if (client == null || owner == null || !_current(revision)) return;
    try {
      final response = await client.get(
        'assistant/outcomes/${Uri.encodeComponent(widget.runId)}',
        authenticated: true,
        accountId: owner,
      );
      if (!_current(revision)) return;
      final raw = response['data'];
      if (raw is! Map) throw const ApiFailure('成果数据无法读取');
      final row = Map<String, dynamic>.from(raw);
      if (row['id'] != widget.runId) {
        throw const ApiFailure('成果数据无法核对');
      }
      setState(() {
        _row = row;
        _error = null;
        _notFound = false;
        _loading = false;
      });
    } on ApiFailure catch (failure) {
      if (!_current(revision)) return;
      setState(() {
        _row = null;
        _notFound = failure.status == 404;
        _error = _notFound ? '成果已失效或不存在' : failure.message;
        _loading = false;
      });
    } catch (_) {
      if (!_current(revision)) return;
      setState(() {
        _row = null;
        _notFound = false;
        _error = '成果暂时无法读取，请重试';
        _loading = false;
      });
    }
  }

  void _retry() {
    if (_switched || _client == null || _owner == null) return;
    setState(() {
      _loading = true;
      _error = null;
      _notFound = false;
      _row = null;
    });
    final revision = ++_revision;
    unawaited(_load(revision));
  }

  @override
  Widget build(BuildContext context) {
    if (_switched) {
      return const Scaffold(body: Center(child: Text('账号已切换，请返回重新打开成果')));
    }
    final row = _row;
    if (row != null && _client != null && _owner != null) {
      return OutcomePage(row: row, owner: _owner!, client: _client!);
    }
    if (!_captured || _loading) {
      return Scaffold(
        appBar: AppBar(title: const Text('成果详情')),
        body: const ContentSkeleton(
          layout: SkeletonLayout.detail,
          rows: 3,
          label: '正在加载成果详情',
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(title: const Text('成果详情')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_error ?? '成果暂时无法读取'),
              if (!_notFound && _client != null) ...[
                const SizedBox(height: 12),
                TextButton(onPressed: _retry, child: const Text('重试')),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
