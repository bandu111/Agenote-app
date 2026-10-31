import 'dart:async';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'meeting_models.dart';
import 'meeting_questions.dart';
import '../home/views/home_style.dart';
import 'minutes/meeting_evidence_link.dart';
import 'minutes/meeting_minutes_data.dart';

String _questionTitle(Map<String, dynamic> q) {
  final c = q['content'];
  return (c['text'] as String).isNotEmpty
      ? c['text']
      : '${meetingTime(Duration(milliseconds: c['atMs']))} 的疑问 · 尚未填写';
}

Future<void> showMeetingQuestion(
  BuildContext context,
  MeetingQuestions questions,
  MeetingRecord record,
  String id, {
  void Function(String)? onSource,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  builder: (sheetContext) => _QuestionEditor(
    questions: questions,
    record: record,
    id: id,
    onSource: onSource == null
        ? null
        : (source) {
            Navigator.pop(sheetContext);
            onSource(source);
          },
  ),
);

/// Compact entry also exposes marks which have no transcript yet.
class MeetingQuestionList extends StatefulWidget {
  const MeetingQuestionList({
    super.key,
    required this.questions,
    required this.record,
    this.sourceIds,
    this.compact = false,
    this.minutesStyle = false,
    this.toolbar = false,
    this.liveSheet = false,
    this.transcriptBadge = false,
    this.badgeLabel = '疑问',
    this.onSource,
  });
  final MeetingQuestions questions;
  final MeetingRecord record;
  final List<String>? sourceIds;
  final bool compact;
  final bool minutesStyle;
  final bool toolbar;
  final bool liveSheet;
  final bool transcriptBadge;
  final String badgeLabel;
  final void Function(String)? onSource;
  @override
  State<MeetingQuestionList> createState() => _MeetingQuestionListState();
}

class _MeetingQuestionListState extends State<MeetingQuestionList> {
  String? get _visibleError {
    final error = widget.questions.error;
    // 后台同步与补分析状态不作为页面小字展示，实际读写失败仍保留。
    if (const {
      '疑问已保存在本机，同步待重试',
      '疑问已保存在本机，联网后重试；若云端有更新，请先处理冲突',
      '纪要已归档，疑问分析稍后重试',
    }.contains(error)) {
      return null;
    }
    return error;
  }

  final _liveDraft = TextEditingController();
  String? _editingLiveId, _liveSaveError;
  bool _savingLive = false;

  @override
  void dispose() {
    _liveDraft.dispose();
    super.dispose();
  }

  Future<void> _saveLiveQuestion(String id) async {
    setState(() {
      _savingLive = true;
      _liveSaveError = null;
    });
    try {
      await widget.questions.edit(widget.record, id, text: _liveDraft.text);
      if (mounted) setState(() => _editingLiveId = null);
    } catch (_) {
      if (mounted) setState(() => _liveSaveError = '保存失败，请重试');
    } finally {
      if (mounted) setState(() => _savingLive = false);
    }
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant MeetingQuestionList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.record.id != widget.record.id ||
        oldWidget.record.ownerId != widget.record.ownerId) {
      _load();
    }
  }

  Future<void> _showQuestionSheet(BuildContext context) =>
      showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        backgroundColor: HomeStyle.surface(context),
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
        builder: (_) => ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * .76,
          ),
          child: SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(
              20,
              10,
              20,
              20 +
                  MediaQuery.paddingOf(context).bottom +
                  MediaQuery.viewInsetsOf(context).bottom,
            ),
            child: MeetingQuestionList(
              questions: widget.questions,
              record: widget.record,
              liveSheet: true,
              sourceIds: widget.sourceIds,
            ),
          ),
        ),
      );

  void _load() {
    unawaited(widget.questions.load(widget.record).catchError((Object _) {}));
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.questions,
    builder: (_, _) {
      final all = widget.questions.items(widget.record);
      final entries = all
          .where(
            (q) =>
                widget.sourceIds == null ||
                (q['content']['sourceIds'] as List).any(
                  widget.sourceIds!.contains,
                ),
          )
          .toList();
      if (widget.minutesStyle) {
        entries.sort((a, b) {
          final aResolved = a['content']['status'] == 'resolved' ? 1 : 0;
          final bResolved = b['content']['status'] == 'resolved' ? 1 : 0;
          final status = aResolved.compareTo(bResolved);
          if (status != 0) return status;
          final time = (a['content']['atMs'] as int).compareTo(
            b['content']['atMs'] as int,
          );
          return time != 0
              ? time
              : (a['id'] as String).compareTo(b['id'] as String);
        });
      }
      if (widget.toolbar) {
        return IconButton(
          key: const ValueKey('meeting-my-questions'),
          tooltip: '我的疑问',
          icon: Badge(
            isLabelVisible: entries.isNotEmpty,
            label: Text(entries.length > 99 ? '99+' : '${entries.length}'),
            child: const Icon(Icons.help_outline_rounded),
          ),
          onPressed: () => _showQuestionSheet(context),
        );
      }
      if (widget.liveSheet) {
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 34,
                height: 3,
                margin: const EdgeInsets.only(bottom: 18),
                decoration: BoxDecoration(
                  color: HomeStyle.secondary(context).withValues(alpha: .25),
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ),
            Row(
              children: [
                Expanded(
                  child: Text(
                    '我的疑问',
                    style: HomeStyle.text(
                      17,
                      bold: true,
                      color: HomeStyle.foreground(context),
                    ),
                  ),
                ),
                Text(
                  '${widget.sourceIds == null ? '本场' : '本段'} ${entries.length} 处',
                  style: HomeStyle.text(
                    11,
                    color: HomeStyle.secondary(context),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            if (entries.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 32),
                child: Center(
                  child: Text(
                    '本场还没有标记',
                    style: HomeStyle.text(
                      13,
                      color: HomeStyle.secondary(context),
                    ),
                  ),
                ),
              ),
            for (final q in entries) _liveEntry(context, q),
            if (_visibleError != null) Text(_visibleError!),
          ],
        );
      }
      if (entries.isEmpty) return const SizedBox.shrink();
      if (widget.transcriptBadge) {
        return Tooltip(
          message: '查看本段疑问',
          child: Material(
            color: HomeStyle.blue,
            borderRadius: BorderRadius.circular(4),
            child: InkWell(
              borderRadius: BorderRadius.circular(4),
              onTap: () => _showQuestionSheet(context),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                child: Text(
                  entries.length > 1
                      ? '${widget.badgeLabel} · ${entries.length}'
                      : widget.badgeLabel,
                  style: HomeStyle.text(11, bold: true, color: Colors.white),
                ),
              ),
            ),
          ),
        );
      }

      if (widget.compact) {
        return TextButton.icon(
          icon: const Icon(Icons.help_outline, size: 16),
          label: Text(
            widget.sourceIds == null
                ? '疑问标记 · ${entries.length}'
                : '已标记疑问${entries.length > 1 ? ' · ${entries.length}' : ''}',
          ),
          onPressed: () => showModalBottomSheet<void>(
            context: context,
            useSafeArea: true,
            isScrollControlled: true,
            builder: (sheetContext) => SingleChildScrollView(
              child: MeetingQuestionList(
                questions: widget.questions,
                record: widget.record,
                sourceIds: widget.sourceIds,
                onSource: widget.onSource == null
                    ? null
                    : (id) {
                        Navigator.pop(sheetContext);
                        widget.onSource!(id);
                      },
              ),
            ),
          ),
        );
      }
      return Padding(
        padding: EdgeInsets.symmetric(vertical: widget.minutesStyle ? 0 : 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.minutesStyle)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Divider(
                  height: 1,
                  color: HomeStyle.tintColor(context, const Color(0xFFEAF0FD)),
                ),
              ),
            if (widget.sourceIds == null)
              Padding(
                padding: widget.minutesStyle
                    ? const EdgeInsets.only(bottom: 18)
                    : const EdgeInsets.all(12),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '我的疑问',
                        style: widget.minutesStyle
                            ? _minutesText(context, 18, bold: true)
                            : Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    if (widget.minutesStyle)
                      Text(
                        '${entries.length} 个疑问',
                        style: _minutesText(context, 11, muted: true),
                      ),
                  ],
                ),
              ),
            for (final q in entries) _entry(context, q),
            if (_visibleError != null)
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text(_visibleError!),
              ),
          ],
        ),
      );
    },
  );

  Widget _liveEntry(BuildContext context, Map<String, dynamic> q) {
    final content = q['content'];
    final sources = widget.questions
        .latest(widget.record)
        .utterances
        .where(
          (u) => !u.withdrawn && (content['sourceIds'] as List).contains(u.id),
        )
        .toList();
    final secondary = HomeStyle.secondary(context);
    Widget row(String label, String value) => Padding(
      padding: const EdgeInsets.only(bottom: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 66,
            child: Text(label, style: HomeStyle.text(11, color: secondary)),
          ),
          Expanded(
            child: Text(
              value,
              style: HomeStyle.text(12, color: HomeStyle.foreground(context)),
            ),
          ),
        ],
      ),
    );
    return Container(
      key: ValueKey('meeting-question-${q['id']}'),
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: HomeStyle.tint(context),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: HomeStyle.blue.withValues(alpha: .22)),
      ),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: Material(
          type: MaterialType.transparency,
          child: ExpansionTile(
            initiallyExpanded: false,
            dense: true,
            minTileHeight: 56,
            visualDensity: VisualDensity.compact,
            tilePadding: const EdgeInsets.symmetric(horizontal: 12),
            childrenPadding: const EdgeInsets.fromLTRB(42, 0, 12, 8),
            leading: Container(
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                color: HomeStyle.blue.withValues(alpha: .07),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.help_outline_rounded,
                size: 13,
                color: HomeStyle.blue,
              ),
            ),
            title: Text(
              _questionTitle(q),
              style: HomeStyle.text(13, color: HomeStyle.foreground(context)),
            ),
            subtitle: Text(
              content['status'] == 'resolved' ? '已解决' : '待处理',
              style: HomeStyle.text(10, color: secondary),
            ),
            children: [
              row('标记时间', meetingTime(Duration(milliseconds: content['atMs']))),
              row(
                '关联发言',
                sources.isEmpty
                    ? '尚未关联原文'
                    : sources
                          .map((u) => '${u.speaker} · ${meetingTime(u.at)}')
                          .join('、'),
              ),
              for (final u in sources)
                Container(
                  width: double.infinity,
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.fromLTRB(10, 6, 8, 6),
                  decoration: BoxDecoration(
                    color: HomeStyle.surface(context),
                    border: const Border(
                      left: BorderSide(color: Color(0xFF9CBDFF), width: 2),
                    ),
                  ),
                  child: Text(
                    '「${u.raw}」',
                    style: HomeStyle.text(
                      12,
                      color: secondary,
                    ).copyWith(height: 1.6),
                  ),
                ),
              _inlineEditor(context, q),
            ],
          ),
        ),
      ),
    );
  }

  Widget _inlineEditor(BuildContext context, Map<String, dynamic> q) {
    final secondary = HomeStyle.secondary(context);
    final editorButtonStyle = TextButton.styleFrom(
      fixedSize: const Size(60, 32),
      minimumSize: Size.zero,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      shape: const StadiumBorder(),
      textStyle: HomeStyle.text(11),
      tapTargetSize: MaterialTapTargetSize.padded,
      visualDensity: VisualDensity.standard,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_editingLiveId == q['id']) ...[
          TextField(
            key: ValueKey('live-question-draft-${q['id']}'),
            controller: _liveDraft,
            autofocus: true,
            enabled: !_savingLive,
            minLines: 2,
            maxLines: 3,
            maxLength: 120,
            style: HomeStyle.text(12, color: HomeStyle.foreground(context)),
            decoration: InputDecoration(
              hintText: '想追一句什么？留空也可以',
              hintStyle: HomeStyle.text(12, color: secondary),
              filled: true,
              fillColor: HomeStyle.surface(context),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 10,
                vertical: 10,
              ),
              counterText: '',
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide(
                  color: HomeStyle.blue.withValues(alpha: .3),
                ),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide(
                  color: HomeStyle.blue.withValues(alpha: .3),
                ),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: HomeStyle.blue),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: ValueListenableBuilder<TextEditingValue>(
                  valueListenable: _liveDraft,
                  builder: (_, value, _) => Text(
                    '${value.text.characters.length} / 120',
                    style: HomeStyle.text(10, color: secondary),
                  ),
                ),
              ),
              TextButton(
                onPressed: _savingLive
                    ? null
                    : () => setState(() {
                        _editingLiveId = null;
                        _liveSaveError = null;
                      }),
                style: editorButtonStyle.copyWith(
                  side: WidgetStatePropertyAll(
                    BorderSide(color: secondary.withValues(alpha: .2)),
                  ),
                  foregroundColor: WidgetStatePropertyAll(secondary),
                ),
                child: const Text('取消'),
              ),
              const SizedBox(width: 6),
              TextButton(
                onPressed: _savingLive
                    ? null
                    : () => _saveLiveQuestion(q['id']),
                style: editorButtonStyle.copyWith(
                  backgroundColor: WidgetStateProperty.resolveWith(
                    (states) => states.contains(WidgetState.disabled)
                        ? HomeStyle.blue.withValues(alpha: .45)
                        : HomeStyle.blue,
                  ),
                  foregroundColor: const WidgetStatePropertyAll(Colors.white),
                  side: const WidgetStatePropertyAll(
                    BorderSide(color: Colors.transparent),
                  ),
                ),
                child: Text(_savingLive ? '保存中' : '保存'),
              ),
            ],
          ),
          if (_liveSaveError != null)
            Text(_liveSaveError!, style: const TextStyle(color: Colors.red)),
        ] else
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => setState(() {
                _liveDraft.text = q['content']['text'] as String? ?? '';
                _editingLiveId = q['id'];
                _liveSaveError = null;
              }),
              icon: const Icon(Icons.edit_outlined, size: 14),
              label: const Text('编辑疑问'),
            ),
          ),
      ],
    );
  }

  TextStyle _minutesText(
    BuildContext context,
    double size, {
    bool bold = false,
    bool muted = false,
  }) => HomeStyle.text(
    size,
    bold: bold,
    color: muted
        ? (Theme.of(context).brightness == Brightness.dark
              ? HomeStyle.secondary(context)
              : HomeStyle.muted)
        : (Theme.of(context).brightness == Brightness.dark
              ? HomeStyle.foreground(context)
              : HomeStyle.ink),
  );

  Widget _entry(BuildContext context, Map<String, dynamic> q) {
    final sources = widget.questions
        .latest(widget.record)
        .utterances
        .where(
          (u) =>
              !u.withdrawn &&
              (q['content']['sourceIds'] as List).contains(u.id),
        )
        .toList();
    final primary = sources.firstOrNull;
    final answerIds = <String>{
      for (final answer in q['analysis']?['answers'] as List? ?? [])
        for (final evidence in answer['evidence'] as List? ?? [])
          evidence['id'] as String,
    };
    final details = _QuestionDetails(
      questions: widget.questions,
      record: widget.record,
      question: q,
      onSource: widget.onSource,
      minutesStyle: widget.minutesStyle,
    );
    final tile = ExpansionTile(
      expandedCrossAxisAlignment: widget.minutesStyle
          ? CrossAxisAlignment.stretch
          : null,
      tilePadding: widget.minutesStyle
          ? const EdgeInsets.symmetric(horizontal: 12)
          : null,
      leading: Icon(
        q['content']['status'] == 'resolved'
            ? Icons.check_circle_outline
            : Icons.help_outline,
        size: widget.minutesStyle ? 15 : null,
        color: widget.minutesStyle ? const Color(0xFF86A0CD) : null,
      ),
      title: Text(
        _questionTitle(q),
        maxLines: widget.minutesStyle ? 3 : null,
        overflow: widget.minutesStyle ? TextOverflow.ellipsis : null,
        style: widget.minutesStyle
            ? _minutesText(context, 14, bold: true).copyWith(height: 1.5)
            : null,
      ),
      subtitle: Text(
        q['content']['status'] == 'resolved' ? '已解决' : switch (q['analysis']?['state']) {
          'awaiting_confirmation' => '待确认疑问',
          'answered' => '有参考答案',
          'needs_input' => '待补充',
          _ => '待处理',
        },
        style: widget.minutesStyle
            ? _minutesText(context, 11, muted: true)
            : null,
      ),
      childrenPadding: EdgeInsets.fromLTRB(
        16,
        0,
        16,
        widget.minutesStyle ? 8 : 12,
      ),
      children: [
        if (widget.minutesStyle)
          DefaultTextStyle.merge(
            style: _minutesText(
              context,
              13,
              muted: true,
            ).copyWith(height: 1.65),
            child: details,
          )
        else
          details,
        if (widget.minutesStyle) ...[
          if ((q['content']['text'] as String? ?? '').isEmpty)
            for (final candidate in q['analysis']?['candidates'] as List? ?? [])
              Align(alignment: Alignment.centerLeft, child: TextButton(
                onPressed: () async {
                  try {
                    await widget.questions.edit(widget.record, q['id'], text: '$candidate');
                  } catch (_) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('确认尚未保存，请重试')));
                    }
                  }
                }, child: Text('确认疑问：$candidate'))),
          Align(alignment: Alignment.centerLeft, child: TextButton(
            onPressed: () async {
              try {
                await widget.questions.edit(widget.record, q['id'], status:
                  q['content']['status'] == 'resolved' ? 'pending' : 'resolved');
              } catch (_) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('状态尚未保存，请重试')));
                }
              }
            }, child: Text(q['content']['status'] == 'resolved' ? '重新打开疑问' : '标记已解决'))),
        ],
        if (widget.minutesStyle)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: _inlineEditor(context, q),
          )
        else
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: () => showMeetingQuestion(
                context,
                widget.questions,
                widget.record,
                q['id'],
                onSource: widget.onSource,
              ),
              child: const Text('编辑疑问'),
            ),
          ),
        if (widget.minutesStyle) ...[
          if (primary != null)
            MeetingEvidenceLink(
              at: Duration(milliseconds: q['content']['atMs']),
              label: '查看原始依据',
              onPressed: widget.onSource == null
                  ? null
                  : () => widget.onSource!(primary.id),
            )
          else
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                '${meetingTime(Duration(milliseconds: q['content']['atMs']))}  ·  尚未关联原文',
                style: _minutesText(context, 12, muted: true),
              ),
            ),
          for (final source
              in widget.questions
                  .latest(widget.record)
                  .utterances
                  .where(
                    (u) =>
                        !u.withdrawn &&
                        u.id != primary?.id &&
                        (answerIds.contains(u.id) ||
                            sources.any((s) => s.id == u.id)),
                  ))
            MeetingEvidenceLink(
              at: minutesUtteranceStart(source),
              label: '查看原始依据',
              onPressed: widget.onSource == null
                  ? null
                  : () => widget.onSource!(source.id),
            ),
        ],
      ],
    );
    final key = ValueKey('meeting-question-${q['id']}');
    if (!widget.minutesStyle) return Card(key: key, child: tile);
    return Padding(
      key: key,
      padding: const EdgeInsets.only(bottom: 10),
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border.all(
            color: HomeStyle.tintColor(context, const Color(0xFFEAF0FD)),
          ),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: Material(
            type: MaterialType.transparency,
            child: ListTileTheme(
              data: const ListTileThemeData(
                horizontalTitleGap: 10,
                minLeadingWidth: 20,
              ),
              child: tile,
            ),
          ),
        ),
      ),
    );
  }
}

