import 'dart:async';
import 'package:flutter/material.dart';
import '../home/views/home_style.dart';
import 'meeting_completion.dart';
import '../../core/network/api_config.dart';

/// 按服务端实际缺项展示；用户补齐后自动提交，原始转写始终保留。
class MeetingCompletionPanel extends StatefulWidget {
  const MeetingCompletionPanel({
    super.key,
    required this.sourceId,
    required this.loadItems,
    required this.onConfirm,
    this.active = true,
    this.dataRevision = 0,
    this.analysisPending = false,
  });
  final String sourceId;
  final bool active, analysisPending;
  final int dataRevision;
  final Future<List<MeetingCompletionItem>> Function() loadItems;
  final Future<MeetingCompletionItem> Function(
    MeetingCompletionItem item,
    String side,
    DateTime deadline,
  )
  onConfirm;
  @override
  State<MeetingCompletionPanel> createState() => _MeetingCompletionPanelState();
}

class _MeetingCompletionPanelState extends State<MeetingCompletionPanel> {
  String? _side, _saveError, _loadError, _lastAttempt;
  DateTime? _date;
  List<MeetingCompletionItem> _items = [];
  MeetingCompletionItem? _item;
  bool _fetching = false, _saving = false, _loaded = false;
  bool _reloadPending = false, _pickingDate = false, _holdSubmit = false;
  final _edited = <String>{};
  Timer? _retry;
  int _retryCount = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant MeetingCompletionPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.active) {
      _retry?.cancel();
      return;
    }
    if (!oldWidget.active ||
        widget.dataRevision != oldWidget.dataRevision ||
        widget.analysisPending != oldWidget.analysisPending) {
      _retryCount = 0;
      _retry?.cancel();
      if (_fetching || _saving || _pickingDate) {
        _reloadPending = true;
      } else {
        _load();
      }
    }
  }

  @override
  void dispose() {
    _retry?.cancel();
    super.dispose();
  }

  void _select(MeetingCompletionItem item, {bool preserveDraft = false}) {
    final keep =
        preserveDraft && _item?.id == item.id && _item?.title == item.title;
    final side = _side, date = _date;
    _item = item;
    _side = item.side ?? (keep ? side : null);
    _date = item.deadline ?? (keep ? date : null);
    if (!keep) {
      _edited.clear();
      _lastAttempt = null;
      _saveError = null;
    }
    if (!item.needsSide) _edited.remove('side');
    if (!item.needsDeadline) _edited.remove('deadline');
    if (item.confirmed) {
      _saveError = null;
      _edited.clear();
    }
  }

  Future<void> _load() async {
    if (!mounted || !widget.active) return;
    if (_fetching || _saving || _pickingDate) {
      _reloadPending = true;
      return;
    }
    _retry?.cancel();
    setState(() {
      _fetching = true;
      _loadError = null;
    });
    try {
      final received = await widget.loadItems();
      if (!mounted) return;
      final items = [
        for (final item in received)
          if (_item?.id == item.id && _item!.version > item.version)
            _item!
          else
            item,
      ];
      setState(() {
        final selected =
            items.where((i) => i.id == _item?.id).firstOrNull ??
            (items.length == 1 ? items.single : null);
        _items = items;
        if (selected != null) {
          _select(selected, preserveDraft: true);
        } else {
          _item = null;
          _side = null;
          _date = null;
          _edited.clear();
        }
        _loaded = true;
      });
    } catch (_) {
      if (mounted) setState(() => _loadError = '补全信息暂未读取，当前选择已保留');
    } finally {
      if (mounted) {
        setState(() => _fetching = false);
        if (_reloadPending && widget.active) {
          _reloadPending = false;
          scheduleMicrotask(_load);
        } else {
          _trySubmit();
          _scheduleReadRetry();
        }
      }
    }
  }

  void _scheduleReadRetry() {
    // 结果更新优先走业务事件，网络失败或分析尚未落库时只做有限退避读取。
    if (!widget.active ||
        _saving ||
        _retryCount >= 3 ||
        !(_loadError != null ||
            (widget.analysisPending &&
                (_items.isEmpty || _item?.reviewPending == true)))) {
      return;
    }
    _retry = Timer(Duration(seconds: 2 << _retryCount++), _load);
  }

  Future<void> _trySubmit() async {
    final item = _item;
    if (!mounted ||
        !widget.active ||
        _saving ||
        _fetching ||
        _pickingDate ||
        _holdSubmit ||
        item == null ||
        item.reviewPending ||
        item.confirmed ||
        _edited.isEmpty ||
        _side == null ||
        _date == null) {
      return;
    }
    final date =
        item.deadline ??
        DateTime(_date!.year, _date!.month, _date!.day, 23, 59, 59);
    final attempt =
        '${item.id}:${item.version}:$_side:${date.toIso8601String()}';
    if (_lastAttempt == attempt) return;
    _lastAttempt = attempt;
    final side = _side!;
    setState(() {
      _saving = true;
      _saveError = null;
    });
    try {
      final saved = await widget.onConfirm(item, side, date);
      if (!saved.confirmed || saved.side == null || saved.deadline == null) {
        throw StateError('not_persisted');
      }
      if (mounted) {
        setState(() {
          _select(saved);
          _items = [
            for (final old in _items)
              if (old.id == saved.id) saved else old,
          ];
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _holdSubmit = true;
          _saveError = error is ApiFailure && error.status == 409
              ? '记录已更新，核对后重新选择即可保存'
              : '尚未保存，选择已保留，重新选择可重试';
          _reloadPending = true;
        });
      }
    } finally {
      if (mounted) {
        setState(() => _saving = false);
        if (_reloadPending && widget.active) {
          _reloadPending = false;
          _load();
        }
      }
    }
  }

  void _chooseSide(String side) {
    setState(() {
      _side = side;
      _edited.add('side');
      _lastAttempt = null;
      _holdSubmit = false;
      _saveError = null;
    });
    _trySubmit();
  }

  Future<void> _pickDate() async {
    _pickingDate = true;
    final date = await showDatePicker(
      context: context,
      initialDate: _date ?? DateTime.now(),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
      helpText: '选择交期',
      cancelText: '取消',
      confirmText: '确定',
    );
    _pickingDate = false;
    if (!mounted) return;
    if (date != null) {
      setState(() {
        _date = date;
        _edited.add('deadline');
        _lastAttempt = null;
        _holdSubmit = false;
        _saveError = null;
      });
    }
    if (_reloadPending) {
      _reloadPending = false;
      _load();
    } else if (date != null) {
      _trySubmit();
    }
  }

  @override
  Widget build(BuildContext context) {
    final item = _item;
    final secondary = HomeStyle.secondary(context);
    final confirmed = item?.confirmed == true;
    final editable =
        !_saving &&
        !_fetching &&
        item != null &&
        !confirmed &&
        !item.reviewPending;
    final needsSide =
        item?.needsSide == true && !confirmed && item?.reviewPending != true;
    final needsDate =
        item?.needsDeadline == true &&
        !confirmed &&
        item?.reviewPending != true;
    final waiting = !_loaded || widget.analysisPending;
    final error = _saveError ?? _loadError;
    final status = _saving
        ? '保存中…'
        : _loadError != null
        ? '暂未连接'
        : confirmed
        ? '已确认'
        : item?.reviewPending == true
        ? '核对中'
        : item != null && (needsSide || needsDate)
        ? '待补全'
        : _items.isEmpty && waiting
        ? '识别中'
        : '无需补全';
    return Container(
      key: ValueKey('completion-panel-${widget.sourceId}'),
      width: double.infinity,
      margin: const EdgeInsets.only(top: 4, bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: HomeStyle.blue.withValues(alpha: .035),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: HomeStyle.blue.withValues(alpha: .09)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(
                Icons.playlist_add_rounded,
                color: HomeStyle.blue,
                size: 18,
              ),
              const SizedBox(width: 7),
              Text('补全信息', style: HomeStyle.text(13, bold: true)),
              const Spacer(),
              Text(
                status,
                key: ValueKey('completion-status-${widget.sourceId}'),
                style: HomeStyle.text(
                  10,
                  color: confirmed ? HomeStyle.blue : secondary,
                ),
              ),
            ],
          ),
          if (_fetching && !_loaded)
            const Padding(
              padding: EdgeInsets.only(top: 12),
              child: LinearProgressIndicator(minHeight: 2),
            ),
          if (_items.length > 1) ...[
            const SizedBox(height: 12),
            DropdownButton<String>(
              key: ValueKey('completion-item-${widget.sourceId}'),
              value: item?.id,
              isExpanded: true,
              hint: const Text('选择需要补全的履约项'),
              items: [
                for (final value in _items)
                  DropdownMenuItem(
                    value: value.id,
                    child: Text(value.title, overflow: TextOverflow.ellipsis),
                  ),
              ],
              onChanged: _saving
                  ? null
                  : (id) => setState(
                      () => _select(_items.firstWhere((i) => i.id == id)),
                    ),
            ),
          ],
          if (item != null)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(
                item.title,
                style: HomeStyle.text(11, color: secondary),
              ),
            ),
          if (item?.reviewPending == true)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(
                '正在核对原话，待补信息会自动更新',
                style: HomeStyle.text(11, color: secondary),
              ),
            ),
          if (_loaded && _items.isEmpty && _loadError == null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                widget.analysisPending ? '正在识别待补信息，结果就绪后自动显示' : '这段发言暂无待补全信息',
                style: HomeStyle.text(11, color: secondary),
              ),
            ),
          if (needsSide) ...[
            const SizedBox(height: 16),
            Text('履约方', style: HomeStyle.text(11, color: secondary)),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                color: HomeStyle.surface(context),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  for (final side in ['ours', 'theirs'])
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 2),
                        child: TextButton(
                          key: ValueKey(
                            'completion-side-${widget.sourceId}-${side == 'ours' ? '我方履约' : '对方履约'}',
                          ),
                          onPressed: editable ? () => _chooseSide(side) : null,
                          style: TextButton.styleFrom(
                            minimumSize: const Size(0, 44),
                            backgroundColor: _side == side
                                ? HomeStyle.blue.withValues(alpha: .09)
                                : Colors.transparent,
                            foregroundColor: _side == side
                                ? HomeStyle.blue
                                : secondary,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8),
                            ),
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              if (_side == side) ...[
                                const Icon(Icons.check_rounded, size: 15),
                                const SizedBox(width: 4),
                              ],
                              Flexible(
                                child: Text(
                                  side == 'ours' ? '我方履约' : '对方履约',
                                  style: HomeStyle.text(
                                    12,
                                    bold: _side == side,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
          if (needsDate) ...[
            const SizedBox(height: 14),
            Text('交期', style: HomeStyle.text(11, color: secondary)),
            const SizedBox(height: 8),
            OutlinedButton(
              key: ValueKey('completion-date-${widget.sourceId}'),
              onPressed: editable ? _pickDate : null,
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
                backgroundColor: HomeStyle.surface(context),
                side: BorderSide(color: HomeStyle.blue.withValues(alpha: .1)),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 12),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.calendar_today_outlined,
                    size: 17,
                    color: HomeStyle.blue,
                  ),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Text(
                      _date == null
                          ? '选择日期'
                          : '${_date!.year}年${_date!.month}月${_date!.day}日',
                      style: HomeStyle.text(
                        12,
                        color: _date == null
                            ? secondary
                            : HomeStyle.foreground(context),
                      ),
                    ),
                  ),
                  Icon(Icons.chevron_right_rounded, size: 18, color: secondary),
                ],
              ),
            ),
          ],
          if (item != null && !needsSide && !needsDate && !item.reviewPending)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(
                confirmed
                    ? '${item.side == 'ours' ? '我方履约' : '对方履约'} · ${item.deadline!.year}/${item.deadline!.month}/${item.deadline!.day}'
                    : '相关信息已齐全，无需重复填写',
                style: HomeStyle.text(11, color: secondary),
              ),
            ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(
                error,
                style: HomeStyle.text(
                  11,
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
