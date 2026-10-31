import 'meeting_models.dart';

/// 仅归并展示问题，不推断批准、执行或正式业务状态。
class MeetingIssuePolicy {
  MeetingIssuePolicy(List<MeetingUtterance> sources)
    : _sources = {for (final source in sources) source.id: source};
  final Map<String, MeetingUtterance> _sources;

  bool _distinctBranch(MeetingInsight item) =>
      item.kind == InsightKind.prediction &&
      RegExp(r'分支|替代方案|分期|否则|如果.+则|方案[一二三AB]|两种方案|三种方案').hasMatch(item.body);

  String _normalize(String text) => text.toLowerCase().replaceAllMapped(
    RegExp(r'\b[a-z]{1,3}(?:\s+[a-z]{1,3}){1,4}\b'),
    (m) => m[0]!.replaceAll(RegExp(r'\s+'), ''),
  );

  String? _family(MeetingInsight item) {
    if (item.kind == InsightKind.stitch) return null;
    if (_distinctBranch(item)) return null;
    final text = _normalize('${item.title} ${item.body}');
    if (RegExp(r'数据丢失|数据泄露|越权|重复扣款|安全漏洞|服务宕机').hasMatch(item.title)) {
      return null;
    }
    if (item.title == '信息待补全' || item.id.startsWith('questionnaire-')) {
      return 'task-details';
    }
    if (RegExp(
      r'(?:主体|主要|功能|开发).*(?:完成|已完)|(?:遗留|仍有|还剩|未解决|未关闭).*(?:问题|缺陷)',
    ).hasMatch(item.title)) {
      return 'readiness';
    }
    if (RegExp(r'验收|持续运行|稳定运行|持续时长|运行时长|量化标准|通过率|稳定指标|运行口径').hasMatch(text)) {
      return 'acceptance';
    }
    if (RegExp(
      r'(?:主体|主要|功能|开发).*(?:完成|已完)|(?:遗留|仍有|还剩|未解决|未关闭).*(?:问题|缺陷)',
    ).hasMatch(text)) {
      return 'readiness';
    }
    return null;
  }

  Set<String> _subjects(String text) {
    text = _normalize(text);
    return {
      ...RegExp(r'\b[a-z]{2,12}\b')
          .allMatches(text)
          .map((m) => m[0]!)
          .where((s) => !{'app', 'ai', 'id'}.contains(s)),
      if (RegExp(r'图片.*上传|上传.*图片|图片上传|上传图片').hasMatch(text)) '图片上传',
      if (text.contains('支付')) '支付',
      if (text.contains('登录')) '登录',
    };
  }

  Set<String> _subject(MeetingInsight item) {
    final title = _subjects(item.title);
    if (title.isNotEmpty) return title;
    final body = _subjects(item.body);
    if (body.isNotEmpty) return body;
    return _subjects(
      item.evidenceIds
          .map((id) {
            final source = _sources[id];
            return source?.correction ?? source?.raw ?? '';
          })
          .join(' '),
    );
  }

  Set<String> _constraints(MeetingInsight item) => RegExp(
    r'\d+(?:\.\d+)?\s*(?:小时|分钟|天|万元|元|%)|[零〇一二两三四五六七八九十百千万]+(?:小时|分钟|天|万元|元)|[本下这]?(?:周|星期)[一二三四五六日天]|\d{4}[-/]\d{1,2}[-/]\d{1,2}',
  ).allMatches(item.body).map((m) => m[0]!).toSet();