class _QuestionDetails extends StatelessWidget {
  const _QuestionDetails({
    required this.questions,
    required this.record,
    required this.question,
    this.onSource,
    this.minutesStyle = false,
  });
  final MeetingQuestions questions;
  final MeetingRecord record;
  final Map<String, dynamic> question;
  final void Function(String)? onSource;
  final bool minutesStyle;

  Widget _organizedMinutes(
    BuildContext context,
    Map content,
    Map? analysis,
    Iterable<MeetingUtterance> sources,
  ) {
    final muted = HomeStyle.secondary(context);
    Widget section(String label, List<Widget> children) => Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: HomeStyle.text(11, color: muted)),
          const SizedBox(height: 8),
          ...children,
        ],
      ),
    );
    Widget block(Widget child) => Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: HomeStyle.tint(context),
        borderRadius: BorderRadius.circular(10),
        border: const Border(
          left: BorderSide(color: Color(0xFF9CBDFF), width: 2),
        ),
      ),
      child: child,
    );
    final answers = analysis?['answers'] as List? ?? [];
    final candidates = (content['text'] as String).isEmpty
        ? ((analysis?['candidates'] as List?) ?? [])
        : const [];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (sources.isNotEmpty)
          section('关联原话', [
            for (final u in sources)
              block(
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(u.speaker, style: HomeStyle.text(11, color: muted)),
                    const SizedBox(height: 4),
                    Text(u.raw),
                  ],
                ),
              ),
          ]),
        if (content['association'] == 'nearby')
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text('已关联附近发言，请核对', style: HomeStyle.text(11, color: muted)),
          ),
        if (analysis?['stale'] == true)
          section('分析状态', [const Text('问题或原文已更新，以下 AI 结果待重新分析')]),
        if ((analysis?['message'] as String? ?? '').isNotEmpty)
          section('分析状态', [Text(analysis!['message'] as String)]),
        if (candidates.isNotEmpty)
          section('AI 候选问题 · 未经用户确认', [
            for (final candidate in candidates) block(Text('$candidate')),
          ]),
        if (answers.isNotEmpty)
          section('AI 参考', [
            for (final answer in answers)
              block(
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(switch (answer['coverage']) {
                      'explicit' => '会议中有明确回答',
                      'partial' => '会议中有部分回答',
                      'external' => '相关资料参考',
                      _ => '无法确认',
                    }, style: HomeStyle.text(11, color: muted)),
                    const SizedBox(height: 6),
                    if ((content['text'] as String).isEmpty &&
                        answer['question'] != null) ...[
                      Text('候选问题（未确认）：${answer['question']}'),
                      const SizedBox(height: 6),
                    ],
                    Text('${answer['text']}'),
                    if ((answer['evidence'] as List? ?? []).isNotEmpty) ...[
                      const SizedBox(height: 10),
                      Text('回答依据', style: HomeStyle.text(11, color: muted)),
                      for (final evidence in answer['evidence'] as List)
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: evidence['path'] is String &&
                              (evidence['path'] as String).startsWith('/knowledge/documents/')
                            ? TextButton(
                                onPressed: () => context.push(evidence['path'] as String),
                                child: Text('${evidence['title'] ?? '相关资料'}：${evidence['raw']}'))
                            : Text('${evidence['raw']}'),
                        ),
                    ],
                  ],
                ),
              ),
          ]),
      ],
    );
  }

  Widget _label(BuildContext context, String text) => !minutesStyle
      ? Text(text)
      : Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
            decoration: BoxDecoration(
              color: HomeStyle.tintColor(context, const Color(0xFFFFF6E7)),
              borderRadius: BorderRadius.circular(5),
            ),
            child: Text(
              text,
              style: HomeStyle.text(10, color: const Color(0xFFAE7417)),
            ),
          ),
        );
  @override
  Widget build(BuildContext context) {
    final c = question['content'];
    final analysis = question['analysis'] as Map?;
    final ids = List<String>.from(c['sourceIds']);
    final sources = questions
        .latest(record)
        .utterances
        .where((u) => ids.contains(u.id));
    if (minutesStyle) return _organizedMinutes(context, c, analysis, sources);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (!minutesStyle)
          Text('标记时间 ${meetingTime(Duration(milliseconds: c['atMs']))}'),
        if (ids.isEmpty && !minutesStyle) const Text('尚未关联转写，时间标记已保留'),
        if (c['association'] == 'nearby') const Text('已关联附近发言，请核对'),
        for (final u in sources) ...[
          const SizedBox(height: 8),
          Text('${u.speaker}：${u.raw}'),
          if (!minutesStyle && onSource != null)
            TextButton(
              onPressed: () => onSource!(u.id),
              child: const Text('查看原始发言'),
            ),
        ],
        if (analysis?['stale'] == true) const Text('问题或原文已更新，以下 AI 结果待重新分析'),
        if (analysis != null &&
            (analysis['message'] as String? ?? '').isNotEmpty)
          Text(analysis['message'] as String),
        if ((c['text'] as String).isEmpty && analysis != null)
          for (final value in analysis['candidates'] as List? ?? [])
            if (minutesStyle)
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [_label(context, 'AI 候选问题 · 未经用户确认'), Text('$value')],
              )
            else
              Text('AI 候选问题（未确认）：$value'),
        for (final answer in analysis?['answers'] as List? ?? []) ...[
          const Divider(),
          if ((c['text'] as String).isEmpty)
            Text('候选问题（未确认）：${answer['question']}'),
          _label(
            context,
            'AI 参考 · ${switch (answer['coverage']) {
              'explicit' => '会议中有明确回答',
              'partial' => '会议中有部分回答',
              _ => '无法确认',
            }}',
          ),
          Text('${answer['text']}'),
          for (final evidence in answer['evidence'] as List? ?? [])
            if (minutesStyle)
              Padding(
                padding: const EdgeInsets.only(top: 7),
                child: Text('${evidence['raw']}'),
              )
            else
              TextButton(
                onPressed: onSource == null
                    ? null
                    : () => onSource!(evidence['id']),
                child: Text(
                  '${meetingTime(Duration(milliseconds: evidence['atMs']))} · ${evidence['raw']}',
                ),
              ),
        ],
      ],
    );
  }
}

