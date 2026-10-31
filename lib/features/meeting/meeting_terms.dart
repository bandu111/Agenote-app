import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import '../home/views/home_style.dart';
import 'package:provider/provider.dart';
import 'meeting_view_model.dart';
import 'meeting_remote.dart';
import 'transcript_highlight_models.dart';

class MeetingTermMatch {
  const MeetingTermMatch(this.start, this.end, this.term, this.definition);
  final int start, end;
  final String term, definition;
}

/// 偏移始终基于原文 UTF-16；有歧义的概念暂不自动选择。
List<MeetingTermMatch> matchMeetingTerms(String text, List<dynamic> items) {
  final hits = <MeetingTermMatch>[];
  for (final item in items) {
    if (item['enabled'] != true || item['match_policy'] != 'direct') continue;
    for (final surface in <String>{
      item['term'] as String,
      ...List<String>.from(item['aliases'] ?? []),
    }) {
      if (surface.isEmpty) continue;
      for (final hit in RegExp(
        RegExp.escape(surface),
        caseSensitive: false,
      ).allMatches(text)) {
        final ascii = RegExp(r'[a-zA-Z0-9_]');
        if ((ascii.hasMatch(surface[0]) &&
                hit.start > 0 &&
                ascii.hasMatch(text[hit.start - 1])) ||
            (ascii.hasMatch(surface[surface.length - 1]) &&
                hit.end < text.length &&
                ascii.hasMatch(text[hit.end]))) {
          continue;
        }
        hits.add(
          MeetingTermMatch(
            hit.start,
            hit.end,
            item['term'],
            item['definition'],
          ),
        );
      }
    }
  }
  hits.sort(
    (a, b) => a.start != b.start
        ? a.start.compareTo(b.start)
        : b.end.compareTo(a.end),
  );
  final result = <MeetingTermMatch>[];
  for (final hit in hits) {
    if (result.isNotEmpty && hit.start < result.last.end) continue;
    if (hits.any(
      (other) =>
          other.start == hit.start &&
          other.end == hit.end &&
          other.term != hit.term,
    )) {
      continue;
    }
    result.add(hit);
  }
  return result;
}

/// 术语解释只注释文本，不把词典释义写入原始证据。
class MeetingTermText extends StatefulWidget {
  const MeetingTermText({
    super.key,
    required this.text,
    required this.style,
    this.classify = true,
    this.onTermTap,
    this.highlights = const [],
    this.onHighlightTap,
  });
  final bool classify;
  final String text;
  final TextStyle style;
  final ValueChanged<MeetingTermMatch>? onTermTap;
  final List<TranscriptHighlight> highlights;
  final ValueChanged<TranscriptHighlight>? onHighlightTap;
  static final Future<List<dynamic>> dictionary = rootBundle
      .loadString('assets/knowledge/meeting_glossary.json')
      .then(
        (value) =>
            (jsonDecode(value) as Map<String, dynamic>)['items']
                as List<dynamic>,
      );
  @override
  State<MeetingTermText> createState() => _MeetingTermTextState();
}

class _MeetingTermTextState extends State<MeetingTermText> {
  String? _classified;
  bool _important = false;
  List<dynamic> _aiTerms = [];
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _classify();
  }

  @override
  void didUpdateWidget(MeetingTermText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) _classify();
  }

  void _classify() {
    final text = widget.text;
    if (!widget.classify || _classified == text) return;
    _classified = text;
    _important = false;
    _aiTerms = [];
    final remote = context.read<MeetingViewModel>().remote;
    if (text.length < 4 || remote is! DioMeetingRepository) return;
    remote
        .segmentImportant(text)
        .then((value) {
          if (mounted && _classified == text) {
            setState(() {
              _important = value['important'] == true;
              _aiTerms = [
                for (final term in (value['terms'] as List? ?? []))
                  if (term is Map &&
                      term['surface'] is String &&
                      text.contains(term['surface'] as String) &&
                      term['definition'] is String)
                    {
                      'term': term['surface'],
                      'definition': 'AI 解释 · 待核对：${term['definition']}',
                      'enabled': true,
                      'match_policy': 'direct',
                    },
              ];
            });
          }
        })
        .catchError((Object _) {});
  }

  final _recognizers = <TapGestureRecognizer>[];
  void _clear() {
    for (final recognizer in _recognizers) {
      recognizer.dispose();
    }
    _recognizers.clear();
  }

  @override
  void dispose() {
    _clear();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<List<dynamic>>(
    future: MeetingTermText.dictionary,
    builder: (context, snapshot) {
      _clear();
      final spans = <InlineSpan>[];
      var offset = 0;
      final known = matchMeetingTerms(widget.text, snapshot.data ?? []);
      final unknown = matchMeetingTerms(widget.text, _aiTerms).where(
        (hit) => !known.any((k) => hit.start < k.end && hit.end > k.start),
      );
      final matches = [...known, ...unknown]
        ..sort((a, b) => a.start.compareTo(b.start));
      final highlights = widget.highlights
          .where(
            (h) =>
                h.start >= 0 &&
                h.end <= widget.text.length &&
                h.end > h.start &&
                widget.text.substring(h.start, h.end) == h.quote,
          )
          .toList();
      final edges = <int>{
        0,
        widget.text.length,
        for (final term in matches) ...[term.start, term.end],
        for (final h in highlights) ...[h.start, h.end],
      }.toList()..sort();
      // 按区间拆分样式；术语点击优先，重叠的重点仍可从“重点”标签查看。
      for (var i = 0; i + 1 < edges.length; i++) {
        final start = edges[i], end = edges[i + 1];
        final term = matches
            .where((t) => t.start <= start && t.end >= end)
            .firstOrNull;
        final highlight = highlights
            .where((h) => h.start <= start && h.end >= end)
            .firstOrNull;
        TapGestureRecognizer? recognizer;
        if (term != null || highlight != null) {
          recognizer = TapGestureRecognizer()
            ..onTap = () {
              if (term != null) {
                widget.onTermTap?.call(term);
              } else if (highlight != null) {
                widget.onHighlightTap?.call(highlight);
              }
            };
          _recognizers.add(recognizer);
        }
        spans.add(
          TextSpan(
            text: widget.text.substring(start, end),
            recognizer: recognizer,
            style: term != null || highlight != null
                ? TextStyle(
                    color: HomeStyle.blue,
                    backgroundColor: term != null
                        ? HomeStyle.blue.withValues(alpha: .08)
                        : null,
                    decoration: TextDecoration.underline,
                    decorationColor: HomeStyle.blue.withValues(alpha: .65),
                    decorationThickness: 1,
                  )
                : null,
          ),
        );
        offset = end;
      }
      spans.add(TextSpan(text: widget.text.substring(offset)));
      return Text.rich(
        TextSpan(children: spans),
        style: widget.style.copyWith(
          fontWeight: widget.highlights.isEmpty && _important
              ? FontWeight.w600
              : widget.style.fontWeight,
        ),
      );
    },
  );
}
