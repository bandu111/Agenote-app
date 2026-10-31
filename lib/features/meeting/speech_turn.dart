import 'meeting_models.dart';

/// 只控制显示合段；真实音频间隔优先，缺少边界时保守使用记录时间。
bool withinSpeechParagraphGap(MeetingUtterance before, MeetingUtterance after) {
  final gap = before.audioEnd != null && after.audioStart != null
      ? after.audioStart! - before.audioEnd!
      : after.at - before.at;
  return !gap.isNegative && gap <= const Duration(seconds: 2);
}

/// 未完成轮次只在末段显示一个待补状态；这是证据状态，不是模型补写。
Set<String> pendingSpeechCompletionIds(List<MeetingUtterance> utterances) {
  final tails = <String, MeetingUtterance>{};
  for (final u in utterances) {
    tails['${u.turnId ?? u.id}:${u.speakerId ?? u.speaker}'] = u;
  }
  return {
    for (final u in tails.values)
      if (u.turnStatus == 'interrupted' &&
          !u.withdrawn &&
          !u.manual &&
          u.correction == null &&
          !(u.repair?.validFor(u.raw) ?? false))
        u.id,
  };
}

/// ASR 稳定片段不等于完整发言；这里只做保守收尾，不判断业务是否获批。
bool isUnfinishedSpeech(String text) {
  final value = text.trim().replaceAll(RegExp(r'[，,。.!！?？;；：:\s]+$'), '');
  if (value.runes.length < 3) return true;
  for (final pair in [('“', '”'), ('「', '」'), ('（', '）'), ('(', ')')]) {
    if (pair.$1.allMatches(value).length > pair.$2.allMatches(value).length) {
      return true;
    }
  }
  if (RegExp(
    r'(还没有|尚未|并未|不能够|交期是|截止到|定于|调整为|改为|取决于|包括|分别是|就按|按|以|由|从|是|为|将|要|让|给|跟|对|向|与)$',
  ).hasMatch(value)) {
    return true;
  }
  if (RegExp(r'(?:我|我们|大家)(?:计划|准备)$').hasMatch(value)) return true;
  return RegExp(
    r'(…|\.\.\.|然后|但是|因为|所以|如果|比如|关于|就是|需要|我们|这个|那个|以及|还有|或者|和|把|的|在|到|先|我想|我要|我们要|我们会|我们将|我会|我说|应该|必须|希望|打算|按照|根据|例如|至于)$',
  ).hasMatch(value);
}

/// 展示按发言轮次聚合，底层片段、原声和证据 ID 始终保留。
/// 声纹聚类更正后按实际身份重新分组，不跨说话人拼接。
List<List<MeetingUtterance>> speechTurnGroups(
  List<MeetingUtterance> utterances,
) {
  final groups = <List<MeetingUtterance>>[];
  for (final item in utterances) {
    final previous = groups.lastOrNull?.last;
    if (previous != null &&
        item.turnId != null &&
        previous.turnId == item.turnId &&
        previous.speakerId == item.speakerId &&
        previous.speaker == item.speaker &&
        previous.speakerSeparated == item.speakerSeparated &&
        previous.audioPath == item.audioPath &&
        withinSpeechParagraphGap(previous, item) &&
        !item.manual &&
        !previous.manual) {
      groups.last.add(item);
    } else {
      groups.add([item]);
    }
  }
  return groups;
}

/// 安静环境保留轻声发言；噪声底只由非语音帧慢速更新，避免长句被当成环境噪声。
class SpeechActivityGate {
  double _floor = .002;
  bool observe(double rms) {
    if (!rms.isFinite || rms < 0) return false;
    final threshold = (_floor * 3).clamp(.008, .045);
    final speech = rms >= threshold;
    if (!speech) {
      _floor = (_floor * .98 + rms * .02).clamp(.0005, .015);
    }
    return speech;
  }

  void reset() {
    _floor = .002;
  }
}

/// 段落只是展示投影，原切片 ID、原声、纠错与撤回证据不被重写。
class SpeechParagraph {
  SpeechParagraph(this.sources);
  final List<MeetingUtterance> sources;
  MeetingUtterance get display {
    if (sources.length == 1) return sources.single;
    final first = sources.first, last = sources.last;
    return MeetingUtterance(
      id: first.id,
      speaker: first.speaker,
      speakerId: first.speakerId,
      speakerSeparated: first.speakerSeparated,
      turnId: first.turnId,
      raw: sources.map((s) => s.raw).join(''),
      cleaned: sources.map((s) => s.display).join(''),
      at: first.at,
      audioPath: first.audioPath,
      audioStart: first.audioStart,
      audioEnd: last.audioEnd,
      turnStatus: sources.any((s) => s.turnStatus == 'pending')
          ? 'pending'
          : last.turnStatus,
    );
  }
}

List<SpeechParagraph> speechParagraphs(
  List<MeetingUtterance> group, {
  Set<String> protectedIds = const {},
}) {
  final paragraphs = <SpeechParagraph>[];
  bool protected(MeetingUtterance u) =>
      u.manual ||
      u.withdrawn ||
      u.correction != null ||
      u.repair != null ||
      protectedIds.contains(u.id);
  for (final item in group) {
    final previous = paragraphs.lastOrNull?.sources.last;
    if (previous != null &&
        !protected(previous) &&
        !protected(item) &&
        previous.turnId != null &&
        previous.turnId == item.turnId &&
        previous.speakerId == item.speakerId &&
        previous.speaker == item.speaker &&
        previous.speakerSeparated == item.speakerSeparated &&
        previous.audioPath == item.audioPath &&
        previous.hasAudio == item.hasAudio &&
        withinSpeechParagraphGap(previous, item) &&
        (previous.audioEnd == null ||
            item.audioStart == null ||
            item.audioStart! >= previous.audioEnd!)) {
      paragraphs.last.sources.add(item);
    } else {
      paragraphs.add(SpeechParagraph([item]));
    }
  }
  return paragraphs;
}
