import 'package:flutter/foundation.dart';

class TranscriptHighlight {
  const TranscriptHighlight(
    this.start,
    this.end,
    this.quote,
    this.kind,
    this.reason,
  );
  final int start, end;
  final String quote, kind, reason;
  Map<String, dynamic> toJson() => {
    'start': start,
    'end': end,
    'quote': quote,
    'kind': kind,
    'reason': reason,
  };

  static List<TranscriptHighlight> parse(String raw, dynamic values) {
    if (values is! List || values.length > 2) return [];
    final hits = <TranscriptHighlight>[];
    for (final value in values) {
      if (value is! Map) continue;
      final start = value['start'], end = value['end'];
      final quote = value['quote'],
          kind = value['kind'],
          reason = value['reason'];
      if (start is! int ||
          end is! int ||
          quote is! String ||
          reason is! String ||
          !{
            'time',
            'commitment',
            'decision',
            'risk',
            'number',
          }.contains(kind) ||
          start < 0 ||
          end <= start ||
          end > raw.length ||
          quote.length < 2 ||
          reason.isEmpty ||
          reason.length > 80 ||
          raw.substring(start, end) != quote ||
          hits.any((h) => start < h.end && end > h.start)) {
        continue;
      }
      hits.add(TranscriptHighlight(start, end, quote, kind as String, reason));
    }
    return hits;
  }
}

class TranscriptHighlightBatch {
  TranscriptHighlightBatch(
    this.raw,
    this.revision,
    this.trace,
    this.items, {
    this.onDisplayed,
  });
  final String raw, revision, trace;
  final List<TranscriptHighlight> items;
  final VoidCallback? onDisplayed;
  Map<String, dynamic> toJson() => {
    'raw': raw,
    'revision': revision,
    'trace': trace,
    'items': items.map((h) => h.toJson()).toList(),
  };
  static TranscriptHighlightBatch? restore(dynamic value, String raw) {
    if (value is! Map || value['raw'] != raw || value['revision'] is! String) {
      return null;
    }
    final items = TranscriptHighlight.parse(raw, value['items']);
    if (items.isEmpty) return null;
    return TranscriptHighlightBatch(
      raw,
      value['revision'] as String,
      value['trace'] as String? ?? '',
      items,
    );
  }

  bool _displayed = false;
  void displayed() {
    if (_displayed) return;
    _displayed = true;
    onDisplayed?.call();
  }
}

/// 每个原始片段独立通知；新标注不会通知整个会议 ViewModel。
class TranscriptHighlightStore {
  final _values = <String, ValueNotifier<TranscriptHighlightBatch?>>{};
  ValueNotifier<TranscriptHighlightBatch?> forSource(String id) =>
      _values.putIfAbsent(id, () => ValueNotifier(null));
  void accept(String id, String raw, TranscriptHighlightBatch batch) {
    if (raw != batch.raw) return;
    final target = forSource(id);
    if (target.value?.revision == batch.revision) return;
    target.value = batch;
  }

  void dispose() {
    for (final value in _values.values) {
      value.dispose();
    }
    _values.clear();
  }
}