  bool mustStaySeparate(MeetingInsight a, MeetingInsight b) {
    if (a.topicKey.isNotEmpty &&
        a.issueKey.isNotEmpty &&
        b.topicKey.isNotEmpty &&
        b.issueKey.isNotEmpty) {
      if (!_nearTopic(a, b)) {
        return true;
      }
      final x = _constraints(a), y = _constraints(b);
      if (x.isNotEmpty &&
          y.isNotEmpty &&
          (x.length != y.length || !x.containsAll(y))) {
        return true;
      }
      if (_distinctBranch(a) != _distinctBranch(b)) return true;
      final subjectA = _subject(a), subjectB = _subject(b);
      if (subjectA.isNotEmpty &&
          subjectB.isNotEmpty &&
          subjectA.intersection(subjectB).isEmpty) {
        return true;
      }
      // 已有明确语义键时，不再被旧的按标题词汇分类拆成多个角色卡片。
      return false;
    }
    if (_distinctBranch(a) != _distinctBranch(b)) return true;
    final family = _family(a), other = _family(b);
    if (family == null || other == null) return false;
    if (family != other) return true;
    final x = _subject(a), y = _subject(b);
    if (x.isNotEmpty && y.isNotEmpty && x.intersection(y).isEmpty) return true;
    final ax = _constraints(a), bx = _constraints(b);
    if (ax.isNotEmpty &&
        bx.isNotEmpty &&
        (ax.length != bx.length || !ax.containsAll(bx))) {
      return true;
    }
    if (family == 'task-details') {
      final left = a.body.split(RegExp(r'[：:]'));
      final right = b.body.split(RegExp(r'[：:]'));
      if (left.length > 1 &&
          right.length > 1 &&
          left.first.trim() != right.first.trim()) {
        return true;
      }
    }
    return false;
  }

  bool same(MeetingInsight a, MeetingInsight b) {
    final family = _family(a);
    if (family == null || family != _family(b)) return false;
    final shared = a.evidenceIds.any(b.evidenceIds.contains);
    if (family != 'acceptance' && !shared) return false;
    if (family == 'task-details') {
      String? subject(MeetingInsight item) {
        final pieces = item.body.split(RegExp(r'[：:]'));
        return pieces.length > 1 ? pieces.first.trim() : null;
      }

      final left = subject(a), right = subject(b);
      if (left != null && right != null && left != right) return false;
    }
    final x = _subject(a), y = _subject(b);
    // 同段出现ERP与图片上传时，不能把两个对象的独立问题合并。
    if (x.isNotEmpty && y.isNotEmpty && x.intersection(y).isEmpty) return false;
    if (!shared &&
        (x.isEmpty || y.isEmpty || x.length != y.length || !x.containsAll(y))) {
      return false;
    }
    final ax = _constraints(a), bx = _constraints(b);
    if (ax.isNotEmpty &&
        bx.isNotEmpty &&
        (ax.length != bx.length || !ax.containsAll(bx))) {
      return false;
    }
    final textA = '${a.title} ${a.body}', textB = '${b.title} ${b.body}';
    bool approved(String text) =>
        RegExp(r'已批准|正式批准|已确认通过|已经通过|明确不纳入').hasMatch(text);
    if (approved(textA) != approved(textB)) return false;
    return true;
  }

  /// 通用问题聚类：优先业务对象+问题键，旧数据用标题/正文相似度与证据邻接兜底。
  /// 不依赖预先列出会议场景，不增开 LLM 或在手机运行向量模型。
  bool sameGeneric(MeetingInsight a, MeetingInsight b) {
    if (a.kind == InsightKind.stitch ||
        b.kind == InsightKind.stitch ||
        _distinctBranch(a) ||
        _distinctBranch(b)) {
      return false;
    }
    final x = _subject(a), y = _subject(b);
    if (x.isNotEmpty && y.isNotEmpty && x.intersection(y).isEmpty) return false;
    final ac = _constraints(a), bc = _constraints(b);
    if (ac.isNotEmpty &&
        bc.isNotEmpty &&
        (ac.length != bc.length || !ac.containsAll(bc))) {
      return false;
    }
    final keyed =
        a.topicKey.isNotEmpty &&
        a.issueKey.isNotEmpty &&
        b.topicKey.isNotEmpty &&
        b.issueKey.isNotEmpty;
    if (keyed) {
      if (!_nearTopic(a, b)) return false;
      if (_canonical(a.issueKey) == _canonical(b.issueKey)) return true;
      // 模型给相同问题起了不同键时，仍需根据标题、内容和证据近似匹配。
    }
    final shared = a.evidenceIds.any(b.evidenceIds.contains);
    final left = a.evidenceIds.map((id) => _sources[id]).nonNulls.toList();
    final right = b.evidenceIds.map((id) => _sources[id]).nonNulls.toList();
    final adjacent = left.any(
      (l) => right.any(
        (r) =>
            l.turnId != null &&
            l.turnId == r.turnId &&
            l.speakerId == r.speakerId,
      ),
    );
    if (!shared && !adjacent) return false;
    final titleA = _canonical(a.title), titleB = _canonical(b.title);
    if (titleA.length < 3 || titleB.length < 3) return false;
    final titleScore = _similarity(titleA, titleB);
    final bodyScore = _similarity(_canonical(a.body), _canonical(b.body));
    return (titleScore >= .85 && bodyScore >= .10) ||
        (titleScore >= .70 && bodyScore >= .25);
  }