class _QuestionEditor extends StatefulWidget {
  const _QuestionEditor({
    required this.questions,
    required this.record,
    required this.id,
    this.onSource,
  });
  final MeetingQuestions questions;
  final MeetingRecord record;
  final String id;
  final void Function(String)? onSource;
  @override
  State<_QuestionEditor> createState() => _QuestionEditorState();
}

class _QuestionEditorState extends State<_QuestionEditor> {
  late final _text = TextEditingController(
    text:
        widget.questions.item(widget.record, widget.id)?['content']['text'] ??
        '',
  );
  bool _busy = false;
  String? _error;
  Future<void> _run(
    Future<void> Function() action, {
    bool close = false,
  }) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
      if (mounted && close) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        setState(
          () => _error = e is StateError
              ? e.message.toString()
              : '操作暂未完成，请重试；已输入内容保留',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() =>
      widget.questions.edit(widget.record, widget.id, text: _text.text);
  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.questions,
    builder: (_, _) {
      final q = widget.questions.item(widget.record, widget.id);
      if (q == null) {
        return const Padding(
          padding: EdgeInsets.all(24),
          child: Text('疑问已删除或账户已切换'),
        );
      }
      final resolved = q['content']['status'] == 'resolved';
      return Padding(
        padding: EdgeInsets.fromLTRB(
          20,
          20,
          20,
          MediaQuery.viewInsetsOf(context).bottom + 20,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(child: Text('我的疑问 · ${resolved ? '已解决' : '待处理'}')),
                  PopupMenuButton<String>(
                    enabled: !_busy,
                    onSelected: (_) async {
                      final confirmed = await showDialog<bool>(
                        context: context,
                        builder: (ctx) => AlertDialog(
                          title: const Text('删除这条疑问？'),
                          content: const Text('删除后不再展示或分析这条标记。'),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(ctx, false),
                              child: const Text('取消'),
                            ),
                            TextButton(
                              onPressed: () => Navigator.pop(ctx, true),
                              child: const Text('删除'),
                            ),
                          ],
                        ),
                      );
                      if (confirmed == true && mounted) {
                        await _run(
                          () => widget.questions.edit(
                            widget.record,
                            widget.id,
                            deleted: true,
                          ),
                          close: true,
                        );
                      }
                    },
                    itemBuilder: (_) => [
                      const PopupMenuItem(value: 'delete', child: Text('删除疑问')),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _text,
                minLines: 2,
                maxLines: 5,
                maxLength: 2000,
                decoration: const InputDecoration(
                  labelText: '我的问题',
                  hintText: '可以稍后填写，也可以编辑 AI 候选问题',
                  border: OutlineInputBorder(),
                ),
              ),
              if (!resolved)
                TextButton.icon(
                  onPressed: _busy
                      ? null
                      : () => _run(() async {
                          // Suggestions never replace a draft or confirm it on the user's behalf.
                          await widget.questions.analyze(
                            widget.record,
                            id: widget.id,
                            suggest: true,
                          );
                        }),
                  icon: const Icon(Icons.auto_awesome_outlined),
                  label: const Text('帮我推测问题'),
                ),
              if (!resolved)
                for (final candidate
                    in q['analysis']?['candidates'] as List? ?? [])
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: ActionChip(
                      label: Text('$candidate', softWrap: true),
                      onPressed: _busy ? null : () => _text.text = '$candidate',
                    ),
                  ),
              const Text('AI 候选仅供参考，保存后才作为你的问题。'),
              const SizedBox(height: 12),
              _QuestionDetails(
                questions: widget.questions,
                record: widget.record,
                question: q,
                onSource: widget.onSource,
              ),
              if (q['conflict'] != null) ...[
                const Text('另一台设备已修改此疑问，请选择保留哪一份：'),
                Text('云端问题：${q['conflict']['content']['text']}'),
                Wrap(
                  children: [
                    TextButton(
                      onPressed: _busy
                          ? null
                          : () => _run(
                              () => widget.questions.resolveConflict(
                                widget.record,
                                widget.id,
                                keepLocal: true,
                              ),
                            ),
                      child: const Text('保留本机修改'),
                    ),
                    TextButton(
                      onPressed: _busy
                          ? null
                          : () => _run(() async {
                              await widget.questions.resolveConflict(
                                widget.record,
                                widget.id,
                                keepLocal: false,
                              );
                              _text.text =
                                  widget.questions.item(
                                    widget.record,
                                    widget.id,
                                  )?['content']['text'] ??
                                  '';
                            }),
                      child: const Text('采用云端修改'),
                    ),
                  ],
                ),
              ],
              if (_error != null)
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              if (_busy) const LinearProgressIndicator(),
              Wrap(
                spacing: 8,
                children: [
                  FilledButton(
                    onPressed: _busy ? null : () => _run(_save, close: true),
                    child: const Text('保存'),
                  ),
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () => _run(
                            () => widget.questions.edit(
                              widget.record,
                              widget.id,
                              text: _text.text,
                              status: resolved ? 'pending' : 'resolved',
                            ),
                            close: true,
                          ),
                    child: Text(resolved ? '重新待处理' : '标记已解决'),
                  ),
                  if (widget.record.ended &&
                      widget.record.canGenerateMinutes &&
                      !resolved)
                    TextButton(
                      onPressed: _busy
                          ? null
                          : () => _run(() async {
                              await _save();
                              await widget.questions.analyze(
                                widget.record,
                                id: widget.id,
                              );
                            }),
                      child: const Text('寻找相关内容'),
                    ),
                ],
              ),
            ],
          ),
        ),
      );
    },
  );
}
