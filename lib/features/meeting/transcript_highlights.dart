import 'package:flutter/material.dart';
import 'meeting_models.dart';
import 'meeting_terms.dart';
import '../home/views/home_style.dart';

import 'transcript_highlight_models.dart';
export 'transcript_highlight_models.dart';

class MeetingHighlightedText extends StatefulWidget {
  const MeetingHighlightedText({
    super.key,
    required this.text,
    required this.style,
    required this.sources,
    required this.store,
    this.onTermTap,
    this.onReplay,
    this.classify = true,
    this.useRawText = false,
    this.paragraphEmphasis = false,
    this.paragraphImportant = false,
  });
  final String text;
  final TextStyle style;
  final List<MeetingUtterance> sources;
  final TranscriptHighlightStore store;
  final ValueChanged<MeetingTermMatch>? onTermTap;
  final ValueChanged<MeetingUtterance>? onReplay;
  final bool classify;
  final bool useRawText;

  /// 纪要用整段重点样式，不展示可展开的重点原因入口。
  final bool paragraphEmphasis;
  final bool paragraphImportant;
  @override
  State<MeetingHighlightedText> createState() => _MeetingHighlightedTextState();
}

class _MeetingHighlightedTextState extends State<MeetingHighlightedText> {
  (TranscriptHighlight, MeetingUtterance)? _selected;
  MeetingTermMatch? _term;
  String? _termText;
  bool _termContext = false;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([
      for (final s in widget.sources) widget.store.forSource(s.id),
    ]),
    builder: (context, _) {
      final hits = <(TranscriptHighlight, MeetingUtterance)>[];
      final batches = <TranscriptHighlightBatch>[];
      var offset = 0;
      // 只在精确的原始来源投影中映射；纠错、撤回或无法映射时不猜坐标。
      for (final source in widget.sources) {
        final value = widget.store.forSource(source.id).value;
        final display = widget.useRawText ? source.raw : source.display;
        if (value != null &&
            value.raw == source.raw &&
            !source.withdrawn &&
            source.correction == null &&
            offset + display.length <= widget.text.length &&
            widget.text.substring(offset, offset + display.length) == display) {
          for (final h in value.items) {
            // 整理文本与原文不同，只接受唯一连续引用，绝不套用旧偏移。
            final start = display == source.raw
                ? h.start
                : display.indexOf(h.quote);
            if (start < 0 ||
                display.indexOf(h.quote, start + 1) >= 0 ||
                start + h.quote.length > display.length ||
                display.substring(start, start + h.quote.length) != h.quote) {
              continue;
            }
            hits.add((
              TranscriptHighlight(
                offset + start,
                offset + start + h.quote.length,
                h.quote,
                h.kind,
                h.reason,
              ),
              source,
            ));
          }
          if (hits.any((h) => h.$2.id == source.id)) batches.add(value);
        }
        offset += display.length;
      }
      final selected = _selected;
      final current = selected == null
          ? null
          : hits
                .where(
                  (h) =>
                      h.$2.id == selected.$2.id &&
                      h.$1.quote == selected.$1.quote &&
                      h.$1.reason == selected.$1.reason,
                )
                .firstOrNull;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          for (final batch in batches) {
            batch.displayed();
          }
        }
      });
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          MeetingTermText(
            text: widget.text,
            style:
                widget.paragraphEmphasis &&
                    (widget.paragraphImportant || hits.isNotEmpty)
                ? widget.style.copyWith(
                    fontWeight: FontWeight.w600,
                    decoration: TextDecoration.underline,
                    decorationColor: HomeStyle.blue,
                  )
                : widget.style,
            classify: widget.classify,
            highlights: widget.paragraphEmphasis
                ? const []
                : hits.map((h) => h.$1).toList(),
            onHighlightTap: (hit) => setState(() {
              _selected = hits.firstWhere((h) => identical(h.$1, hit));
              _termContext = false;
            }),
            onTermTap: (term) {
              if (widget.onTermTap != null) {
                widget.onTermTap!(term);
              } else {
                setState(() {
                  _term = term;
                  _termText = widget.text;
                  _termContext = true;
                  _selected = null;
                });
              }
            },
          ),
          if (_term != null && _termText == widget.text) ...[
            TextButton(
              onPressed: () => setState(() => _termContext = !_termContext),
              child: Text(
                _termContext ? '收起上下文' : '展开上下文 ›',
                style: const TextStyle(fontSize: 11),
              ),
            ),
            if (_termContext)
              Container(
                key: const ValueKey('transcript-term-explanation'),
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: HomeStyle.blue.withValues(alpha: .045),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '术语解释 · ${_term!.term}',
                      style: HomeStyle.text(
                        11,
                        bold: true,
                        color: HomeStyle.blue,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(_term!.definition, style: HomeStyle.text(12)),
                  ],
                ),
              ),
          ],
          if (!widget.paragraphEmphasis &&
              (widget.paragraphImportant || hits.isNotEmpty))
            TextButton(
              key: const ValueKey('transcript-highlight-label'),
              onPressed: () => setState(() {
                _selected = current == null ? hits.first : null;
                _termContext = false;
              }),
              child: const Text(
                '重点',
                style: TextStyle(fontSize: 11, color: HomeStyle.blue),
              ),
            ),
          if (!widget.paragraphEmphasis && current != null)
            Container(
              key: const ValueKey('transcript-highlight-reason'),
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: HomeStyle.blue.withValues(alpha: .045),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '重点 · AI 标注',
                    style: HomeStyle.text(
                      11,
                      bold: true,
                      color: HomeStyle.blue,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(current.$1.reason, style: HomeStyle.text(12)),
                  Text('“${current.$1.quote}”', style: HomeStyle.text(12)),
                  TextButton.icon(
                    onPressed: current.$2.hasAudio && widget.onReplay != null
                        ? () => widget.onReplay!(current.$2)
                        : null,
                    icon: const Icon(Icons.play_circle_outline, size: 16),
                    label: const Text('原始录音依据', style: TextStyle(fontSize: 11)),
                  ),
                ],
              ),
            ),
        ],
      );
    },
  );
}