  String _canonical(String value) => _normalize(value)
      .replaceAll(
        RegExp(r'是否|具体|什么|尚未|仍需|建议|确认|待核对|补充|进一步|待补全|待评估|不明|缺失|待完善|仍然|说明|明确'),
        '',
      )
      .replaceAll(RegExp(r'[\s，。！？、：；,.!?:;“”「」·…—-]'), '');

  bool _nearTopic(MeetingInsight a, MeetingInsight b) {
    final x = _canonical(a.topicKey), y = _canonical(b.topicKey);
    if (x == y || _similarity(x, y) >= .6) return true;
    final left = _subject(a), right = _subject(b);
    return left.isNotEmpty &&
        right.isNotEmpty &&
        left.intersection(right).isNotEmpty &&
        _similarity(_canonical(a.title), _canonical(b.title)) >= .85;
  }

  double _similarity(String a, String b) {
    Set<String> grams(String s) => {
      for (var i = 0; i + 1 < s.length; i++) s.substring(i, i + 2),
    };
    final x = grams(a), y = grams(b);
    return x.isEmpty || y.isEmpty
        ? 0
        : x.intersection(y).length / x.union(y).length;
  }

  int _score(MeetingInsight item) {
    final text = '${item.title} ${item.body}';
    var score = item.kind == InsightKind.question ? 4 : 0;
    score += item.body.runes.length.clamp(0, 80) ~/ 25;
    score += RegExp(
      r'影响|阻塞|导致|后果|处理条件|影响范围',
    ).allMatches(item.body).length.clamp(0, 3);
    score += RegExp(
      r'确认|明确|口径|量化|标准|时长|测试范围|测试条件|通过率|履约方|交付日期',
    ).allMatches(text).length.clamp(0, 6);
    if (item.title == '信息待补全') score -= 2;
    if (RegExp(r'被提为|未提到既有目标|指代不明|对象存疑').hasMatch(item.title)) score -= 3;
    return score;
  }

  MeetingInsight prefer(MeetingInsight old, MeetingInsight next) {
    if (old.topicKey.isNotEmpty &&
        old.issueKey.isNotEmpty &&
        sameGeneric(old, next)) {
      return old.attention == 'urgent' && next.attention != 'urgent'
          ? old
          : next;
    }
    if (_family(old) == 'task-details') {
      // 一个行动的交期与履约方缺口合在一张卡片；问题本身不改写业务字段。
      final sentences = {
        ...old.body.split(RegExp(r'(?<=[？?。])')),
        ...next.body.split(RegExp(r'(?<=[？?。])')),
      }.where((s) => s.trim().isNotEmpty).toList();
      return MeetingInsight.fromJson({
        ...next.toJson(),
        'body': sentences.join(' '),
      });
    }
    // 同一问题保留较完整、可操作的表述，不因后到的泛泛担忧增加卡片。
    return _score(next) >= _score(old) ? next : old;
  }
}
