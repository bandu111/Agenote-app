/// 连接级即时身份；persisted 标记的结果可写入会议本机只读快照。
class LiveSpeakerIdentityEvent {
  const LiveSpeakerIdentityEvent({
    required this.sessionId,
    required this.scope,
    this.isSession = false,
    this.status,
    this.speakerId,
    this.identity,
    this.revision = 0,
    this.persisted = false,
    this.meetingRevision = 0,
  });
  final String sessionId, scope;
  final bool isSession;
  final String? status, speakerId, identity;
  final int revision, meetingRevision;
  final bool persisted;
}

class LiveSpeakerIdentityStore {
  String? sessionId, scope, status;
  final _identities = <String, (int, String)>{};

  void clear() {
    sessionId = scope = status = null;
    _identities.clear();
  }

  bool accept(LiveSpeakerIdentityEvent event) {
    if (event.isSession) {
      clear();
      sessionId = event.sessionId;
      scope = event.scope;
      status = event.status;
      return true;
    }
    if (event.sessionId != sessionId || event.scope != scope) return false;
    if (event.status != null) {
      status = event.status;
      _identities.clear();
      return true;
    }
    if (status != 'enabled' ||
        event.speakerId == null ||
        !['self', 'other', 'unknown'].contains(event.identity) ||
        event.revision <= (_identities[event.speakerId]?.$1 ?? 0)) {
      return false;
    }
    _identities[event.speakerId!] = (event.revision, event.identity!);
    return true;
  }

  bool contains(String? speakerId) => _identities.containsKey(speakerId);

  String label(String? speakerId, String original) {
    if (status != 'enabled' || _identities[speakerId]?.$2 != 'self') {
      return original;
    }
    final short = original.startsWith('发言人 ')
        ? original.substring(4)
        : original;
    return '我（$short）';
  }

  String get hint {
    if (sessionId == null) return '';
    if (status == 'enabled') {
      return _identities.values.any((value) => value.$2 == 'self')
          ? '已识别到本人'
          : '本人识别中，请正常发言';
    }
    return switch (status) {
      'not_registered' => '未启用声纹，继续按发言人区分',
      'template_changed' => '声纹已变更，本次本人识别已停止',
      'disconnected' => '本人识别等待重连',
      _ => '本人识别暂不可用，转写继续',
    };
  }
}
