import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/widgets.dart';
import '../home/viewmodels/home_view_model.dart';
import '../knowledge/viewmodels/knowledge_view_model.dart';
import '../knowledge/models/knowledge_models.dart';
import '../knowledge/repositories/dio_knowledge_repository.dart';
import '../notifications/notification_model.dart';
import 'meeting_models.dart';
import 'meeting_memory_workflow.dart';
import 'meeting_completion.dart';
import 'meeting_insights.dart';
import 'meeting_services.dart';
import 'meeting_store.dart';
import 'meeting_questions.dart';
import 'meeting_demo.dart';
import 'meeting_remote.dart';
import 'meeting_audio_recovery.dart';
import 'speech_turn.dart';
import 'meeting_value_gate.dart';
import 'transcript_highlight_models.dart';
import 'live_speaker_identity.dart';
import '../../core/network/api_config.dart';

class MeetingViewModel extends ChangeNotifier with WidgetsBindingObserver {
  final _liveIdentity = LiveSpeakerIdentityStore();
  String speakerDisplayName(MeetingUtterance source) =>
      active && !source.manual && _liveIdentity.contains(source.speakerId)
      ? _liveIdentity.label(source.speakerId, source.speaker)
      : record?.speakerDisplayName(source) ?? source.speaker;
  bool _identitySyncFailed = false;
  Future<void> _refreshSpeakerIdentities() async {
    final source = record;
    if (source == null ||
        source.demo ||
        source.ownerId != remote?.accountId ||
        remote is! MeetingSpeakerIdentityRemote) {
      return;
    }
    try {
      final value = await (remote as MeetingSpeakerIdentityRemote)
          .readSpeakerIdentities(source);
      if (_disposed ||
          record?.id != source.id ||
          record?.ownerId != remote?.accountId) {
        return;
      }
      final revision = value['revision'] as int;
      if (revision >= record!.speakerIdentityRevision) {
        record = record!.copy(
          clearCloudMinutes: revision != record!.speakerIdentityRevision,
          speakerIdentityRevision: revision,
          speakerIdentities: Map<String, dynamic>.from(value['identities']),
        );
        await store.save(record!);
      }
      _identitySyncFailed = false;
    } catch (_) {
      if (_disposed ||
          record?.id != source.id ||
          record?.ownerId != source.ownerId) {
        return;
      }
      _identitySyncFailed = true;
    }
    _emit();
  }

  String get partialSpeakerDisplay =>
      _liveIdentity.label(_partialSpeakerId, partialSpeaker);
  String get selfIdentificationHint => _identitySyncFailed
      ? '身份尚未同步完成，请联网后重新打开会议核对'
      : phase == MeetingPhase.recording && record?.demo == false
      ? _liveIdentity.hint
      : '';
  final transcriptHighlights = TranscriptHighlightStore();
  MeetingViewModel({
    required this.store,
    required this.recorder,
    required this.calendar,
    required this.knowledge,
    required this.notifications,
    required this.home,
    MeetingAnalysisService? analysis,
    this.speakerName,
    this.remote,
    this.onProgressChanged,
    this.onNoticesChanged,
    this.audioRecovery,
    this.turnQuiet = const Duration(seconds: 5),
    this.unfinishedQuiet = const Duration(seconds: 9),
  }) : analysis = analysis ?? DemoMeetingAnalysis() {
    WidgetsBinding.instance.addObserver(this);
    if (audioRecovery != null) {
      _recoveryTimer = Timer.periodic(
        const Duration(seconds: 15),
        (_) => unawaited(recoverAudio()),
      );
    }
  }
  final MeetingStore store;
  late final questions = MeetingQuestions(store, remote);
  bool _markingQuestion = false;

  bool get canMarkQuestion =>
      active &&
      !busy &&
      !_markingQuestion &&
      (record?.utterances.any(
            (u) => !u.withdrawn && u.display.trim().isNotEmpty,
          ) ??
          false);

  Future<bool> markQuestion() async {
    final source = record;
    if (source == null || !canMarkQuestion) return false;
    _markingQuestion = true;
    try {
      String? part;
      int? sample;
      final device = recorder;
      if (device is DeviceMeetingRecorder && source.audioPaths.isNotEmpty) {
        final path = source.audioPaths.last;
        part = path.split(RegExp(r'[/\\]')).last;
        if (device.questionAudioPart == part) {
          sample = device.questionAudioSample;
        } else {
          // Restored paused sessions have no live recorder instance.
          final file = File(path);
          if (await file.exists()) {
            sample = ((await file.length()) - 44).clamp(0, 1 << 60) ~/ 2;
          }
        }
      }
      if (record?.id != source.id || !active || busy) return false;
      await questions.load(source);
      final current = record;
      if (current == null || current.id != source.id || !active || busy) {
        return false;
      }
      final association = questionAssociation({
        'atMs': elapsed.inMilliseconds,
        'part': part,
        'sample': sample,
        'sourceIds': <String>[],
      }, current);
      final ids = (association['sourceIds'] as List)
          .whereType<String>()
          .toSet();
      if (ids.isEmpty) return false;
      final paragraphs = speechTurnGroups(
        current.utterances,
      ).expand((group) => speechParagraphs(group));
      final target = paragraphs
          .where((p) => p.sources.any((u) => ids.contains(u.id)))
          .firstOrNull;
      final paragraphIds = target?.sources.map((u) => u.id).toSet() ?? ids;
      if (questions
          .items(current)
          .any(
            (q) => ((q['content']['sourceIds'] as List?) ?? []).any(
              paragraphIds.contains,
            ),
          )) {
        return false;
      }
      await questions.create(
        current,
        atMs: elapsed.inMilliseconds,
        part: part,
        sample: sample,
      );
      return true;
    } finally {
      _markingQuestion = false;
    }
  }

  final MeetingRecorder recorder;
  final MeetingCalendar calendar;
  final MeetingAnalysisService analysis;
  final KnowledgeViewModel knowledge;
  final NotificationModel notifications;
  final HomeViewModel home;
  final String Function()? speakerName;
  final MeetingRemoteRepository? remote;
  int _completionRevision = 0;
  int get completionRevision => _completionRevision;
  bool get completionUpdating => cloudAnalyzing || _businessWork != null;
  List<MeetingCompletionItem> _completionItems = [];
  String? _completionScope;
  int _completionLoadedRevision = -1, _completionReadFailures = 0;
  bool _completionReading = false;
  Timer? _completionReadRetry;

  bool hasCompletion(List<String> sourceIds) =>
      record != null &&
      !record!.demo &&
      record!.ownerId == remote?.accountId &&
      _completionScope == '${record!.ownerId}:${record!.id}' &&
      _completionItems.any(
        (item) =>
            !item.confirmed &&
            !item.reviewPending &&
            (item.needsSide || item.needsDeadline) &&
            item.sourceIds.any(sourceIds.contains),
      );

  List<MeetingCompletionItem> _keepNewerCompletions(
    List<MeetingCompletionItem> items,
  ) {
    final previous = {for (final item in _completionItems) item.id: item};
    return [
      for (final item in items)
        if ((previous[item.id]?.version ?? -1) > item.version)
          previous[item.id]!
        else
          item,
    ];
  }

  /// 每场会议共用一次读取；不为每张发言卡片发起网络请求。
  void _prepareCompletions({bool force = false}) {
    final source = record;
    final service = remote;
    if (_disposed ||
        source == null ||
        source.demo ||
        service is! MeetingCompletionRemote ||
        service?.accountId != source.ownerId) {
      return;
    }
    final scope = '${source.ownerId}:${source.id}';
    if (scope != _completionScope) {
      _completionScope = scope;
      _completionItems = [];
      _completionLoadedRevision = -1;
      _completionReadFailures = 0;
      _completionReadRetry?.cancel();
    }
    if (_completionReading ||
        (!force && _completionLoadedRevision == _completionRevision)) {
      return;
    }
    final revision = _completionRevision;
    _completionReading = true;
    unawaited(() async {
      try {
        final items = await (service as MeetingCompletionRemote)
            .completionItems(source, []);
        if (_disposed ||
            _completionScope != scope ||
            record?.id != source.id ||
            remote?.accountId != source.ownerId) {
          return;
        }
        _completionItems = _keepNewerCompletions(items);
        _completionReadFailures = 0;
      } catch (_) {
        if (!_disposed &&
            _completionScope == scope &&
            _completionReadFailures < 3) {
          _completionReadRetry?.cancel();
          _completionReadRetry = Timer(
            Duration(seconds: 2 << _completionReadFailures++),
            () => _prepareCompletions(force: true),
          );
        }
      } finally {
        _completionReading = false;
        if (!_disposed) {
          if (_completionScope == scope) _completionLoadedRevision = revision;
          _emit();
        }
      }
    }());
  }

  Future<List<MeetingCompletionItem>> completionItems(
    List<String> sourceIds,
  ) async {
    final source = record;
    final service = remote;
    if (source == null ||
        source.demo ||
        service is! MeetingCompletionRemote ||
        service?.accountId != source.ownerId) {
      throw StateError('请登录后在真实会议中补全履约信息');
    }
    final items = await (service as MeetingCompletionRemote).completionItems(
      source,
      sourceIds,
    );
    if (_disposed ||
        record?.id != source.id ||
        remote?.accountId != source.ownerId) {
      throw StateError('账户或会议已切换');
    }
    _completionItems = {
      for (final old in _completionItems)
        if (!old.sourceIds.any(sourceIds.contains)) old.id: old,
      for (final item in _keepNewerCompletions(items)) item.id: item,
    }.values.toList();
    _emit();
    return items;
  }

  Future<MeetingCompletionItem> confirmCompletion(
    MeetingCompletionItem item, {
    required String side,
    required DateTime deadline,
  }) async {
    final source = record;
    final service = remote;
    if (source == null ||
        source.demo ||
        service is! MeetingCompletionRemote ||
        service?.accountId != source.ownerId) {
      throw StateError('账户或会议已切换，请重新打开补全');
    }
    final saved = await (service as MeetingCompletionRemote).confirmCompletion(
      source,
      item,
      side: side,
      deadline: deadline,
    );
    if (_disposed ||
        record?.id != source.id ||
        remote?.accountId != source.ownerId) {
      throw StateError('账户或会议已切换，请重新打开补全');
    }
    _completionItems = [
      for (final old in _completionItems)
        if (old.id == saved.id) saved else old,
    ];
    _emit();
    try {
      await onProgressChanged?.call();
      await _refreshNotices();
    } catch (_) {
      // 已持久化成功；列表刷新失败不能让用户误以为需要重复执行。
    }
    return saved;
  }

  final MeetingAudioRecovery? audioRecovery;
  final Duration turnQuiet, unfinishedQuiet;
  Timer? _turnTimer;
  Timer? _valueTimer, _valueCooldown;
  final _valueSeen = <String>[];
  int _turnInputVersion = 0;
  int _semanticVersion = -1;
  bool? _semanticAnswer;
  DateTime? _turnDeadline;
  final _speechActivity = SpeechActivityGate();
  String? _turnSpeaker, _turnId;
  String? _partialSpeakerId;
  final _turnFragments = <String>[];
  List<MeetingUtterance>? _memoryWorkflowSources;
  List<MeetingInsight>? _memoryWorkflowInsights;
  String? _memoryWorkflowRecordId;

  String get _turnText => (record?.utterances ?? <MeetingUtterance>[])
      .where((u) => _turnFragments.contains(u.id))
      .map((u) => u.raw)
      .join('');

  void _armTurnEnd({bool fromAudio = false}) {
    if (_turnId == null || partial.isNotEmpty) return;
    final now = DateTime.now();
    final quiet = _turnFragments.isNotEmpty && isUnfinishedSpeech(_turnText)
        ? unfinishedQuiet
        : turnQuiet;
    // RMS 只能短暂延后收尾，不能把空调/底噪当作永不结束的发言。
    // 新的真实转写会重新建立窗口；未稳定的半句继续等待供应商确认。
    if (!fromAudio) _turnDeadline = now.add(quiet + unfinishedQuiet);
    final remaining = _turnDeadline?.difference(now) ?? quiet;
    if (fromAudio && remaining <= Duration.zero) return;
    _turnTimer?.cancel();
    _turnTimer = Timer(remaining < quiet ? remaining : quiet, () {
      _turnTimer = null;
      unawaited(_considerTurnEnd());
    });
  }

  Future<void> _considerTurnEnd() async {
    final source = record, turn = _turnId;
    final text = (source?.utterances ?? <MeetingUtterance>[])
        .where((u) => u.turnId == turn)
        .map((u) => u.correction ?? u.raw)
        .join('');
    if (_disposed || source == null || turn == null || partial.isNotEmpty) {
      return;
    }
    final service = remote;
    if (source.demo || service is! SemanticMeetingTurn || text.trim().isEmpty) {
      _closeTurn();
      return;
    }
    final version = _turnInputVersion;
    final generation = _generation;
    bool? complete = _semanticAnswer;
    if (_semanticVersion != version) {
      _semanticVersion = version;
      _semanticAnswer = null;
      complete = null;
      try {
        complete = await (service as SemanticMeetingTurn)
            .isTurnComplete(source, text)
            .timeout(const Duration(seconds: 5));
      } catch (_) {
        // 离线、旧服务或模型失败时继续保守等候，不中断录音。
      }
      if (_semanticVersion == version) _semanticAnswer = complete;
    }
    if (_disposed ||
        generation != _generation ||
        record?.id != source.id ||
        remote?.accountId != source.ownerId ||
        !active ||
        _turnId != turn ||
        version != _turnInputVersion ||
        record!.utterances
                .where((u) => u.turnId == turn)
                .map((u) => u.correction ?? u.raw)
                .join('') !=
            text ||
        partial.isNotEmpty ||
        _turnTimer?.isActive == true) {
      return;
    }
    if (complete == true && !isUnfinishedSpeech(text)) {
      _closeTurn();
      return;
    }
    // 语义未完成或不可判定只延长当前轮次，不重复请求模型，也不无限等候。
    final remaining =
        _turnDeadline?.difference(DateTime.now()) ?? unfinishedQuiet;
    _turnTimer = Timer(remaining.isNegative ? Duration.zero : remaining, () {
      _turnTimer = null;
      if (version == _turnInputVersion && partial.isEmpty) _closeTurn();
    });
  }

  void _closeTurn({
    bool interruptedBySpeaker = false,
    bool ignorePartial = false,
  }) {
    _turnTimer?.cancel();
    _valueTimer?.cancel();
    _valueTimer = null;
    _turnDeadline = null;
    if (_turnFragments.isEmpty || record == null) {
      _turnSpeaker = null;
      _turnId = null;
      return;
    }
    final status =
        interruptedBySpeaker ||
            (!ignorePartial && partial.isNotEmpty) ||
            isUnfinishedSpeech(_turnText)
        ? 'interrupted'
        : 'complete';
    final ids = _turnFragments.toSet();
    record = record!.copy(
      utterances: [
        for (final u in record!.utterances)
          ids.contains(u.id) ? u.revise(turnStatus: status) : u,
      ],
    );
    if (status == 'complete') {
      for (final u in record!.utterances.where((u) => ids.contains(u.id))) {
        _queuePolish(u);
      }
      // 日程只交给后端基于完整上下文规划，不能逐个 ASR 碎片弹出授权。
    }
    _turnFragments.clear();
    _speechActivity.reset();
    _turnSpeaker = null;
    _turnId = null;
    unawaited(_persist());
    _emit();
  }

  void _scheduleValueCheckpoint() {
    if (_disposed ||
        phase != MeetingPhase.recording ||
        record?.demo != false ||
        _valueTimer?.isActive == true ||
        _valueCooldown?.isActive == true) {
      return;
    }
    final pending = record!.utterances
        .where((u) => _turnFragments.contains(u.id))
        .toList();
    // 只选完整的稳定前缀；末尾尚未说完的 ASR 片段继续留作 pending。
    while (pending.isNotEmpty && isUnfinishedSpeech(pending.last.raw)) {
      pending.removeLast();
    }
    final text = pending.map((u) => u.correction ?? u.raw).join('');
    if (meetingValue(text, fragments: pending.length) == MeetingValue.none ||
        _valueSeen.contains(text)) {
      return;
    }
    // 有界合批，不因后续发言或麦克风一直有声音而重置等待。
    _valueTimer = Timer(const Duration(milliseconds: 1200), () {
      _valueTimer = null;
      _publishValueCheckpoint();
    });
  }

  void _publishValueCheckpoint() {
    if (_disposed || phase != MeetingPhase.recording || record?.demo != false) {
      return;
    }
    final pending = record!.utterances
        .where((u) => _turnFragments.contains(u.id))
        .toList();
    while (pending.isNotEmpty && isUnfinishedSpeech(pending.last.raw)) {
      pending.removeLast();
    }
    final text = pending.map((u) => u.correction ?? u.raw).join('');
    final value = meetingValue(text, fragments: pending.length);
    if (value == MeetingValue.none || _valueSeen.contains(text)) return;
    final ids = pending.map((u) => u.id).toSet();
    record = record!.copy(
      utterances: [
        for (final u in record!.utterances)
          ids.contains(u.id) ? u.revise(turnStatus: 'complete') : u,
      ],
    );
    // complete 表示这一信息片段已完整，不等于说话人已结束或业务已获批准。
    // 保留 turnId/话者和现有展示分组，不调用收尾、暂停或结束录音。
    _turnFragments.removeWhere(ids.contains);
    _valueSeen.add(text);
    if (_valueSeen.length > 12) _valueSeen.removeAt(0);
    for (final u in record!.utterances.where((u) => ids.contains(u.id))) {
      _queuePolish(u);
    }
    _valueCooldown = Timer(
      Duration(seconds: value == MeetingValue.context ? 25 : 8),
      () {
        _valueCooldown = null;
        _scheduleValueCheckpoint();
      },
    );
    unawaited(_persist());
    _emit();
  }

  Timer? _recoveryTimer;
  bool _recovering = false;
  final Future<void> Function()? onProgressChanged;
  final Future<void> Function()? onNoticesChanged;
  Timer? _cloudTimer, _cloudRetryTimer;
  int _cloudFailures = 0;
  Future<void>? _cloudWork;
  Future<void>? _evidenceWork, _businessWork;
  MeetingRecord? _lastUploaded, _businessPendingSource;
  String? _evidenceObserved, _businessFacts;
  Timer? _evidenceTimer;
  Timer? _liveTimer;
  Timer? _riskTimer;
  String? _riskFacts;
  bool _riskBusy = false;
  bool _liveBusy = false, _liveHasContent = false;
  bool _livePreviewDone = false;
  String? _liveFacts;
  bool get liveHintsLoading =>
      _liveBusy &&
      !_liveHasContent &&
      !_livePreviewDone &&
      !hasCompletion([?_liveHintAnchorId]);
  String? _liveHintAnchorId;
  String? get liveHintAnchorId => liveHintsLoading ? _liveHintAnchorId : null;

  /// 卡片流光覆盖首字等待和正文生成，完成事件后立即恢复。
  String? get liveGenerationAnchorId =>
      _liveBusy && !_livePreviewDone && !hasCompletion([?_liveHintAnchorId])
      ? _liveHintAnchorId
      : null;
  String? _cloudObserved, cloudError;
  final _audioTransfers = <String>{};
  final _deletedRecords = <String>{};
  final _audioCompleted = <String>{};
  final _audioRetries = <String, Timer>{};
  String? _audioUploadError;

  void _queueCloudAudio(MeetingRecord source) {
    final key = '${source.ownerId}:${source.id}';
    if (_disposed ||
        _deletedRecords.contains(key) ||
        source.offlineSyncHeld ||
        !source.ended ||
        !source.cloudAudioEnabled ||
        source.cloudAudioUploaded ||
        source.audioPaths.isEmpty ||
        _audioCompleted.contains(key) ||
        remote is! MeetingAudioRemote ||
        remote?.accountId != source.ownerId ||
        !_audioTransfers.add(key)) {
      return;
    }
    unawaited(() async {
      try {
        // 先让缺失转写恢复完整，再一次性发布录音与片段映射。
        if (audioRecovery != null && await audioRecovery!.hasPending(source)) {
          return;
        }
        await (remote as MeetingAudioRemote).uploadAudio(source);
        if (_disposed ||
            _deletedRecords.contains(key) ||
            remote?.accountId != source.ownerId) {
          return;
        }
        _audioCompleted.add(key);
        if (record?.id == source.id && record?.ownerId == source.ownerId) {
          record = record!.copy(cloudAudioUploaded: true);
          _audioUploadError = null;
          await store.save(record!);
        } else {
          final saved = (await store.read())
              .where((r) => r.id == source.id && r.ownerId == source.ownerId)
              .firstOrNull;
          if (saved != null) {
            await store.save(saved.copy(cloudAudioUploaded: true));
          }
        }
        if (_disposed || remote?.accountId != source.ownerId) return;
        await knowledge.load();
        await onProgressChanged?.call();
        _emit();
      } catch (_) {
        if (!_disposed &&
            !_deletedRecords.contains(key) &&
            remote?.accountId == source.ownerId) {
          if (record?.id == source.id) {
            _audioUploadError = '录音上传尚未完成，本机原声已保留，将自动续传';
          }
          _audioRetries.remove(key)?.cancel();
          _audioRetries[key] = Timer(const Duration(seconds: 30), () {
            _audioRetries.remove(key);
            _queueCloudAudio(record?.id == source.id ? record! : source);
          });
          _emit();
        }
      } finally {
        _audioTransfers.remove(key);
      }
    }());
  }

  bool _cloudPending = false, cloudAnalyzing = false, cloudAnalyzed = false;
  int _cloudGeneration = 0;
  String _captureId = '';
  Duration _captureTimeline = Duration.zero;
  final _speakerLabels = <String, String>{};
  String? _lastAnalyzedFacts;
  final _polishQueue = <(MeetingRecord, MeetingUtterance, int)>[];
  Future<void>? _polishWork;
  Timer? _polishDelay;
  String? polishError;

  /// 仅使用本应用实际采音路由，不将蓝牙配对或播放连接当成采音成功。
  String get inputStatus {
    if (phase != MeetingPhase.recording && phase != MeetingPhase.paused) {
      return '未开始采音';
    }
    final device = recorder is DeviceMeetingRecorder
        ? recorder as DeviceMeetingRecorder
        : null;
    if (device?.inputLost == true) return '采音设备已断开';
    if (phase == MeetingPhase.paused) return '采音已暂停';
    final route = device?.inputRoute;
    if (route == null || !route.verified || route.silenced) {
      return '采音状态待核实';
    }
    return switch (route.type) {
      'bluetooth' => '蓝牙麦克风',
      'recordingCard' => '录音卡麦克风',
      'builtIn' => '手机麦克风',
      'usb' || 'wired' => '外接麦克风',
      _ => '采音状态待核实',
    };
  }

  String get _transcriptionLabel =>
      recorder is DeviceMeetingRecorder &&
          (recorder as DeviceMeetingRecorder).transcriptionPending
      ? (recorder as DeviceMeetingRecorder).transcriptionBacklogMilliseconds >
                2000
            ? '转写待恢复 · 积压 ${((recorder as DeviceMeetingRecorder).transcriptionBacklogMilliseconds / 1000).ceil()} 秒'
            : '转写待恢复'
      : recorder is DeviceMeetingRecorder &&
            (recorder as DeviceMeetingRecorder).recognizerFactory != null
      ? '腾讯云实时转写'
      : '本地流式转写';
  bool _checkingAnalysis = false, _corePreviewReady = false;
  bool _coreHasContent = false;
  bool _coreInitialResultReady = false;
  String? _coreHintAnchorId;
  bool get coreHintsLoading =>
      cloudAnalyzing &&
      !_coreHasContent &&
      !_coreInitialResultReady &&
      !hasCompletion([?_coreHintAnchorId]);
  String? get coreHintAnchorId => _coreHintAnchorId;
  bool? _analysisConfigured;
  String get analysisStatus {
    if (remote == null) return '会议服务未配置';
    if (remote?.accountId == null) return '请登录以启用会议AI';
    if (record?.ownerId != null && record!.ownerId != remote?.accountId) {
      return '会议账户不匹配';
    }
    if (cloudError != null) return cloudError!;
    if (_audioUploadError != null) return _audioUploadError!;
    if (_checkingAnalysis) return '正在检查会议AI连接';
    if (_analysisConfigured == false) return '服务端会议AI配置未完成';
    if (cloudAnalyzing) {
      return _corePreviewReady ? '核心提示已返回 · 后续分析中' : 'AI 分析中 · 录音持续进行';
    }
    if (cloudAnalyzed) return 'AI 已分析 · 持续监听新发言';
    if (_turnFragments.isNotEmpty || partial.isNotEmpty) {
      return '实时转写中 · 等待发言完整';
    }
    return '等待完整发言后自动分析';
  }

  String get recordingStatus =>
      '$inputStatus · $_transcriptionLabel · $analysisStatus';

  Future<void> _checkAnalysisConnection() async {
    final service = remote;
    if (service == null ||
        service is! MeetingAnalysisConnection ||
        service.accountId == null ||
        _checkingAnalysis) {
      return;
    }
    final owner = service.accountId;
    final generation = _cloudGeneration;
    _checkingAnalysis = true;
    _emit();
    try {
      final configured = await (service as MeetingAnalysisConnection)
          .checkAnalysisConnection();
      if (!_disposed &&
          generation == _cloudGeneration &&
          owner == remote?.accountId) {
        _analysisConfigured = configured;
      }
    } catch (error) {
      if (!_disposed &&
          generation == _cloudGeneration &&
          owner == remote?.accountId) {
        cloudError = error is ApiFailure ? error.message : '会议AI连接失败，本地录音继续保存';
      }
    } finally {
      if (!_disposed && generation == _cloudGeneration) {
        _checkingAnalysis = false;
        _emit();
      }
    }
  }

  MeetingRecord? record;
  MeetingPhase phase = MeetingPhase.ready;
  bool busy = false, loading = false, _disposed = false, _nativeLive = false;
  String? error, storageError;
  String partial = '', partialSpeaker = '';
  final List<double> waveform = [];
  final List<MeetingRecord> history = [];
  Timer? _ticker, _demoTimer, _persistTimer;
  StreamSubscription<double>? _levels;
  StreamSubscription<String>? _states;
  StreamSubscription<MeetingTranscript>? _transcripts;
  bool _pauseRequested = false;
  bool _preparingTranscript = false;
  final _pendingTranscripts = <MeetingTranscript>[];
  Stopwatch _clock = Stopwatch();
  Duration _base = Duration.zero;
  int _generation = 0, _demoIndex = 0, _demoChars = 0, _analysisRevision = 0;
  bool get nativeRecordingActive => _nativeLive;
  bool get active =>
      phase == MeetingPhase.recording || phase == MeetingPhase.paused;
  Duration get elapsed => _base + _clock.elapsed;

  Future<void> suspendForLogout() async {
    _valueTimer?.cancel();
    _valueCooldown?.cancel();
    ++_cloudGeneration;
    _evidenceTimer?.cancel();
    _evidenceTimer = null;
    _businessPendingSource = null;
    _polishQueue.clear();
    _polishDelay?.cancel();
    _polishDelay = null;
    _cloudTimer?.cancel();
    _liveTimer?.cancel();
    _riskTimer?.cancel();
    _cloudRetryTimer?.cancel();
    _cloudPending = false;
    ++_generation; // 同时取消尚在等待麦克风权限的启动操作。
    _pauseRequested = true;
    await pause();
    if (_nativeLive) {
      await recorder.stop();
      _nativeLive = false;
      await _persist();
    }
    _cloudTimer?.cancel();
    _liveTimer?.cancel();
    _riskTimer?.cancel();
    _cloudRetryTimer?.cancel();
    _cloudPending = false;
    record = null;
    _liveIdentity.clear();
    _audioUploadError = null;
    for (final timer in _audioRetries.values) {
      timer.cancel();
    }
    _audioRetries.clear();
    phase = MeetingPhase.ready;
    partial = '';
    waveform.clear();
    _base = Duration.zero;
    _clock = Stopwatch();
    cloudAnalyzing = false;
    cloudAnalyzed = false;
    _checkingAnalysis = false;
    _analysisConfigured = null;
    notifications.clearMeetingNotices();
    _emit();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached ||
        state == AppLifecycleState.hidden) {
      if (state != AppLifecycleState.detached &&
          recorder is BackgroundRecordingStatus &&
          (recorder as BackgroundRecordingStatus).backgroundActive &&
          _nativeLive) {
        return;
      }
      _pauseRequested = true;
      unawaited(pause());
    } else if (state == AppLifecycleState.resumed) {
      _pauseRequested = false;
    }
  }

  Future<void> loadHistory() async {
    loading = true;
    _emit();
    try {
      final saved = await _readHistory();
      saved.sort((a, b) => b.startedAt.compareTo(a.startedAt));
      if (_disposed) return;
      history
        ..clear()
        ..addAll(saved);
    } catch (_) {
      if (!_disposed) error = '会议历史读取失败，请重试';
    } finally {
      if (!_disposed) {
        loading = false;
        _emit();
      }
    }
  }

  /// Resolve one meeting without replacing an active recording session.
  Future<MeetingRecord?> readMeeting(String id) async {
    final owner = remote?.accountId;
    final existing = record?.id == id && record?.ownerId == owner
        ? record
        : history.where((r) => r.id == id && r.ownerId == owner).firstOrNull;
    if (existing != null) return existing;
    await loadHistory();
    if (_disposed || remote?.accountId != owner) return null;
    final cached = history
        .where((r) => r.id == id && r.ownerId == owner)
        .firstOrNull;
    if (cached != null) return cached;
    final reader = remote;
    if (reader is! MeetingRecordReader ||
        _deletedRecords.contains('$owner:$id')) {
      return null;
    }
    final restored = await (reader as MeetingRecordReader).readMeeting(id);
    if (_disposed || remote?.accountId != owner) return null;
    if (restored.id != id || restored.ownerId != owner) {
      throw const ApiFailure('会议记录不匹配，请重新加载');
    }
    await store.save(restored);
    if (_disposed || remote?.accountId != owner) return null;
    history.removeWhere((r) => r.id == id);
    history.add(restored);
    _emit();
    return restored;
  }

  Future<void> _forgetDeleted(MeetingRecord source) async {
    await questions.forget(source);
    final key = '${source.ownerId ?? ''}:${source.id}';
    _deletedRecords.add(key);
    _deletedRecords.add('${source.ownerId}:${source.id}');
    _audioRetries.remove('${source.ownerId}:${source.id}')?.cancel();
    if (record?.id == source.id && record?.ownerId == source.ownerId) {
      ++_cloudGeneration;
      ++_generation;
      _cloudTimer?.cancel();
      _cloudRetryTimer?.cancel();
      _liveTimer?.cancel();
      _riskTimer?.cancel();
      _persistTimer?.cancel();
      _valueTimer?.cancel();
      _valueCooldown?.cancel();
      _polishDelay?.cancel();
      _polishQueue.clear();
      _cloudPending = false;
      record = null;
      phase = MeetingPhase.ready;
      partial = '';
      _base = Duration.zero;
      _clock = Stopwatch();
      cloudAnalyzing = false;
      cloudAnalyzed = false;
      notifications.clearMeetingNotices();
    }
    await store.delete(source.id, ownerId: source.ownerId);
    history.removeWhere(
      (r) => r.id == source.id && r.ownerId == source.ownerId,
    );
    if (!_disposed) _emit();
  }

  Future<void> deleteMeetingRecord(MeetingRecord source) async {
    final selected =
        record?.id == source.id && record?.ownerId == source.ownerId
        ? record!
        : source;
    if (!selected.ended || (record?.id == source.id && (active || busy))) {
      throw const ApiFailure('会议仍在录音，请先结束会议');
    }
    if (selected.ownerId != null) {
      if (selected.ownerId != remote?.accountId ||
          remote is! MeetingDeletionRemote) {
        throw const ApiFailure('当前账户无法删除这场会议');
      }
      await (remote as MeetingDeletionRemote).deleteMeeting(selected);
      if (selected.ownerId != remote?.accountId) {
        throw const ApiFailure('账户已切换');
      }
    }
    await _forgetDeleted(selected);
    if (selected.ownerId == null) {
      final documentId = selected.documentId ?? 'meeting-${selected.id}';
      if (knowledge.document(documentId) != null) {
        await knowledge.delete(documentId);
      }
    } else {
      // The server transaction already removed only this meeting's generated documents.
      await knowledge.load();
    }
    await onProgressChanged?.call();
  }

  Future<void> open([String? id]) async {
    if (record?.ownerId != null && record!.ownerId != remote?.accountId) {
      await suspendForLogout();
    }
    if (active || busy) return;
    final openingGeneration = _generation;
    loading = true;
    _emit();
    try {
      final saved = await _readHistory();
      if (_disposed || openingGeneration != _generation || active || busy) {
        return;
      }
      history
        ..clear()
        ..addAll(saved);
      final selected = id == null
          ? (saved.isEmpty ? null : saved.first)
          : saved.where((r) => r.id == id).firstOrNull;
      if (id != null && selected == null) {
        error = '会议记录不存在';
      }
      if (selected != null) {
        _liveIdentity.clear();
        record = selected;
        await _refreshSpeakerIdentities();
        unawaited(questions.load(selected).catchError((Object _) {}));
        _audioUploadError = null;
        _queueCloudAudio(selected);
        _speakerLabels.clear();
        for (final u in selected.utterances.where(
          (u) => u.speakerSeparated && u.speakerId != null,
        )) {
          _speakerLabels[u.speakerId!] = u.speaker;
        }
        _base = selected.elapsed;
        _clock = Stopwatch();
        _demoIndex = selected.utterances
            .where((u) => u.id.startsWith('demo-'))
            .length;
        _demoChars = 0;
        partial = '';
        phase = selected.ended ? MeetingPhase.ended : MeetingPhase.paused;
        // 恢复历史记录时不自动打开麦克风。
        if (selected.ended &&
            selected.canGenerateMinutes &&
            record!.cloudMinutes == null &&
            selected.ownerId != null &&
            selected.ownerId == remote?.accountId) {
          final archive = await remote!.readArchive(selected);
          if (!_disposed &&
              record?.id == selected.id &&
              remote?.accountId == selected.ownerId &&
              archive != null) {
            if (knowledge.loading) await knowledge.load();
            if (_disposed ||
                record?.id != selected.id ||
                remote?.accountId != selected.ownerId) {
              return;
            }
            final id = await knowledge.archiveMeeting(
              meetingId: selected.id,
              ownerUserId: selected.ownerId,
              title: archive['title'] as String,
              content: archive['markdown'] as String,
              demo: false,
              refreshExisting: true,
            );
            if (id != null) {
              record = record!.copy(
                title: archive['meetingTitle'] as String? ?? record!.title,
                cloudMinutes: archive['markdown'] as String,
                speakerIdentities: archive['speakerIdentities'] is Map
                    ? Map<String, dynamic>.from(archive['speakerIdentities'])
                    : null,
                speakerIdentityRevision:
                    archive['speakerIdentityRevision'] as int?,
                minutesDetails: archive['details'] is Map
                    ? Map<String, dynamic>.from(archive['details'])
                    : null,
                documentId: id,
              );
              await store.save(record!);
            }
          }
        }
        if (!selected.ended || record?.cloudMinutes == null) _scheduleCloud();
      }
    } catch (_) {
      if (!_disposed) error = '会议记录读取失败，请重试';
    } finally {
      if (!_disposed) {
        loading = false;
        _emit();
      }
    }
  }

  Future<void> start({required bool demo}) async {
    _polishDelay?.cancel();
    _polishDelay = null;
    if (busy || active) return;
    _valueTimer?.cancel();
    _valueTimer = null;
    _valueCooldown?.cancel();
    _valueCooldown = null;
    _valueSeen.clear();
    _turnTimer?.cancel();
    _turnFragments.clear();
    _speechActivity.reset();
    _turnSpeaker = null;
    _turnId = null;
    _pauseRequested = false;
    busy = true;
    error = null;
    storageError = null;
    _emit();
    final generation = ++_generation;
    final next = MeetingRecord(
      cloudAudioEnabled: !demo,
      id: knowledgeId(),
      startedAt: DateTime.now(),
      demo: demo,
      ownerId: demo ? null : remote?.accountId,
    );
    try {
      String? path;
      if (!demo) {
        _preparingTranscript = true;
        _pendingTranscripts.clear();
        // 优先创建服务端会议；暂时离线也必须允许录音，身份保存由后端重试。
        if (remote is MeetingSpeakerIdentityRemote && next.ownerId != null) {
          try {
            await remote!
                .sync(next, paused: false)
                .timeout(const Duration(seconds: 2));
          } catch (_) {
            // 后续原有证据同步会重试，不能让身份扩展阻止本机采音。
          }
        }
        _listenTranscript();
        path = await recorder.start(next.id);
        _captureTimeline = Duration.zero;
        _nativeLive = true;
      }
      if (_disposed || generation != _generation) {
        if (_nativeLive) await recorder.stop();
        _nativeLive = false;
        _preparingTranscript = false;
        _pendingTranscripts.clear();
        return;
      }
      _identitySyncFailed = false;
      record = next.copy(audioPaths: path == null ? [] : [path]);
      cloudAnalyzed = false;
      cloudAnalyzing = false;
      _lastAnalyzedFacts = null;
      cloudError = null;
      _audioUploadError = null;
      waveform.clear();
      _speakerLabels.clear();
      partial = '';
      _demoIndex = demo ? 12 : 0;
      _demoChars = 0;
      if (demo) {
        record = record!.copy(
          utterances: [
            for (var i = 0; i < 12; i++)
              meetingDemoUtterance(
                i,
                Duration(seconds: i * 18),
                availableThrough: 12,
              ),
          ],
        );
        unawaited(_analyze(announce: false));
      }
      _base = demo ? const Duration(minutes: 3, seconds: 30) : Duration.zero;
      _clock = Stopwatch()..start();
      phase = MeetingPhase.recording;
      if (demo) {
        home.startDemo();
      } else {
        home.startMeeting();
      }
      if (!demo) {
        _preparingTranscript = false;
        for (final event in List<MeetingTranscript>.of(_pendingTranscripts)) {
          _handleTranscript(event);
        }
        _pendingTranscripts.clear();
        await _states?.cancel();
        _states = recorder.states.listen((state) {
          if (!_disposed && state == 'transcription_pending') {
            error = '网络转写中断，录音继续保存在本机，网络恢复后自动补转写';
            _emit();
            return;
          }
          if (!_disposed && state == 'transcription_restored') {
            if (error?.startsWith('网络转写中断') == true) error = null;
            _emit();
            return;
          }
          if (!_disposed &&
              (state == 'input_route' || state == 'capture_stopped')) {
            _emit();
            return;
          }
          if (!_disposed && state == 'input_lost') {
            _nativeLive = false;
            _clock.stop();
            phase = MeetingPhase.paused;
            error = '采音设备已断开或被占用，录音已暂停，请重新连接后继续';
            unawaited(_persist());
            _emit();
            return;
          }
          if (_disposed ||
              busy ||
              phase != MeetingPhase.recording ||
              state == 'record') {
            return;
          }
          if (state == 'pause' || state == 'stop') {
            if (state == 'stop') _nativeLive = false;
            _clock.stop();
            phase = MeetingPhase.paused;
            error = '录音已被系统暂停，点击继续恢复';
            unawaited(_persist());
            _emit();
          }
        });
        await _levels?.cancel();
        _levels = recorder.levels.listen(
          (value) {
            if (_disposed || phase != MeetingPhase.recording) return;
            waveform.add(value);
            if (_speechActivity.observe(value)) {
              _armTurnEnd(fromAudio: true);
            }
            if (waveform.length > 72) waveform.removeAt(0);
            _emit();
          },
          onError: (Object _) {
            error = '采音异常，请检查设备后恢复录音';
            unawaited(pause());
          },
        );
      }
      _runTimers();
      if (!record!.demo) unawaited(_checkAnalysisConnection());
      await _persist();
    } catch (e) {
      _preparingTranscript = false;
      _pendingTranscripts.clear();
      unawaited(_transcripts?.cancel());
      if (!_disposed) {
        error = demo
            ? '演示启动失败'
            : e is StateError
            ? e.message.toString()
            : '录音与本地转写启动失败，请重试';
      }
    } finally {
      if (!_disposed) {
        busy = false;
        _emit();
        if (_pauseRequested) unawaited(pause());
      }
    }
  }

  void _listenTranscript() {
    _liveIdentity.clear();
    for (final u in record?.utterances ?? <MeetingUtterance>[]) {
      if (u.speakerSeparated && u.speakerId != null) {
        _speakerLabels[u.speakerId!] = u.speaker;
      }
    }
    _captureId = DateTime.now().microsecondsSinceEpoch.toString();
    unawaited(_transcripts?.cancel());
    _transcripts = recorder.transcripts.listen(
      (event) {
        if (_preparingTranscript) {
          _pendingTranscripts.add(event);
        } else {
          _handleTranscript(event);
        }
      },
      onError: (Object _) {
        if (_disposed) return;
        error = '录音或转写出现异常，原始录音已保留';
        _emit();
        if (phase == MeetingPhase.recording && !busy) unawaited(pause());
      },
    );
  }

  void _handleTranscript(MeetingTranscript event) {
    if (event.identityEvent case final identity?) {
      if (!_disposed &&
          record != null &&
          !record!.demo &&
          !record!.ended &&
          _liveIdentity.accept(identity)) {
        if (identity.isSession) unawaited(_refreshSpeakerIdentities());
        if (identity.speakerId != null && identity.identity != null) {
          _identitySyncFailed =
              remote is MeetingSpeakerIdentityRemote && !identity.persisted;
          if (identity.persisted &&
              identity.meetingRevision >= record!.speakerIdentityRevision) {
            record = record!.copy(
              speakerIdentityRevision: identity.meetingRevision,
              speakerIdentities: {
                ...record!.speakerIdentities,
                identity.speakerId!: {
                  'identity': identity.identity,
                  'source': 'voiceprint',
                },
              },
            );
            unawaited(store.save(record!));
          }
        }
        _emit();
      }
      return;
    }
    if (event.highlightBatch case final batch?) {
      if (_disposed || record == null || record!.demo) return;
      final id = 'asr-$_captureId-${event.segment}';
      final source = record!.utterances.where((u) => u.id == id).firstOrNull;
      if (source != null && source.raw == batch.raw) {
        transcriptHighlights.accept(id, source.raw, batch);
        record = record!.copy(
          transcriptHighlights: {
            ...record!.transcriptHighlights,
            id: batch.toJson(),
          },
        );
        // 注释只保存本机展示副本，不触发业务同步、多Agent或纪要重生成。
        unawaited(
          store.save(record!).catchError((Object _) {
            if (!_disposed) {
              storageError = '重点标注保存失败，请保留会议记录后重试';
              _emit();
            }
          }),
        );
      }
      return;
    }
    if (_disposed || record == null || record!.demo || !active) return;
    // 聚类只得到本场匿名标签，不查询任何平台账号，也不把声源当成决定权限。
    final separated = event.speakerSeparated && event.speakerId != null;
    final speakerId = separated ? event.speakerId! : 'unseparated';
    final speaker = separated
        ? _speakerLabels.putIfAbsent(speakerId, () {
            var i = 0;
            while (_speakerLabels.containsValue(
              '发言人 ${i < 26 ? String.fromCharCode(65 + i) : i + 1}',
            )) {
              i++;
            }
            return '发言人 ${i < 26 ? String.fromCharCode(65 + i) : i + 1}';
          })
        : '待区分发言人';
    final id = 'asr-$_captureId-${event.segment}';
    if (event.isSpeakerUpdate) {
      final existing = record!.utterances.where((u) => u.id == id).firstOrNull;
      if (existing != null &&
          event.speakerRevision > existing.speakerRevision) {
        final revised = existing.revise(
          speaker: speaker,
          speakerId: speakerId,
          speakerSeparated: separated,
          speakerRevision: event.speakerRevision,
          clearRepair: true,
          speakerHistory: [
            ...existing.speakerHistory,
            {
              'revision': event.speakerRevision,
              'speaker': speaker,
              'speakerId': speakerId,
              'speakerSeparated': separated,
            },
          ],
        );
        record = record!.copy(
          utterances: [
            for (final u in record!.utterances) u.id == id ? revised : u,
          ],
        );
        _invalidateInferenceSource(id);
        unawaited(_persist());
        _emit();
      }
      return;
    }
    // 重复稳态通知或空中间态不能清除当前字幕或重新阻塞已结束的发言。
    if (record!.utterances.any((u) => u.id == id) ||
        event.text.trim().isEmpty) {
      return;
    }
    _turnInputVersion++;
    final last = record!.utterances
        .where((u) => _turnId != null && u.turnId == _turnId)
        .lastOrNull;
    if (last?.audioEnd != null &&
        event.audioStart != null &&
        event.audioStart! >= last!.audioEnd!) {
      final silence = event.audioStart! - last.audioEnd!;
      final needed = remote is SemanticMeetingTurn
          ? turnQuiet + unfinishedQuiet
          : isUnfinishedSpeech(_turnText)
          ? unfinishedQuiet
          : turnQuiet;
      // 补传音频以录音时间轴收尾，不能被此刻正在说话的麦克风波形拖住。
      if (silence >= needed) _closeTurn();
    }
    if (separated &&
        _turnSpeaker != null &&
        _turnSpeaker != 'unseparated' &&
        _turnSpeaker != speakerId) {
      // 正常交接不是打断；只有未说完的原话或临时字幕才保留中断状态。
      _closeTurn(
        interruptedBySpeaker:
            (partial.isNotEmpty && _partialSpeakerId == _turnSpeaker) ||
            isUnfinishedSpeech(_turnText),
        // 身份未知的中间字幕可能已经属于 B，不能据此把完整的 A 判为被打断。
        ignorePartial: true,
      );
    }
    // 腾讯云中间字幕可能尚无话者标识；缺失身份不是另一人开口。
    // 保留轮次边界判断使用的已知话者，但当前字幕仍显示“待区分”，不猜身份。
    if (separated || _turnSpeaker == null) _turnSpeaker = speakerId;
    _turnId ??= id;
    _turnTimer?.cancel();
    if (event.isFinal) {
      if (event.text.trim().isNotEmpty &&
          !record!.utterances.any((u) => u.id == id)) {
        final item = MeetingUtterance(
          id: id,
          speaker: speaker,
          speakerId: speakerId,
          speakerSeparated: separated,
          speakerRevision: event.speakerRevision,
          speakerHistory: [
            {
              'revision': event.speakerRevision,
              'speaker': speaker,
              'speakerId': speakerId,
              'speakerSeparated': separated,
            },
          ],
          raw: event.text,
          turnStatus: 'pending',
          turnId: _turnId,
          cleaned: tidySpeech(event.text),
          audioPath: record!.audioPaths.lastOrNull,
          audioStart: event.audioStart,
          audioEnd: event.audioEnd,
          at: event.audioEnd == null
              ? elapsed
              : _captureTimeline + event.audioEnd!,
        );
        record = record!.copy(utterances: [...record!.utterances, item]);
        _turnFragments.add(item.id);
        unawaited(_persist());
      }
      partial = '';
      _partialSpeakerId = null;
      _scheduleValueCheckpoint();
      _armTurnEnd();
    } else {
      _partialSpeakerId = separated ? speakerId : null;
      partialSpeaker = speaker;
      partial = event.text;
    }
    _emit();
  }

  void _runTimers() {
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (phase == MeetingPhase.recording) {
        _emit();
      }
    });
    _persistTimer?.cancel();
    _persistTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => unawaited(_persist()),
    );
    _demoTimer?.cancel();
    if (record?.demo == true) {
      _demoTimer = Timer.periodic(
        const Duration(milliseconds: 160),
        (_) => _demoStep(),
      );
    }
  }

  void _demoStep() {
    if (_disposed ||
        phase != MeetingPhase.recording ||
        _demoIndex >= meetingDemoTurns.length) {
      return;
    }
    final (speaker, text, _) = meetingDemoTurns[_demoIndex];
    partialSpeaker = speaker;
    _demoChars = (_demoChars + 2).clamp(0, text.length);
    partial = text.substring(0, _demoChars);
    if (_demoChars == text.length) {
      final item = meetingDemoUtterance(_demoIndex, elapsed);
      record = record!.copy(utterances: [...record!.utterances, item]);
      if (_demoIndex == 4) {
        record = record!.copy(
          utterances: record!.utterances
              .map((u) => u.id == 'demo-4' ? u.revise(withdrawn: true) : u)
              .toList(),
        );
      }
      _demoIndex++;
      _demoChars = 0;
      partial = '';
      unawaited(_analyze());
      unawaited(_persist());
    }
    _emit();
  }

  Future<void> _analyze({bool announce = true}) async {
    final source = record;
    if (source == null || !source.demo) return;
    final revision = ++_analysisRevision;
    try {
      final results = await analysis.analyze(source.utterances);
      if (_disposed ||
          record?.id != source.id ||
          revision != _analysisRevision) {
        return;
      }
      final ids = source.utterances.map((u) => u.id).toSet();
      final valid = results
          .where(
            (i) =>
                i.evidenceIds.isNotEmpty && i.evidenceIds.every(ids.contains),
          )
          .toList();
      final previous = record!.insights.map((i) => i.id).toSet();
      record = record!.copy(insights: valid);
      for (final insight in valid.where(
        (i) =>
            announce && i.kind == InsightKind.risk && !previous.contains(i.id),
      )) {
        notifications.receive(
          ActionNotice(
            id: 'meeting:${source.id}:${insight.id}',
            title: '演示预警：${insight.title}',
            kind: NoticeKind.warning,
            instruction: '核对范围与工期，继续沟通前明确约束。',
            allowLabel: '知道了',
          ),
          onAllow: () async => true,
        );
      }
      _emit();
    } catch (_) {
      if (!_disposed) {
        error = '演示分析暂不可用，原始记录已保留';
        _emit();
      }
    }
  }

  Future<void> pause() async {
    if (busy || phase != MeetingPhase.recording) return;
    busy = true;
    _emit();
    try {
      _clock.stop();
      if (_nativeLive) await recorder.pause();
      _closeTurn();
      phase = MeetingPhase.paused;
      await _persist();
    } catch (_) {
      error = '暂停失败，请重试';
    } finally {
      busy = false;
      _emit();
    }
  }

  Future<void> resume() async {
    if (busy || phase != MeetingPhase.paused || record == null) return;
    busy = true;
    error = null;
    _emit();
    final generation = _generation;
    final sourceId = record!.id;
    try {
      if (!record!.demo) {
        if (_nativeLive) {
          await recorder.resume();
        } else {
          _preparingTranscript = true;
          _pendingTranscripts.clear();
          _listenTranscript();
          _captureTimeline = elapsed;
          final path = await recorder.start(record!.id);
          if (_disposed ||
              generation != _generation ||
              record?.id != sourceId) {
            await recorder.stop();
            _preparingTranscript = false;
            _pendingTranscripts.clear();
            return;
          }
          _nativeLive = true;
          record = record!.copy(audioPaths: [...record!.audioPaths, path]);
          _preparingTranscript = false;
          for (final event in List<MeetingTranscript>.of(_pendingTranscripts)) {
            _handleTranscript(event);
          }
          _pendingTranscripts.clear();
          await _levels?.cancel();
          _levels = recorder.levels.listen((value) {
            if (_disposed || phase != MeetingPhase.recording) return;
            waveform.add(value);
            if (_speechActivity.observe(value)) {
              _armTurnEnd(fromAudio: true);
            }
            if (waveform.length > 72) waveform.removeAt(0);
            _emit();
          });
        }
      }
      if (_disposed || generation != _generation || record?.id != sourceId) {
        return;
      }
      _clock.start();
      phase = MeetingPhase.recording;
      if (record!.demo) {
        home.startDemo();
      } else {
        home.startMeeting();
      }
      _runTimers();
      if (!record!.demo) unawaited(_checkAnalysisConnection());
      await _persist();
    } catch (_) {
      _preparingTranscript = false;
      _pendingTranscripts.clear();
      error = '恢复录音失败，请检查权限后重试';
    } finally {
      busy = false;
      _emit();
    }
  }

  Future<bool> finish() async {
    if (busy || record == null) return false;
    // Hardware can repeat the saved/idle callback after the first stop.
    // A completed session must not start archive work or progress UI again.
    if (record!.ended &&
        storageError == null &&
        error == null &&
        (!record!.canGenerateMinutes ||
            record!.documentId != null ||
            record!.offlineSyncHeld)) {
      return true;
    }
    busy = true;
    ++_analysisRevision;
    error = null;
    _emit();
    try {
      _clock.stop();
      if (_nativeLive) {
        await recorder.stop();
        _nativeLive = false;
      }
      _clock.stop();
      _ticker?.cancel();
      _closeTurn();
      _demoTimer?.cancel();
      _persistTimer?.cancel();
      // 临时识别结果不直接冒充已确认原话；尾句由录音器刷尾返回。
      await _refreshSpeakerIdentities();
      phase = MeetingPhase.ended;
      _liveIdentity.clear();
      partial = '';
      final hold =
          record!.offlineSyncHeld &&
          !record!.demo &&
          audioRecovery != null &&
          await audioRecovery!.hasPending(record!);
      record = record!.copy(
        ended: true,
        elapsed: elapsed,
        offlineSyncHeld: hold,
      );
      if (hold) {
        _evidenceTimer?.cancel();
        _cloudTimer?.cancel();
        _cloudGeneration++;
        _businessPendingSource = null;
      }
      _emit(); // End system recording UI before potentially slow minutes/knowledge work.
      home.endDemo();
      await _persist();
      if (storageError != null) return false;
      if (!record!.demo &&
          audioRecovery != null &&
          await audioRecovery!.hasPending(record!)) {
        record = record!.copy(recoveryPendingSync: true, offlineSyncHeld: hold);
        await store.save(record!);
        error = hold ? '录音已保存在本机，可在离线录音中选择同步' : null;
        return true;
      }
      if (!record!.canGenerateMinutes) return true;
      if (knowledge.loading) await knowledge.load();
      final id = await knowledge.archiveMeeting(
        meetingId: record!.id,
        ownerUserId: record!.ownerId,
        title:
            '${record!.demo ? '演示 · ' : ''}会议纪要 ${knowledgeDate(record!.startedAt)} ${record!.startedAt.hour}:${record!.startedAt.minute.toString().padLeft(2, '0')}',
        content: minutes(),
        demo: record!.demo,
      );
      if (id == null) {
        error = '录音已保留，纪要归档失败，请重试';
        return false;
      }
      record = record!.copy(documentId: id);
      await _persist();
      return storageError == null;
    } catch (_) {
      error = '结束未完成，原记录保留，请重试';
      return false;
    } finally {
      busy = false;
      _emit();
      if (record?.ended == true &&
          record?.recoveryPendingSync == true &&
          record?.offlineSyncHeld != true) {
        unawaited(recoverAudio());
      }
    }
  }

  Future<void> addManual(String speaker, String text) async {
    if (record == null || phase == MeetingPhase.ended || text.trim().isEmpty) {
      return;
    }
    final item = MeetingUtterance(
      id: knowledgeId(),
      speaker: speaker.trim().isEmpty ? '待确认发言人' : speaker.trim(),
      raw: text.trim(),
      cleaned: tidySpeech(text),
      at: elapsed,
      manual: true,
    );
    record = record!.copy(utterances: [...record!.utterances, item]);
    await _persist();
    _emit();
    _proposeCalendar(item);
  }

  void _proposeCalendar(MeetingUtterance item) {
    // 正式会议由服务端规划及全局通知执行，不能并行触发旧的本地编辑页。
    if (remote != null && record?.demo == false) return;
    final date = explicitMeetingDate(item.raw, DateTime.now());
    if (date != null && record?.demo == false) {
      notifications.receive(
        ActionNotice(
          id: 'meeting-calendar:${record!.id}:${item.id}',
          title: '将会议安排加入日历',
          instruction:
              '${knowledgeDate(date)} ${date.hour}:${date.minute.toString().padLeft(2, '0')}，打开系统日历核对后保存。',
          allowLabel: '打开日历',
        ),
        onAllow: () => calendar.openEditor(item.display, date),
      );
    }
  }

  void _invalidateInferenceSource(String id) {
    if (record == null) return;
    record = record!.copy(
      insights: record!.insights
          .where((i) => !i.evidenceIds.contains(id))
          .toList(),
      utterances: [
        for (final u in record!.utterances)
          (u.repair?.evidenceIds.contains(id) ?? false)
              ? u.revise(clearRepair: true)
              : u,
      ],
      sourceChanges: record!.sourceChanges
          .where(
            (c) =>
                c['status'] == 'confirmed' ||
                !(c['evidence_ids'] as List? ?? []).contains(id),
          )
          .toList(),
    );
  }

  Future<void> correct(String id, String text) async {
    if (record == null || record!.ended || text.trim().isEmpty) return;
    record = record!.copy(
      utterances: record!.utterances
          .map((u) => u.id == id ? u.revise(correction: text.trim()) : u)
          .toList(),
    );
    _invalidateInferenceSource(id);
    await _persist();
    _emit();
  }

  Future<void> retract(String id) async {
    if (record == null || record!.ended) return;
    record = record!.copy(
      utterances: record!.utterances
          .map((u) => u.id == id ? u.revise(withdrawn: !u.withdrawn) : u)
          .toList(),
    );
    _invalidateInferenceSource(id);
    await _persist();
    _emit();
  }

  Future<void> _persist() async {
    if (record == null || _disposed) return;
    record = record!.copy(elapsed: elapsed);
    try {
      final snapshot = record!;
      final device = recorder is DeviceMeetingRecorder
          ? recorder as DeviceMeetingRecorder
          : null;
      final revision = device?.persistenceRevision;
      await store.save(snapshot);
      unawaited(questions.associate(snapshot).catchError((Object _) {}));
      if (revision != null) await device!.confirmPersisted(snapshot, revision);
      if (!_disposed) storageError = null;
      _scheduleCloud();
    } catch (_) {
      if (!_disposed) {
        storageError = '本地保存失败，请保留此页面并重试';
        _emit();
      }
    }
  }

  String minutes() {
    final r = record!;
    if (r.cloudMinutes != null) return r.cloudMinutes!;
    final out = StringBuffer('# ${r.demo ? '演示会议纪要' : '会议纪要'}\n\n');
    out.writeln(
      '开始：${r.startedAt.toIso8601String()}\n时长：${meetingTime(elapsed)}\n',
    );
    out.writeln(
      r.demo
          ? '> 演示场景，不是真实录音、转写或 AI 推演。\n'
          : '> 本地会议记录。语音识别可能有误，请核对原录音；手工补录单独标注。AI 建议与原始记录分别保留。\n',
    );
    out.writeln('## 当前记录\n');
    for (final u in r.utterances) {
      out.writeln(
        '- ${meetingTime(u.at)} ${r.speakerDisplayName(u)}：${u.withdrawn ? '~~${u.display}~~（已撤回）' : u.display}${u.manual ? '（手工补录）' : ''}',
      );
    }
    if (r.utterances.isEmpty) out.writeln('未提供转写，须以保存的原始录音为准。');
    out.writeln('\n## 原始片段（保留不改写）\n');
    for (final u in r.utterances) {
      out.writeln(
        '- [${u.id}] ${meetingTime(u.at)} ${r.speakerDisplayName(u)}：${u.raw}',
      );
    }
    out.writeln('\n## 记忆拼贴（推测补齐，未确认）\n');
    for (final u in r.utterances.where((u) => u.repair != null)) {
      out.writeln(
        '- [${u.id}] 原句缺口：${u.raw}；推测补齐：${u.repair!.text}；参考片段：${u.repair!.evidenceIds.join('、')}。',
      );
    }
    out.writeln('\n## 待核对提示与推测\n');
    for (final i in r.insights) {
      out.writeln(
        '- ${i.title}（${i.inference ? '推测，未确认' : '待核对'}）：${i.body} 来源：${i.evidenceIds.join('、')}',
      );
    }
    if (r.insights.isEmpty) out.writeln('未生成 AI 分析。');
    return out.toString();
  }

  void _emit() {
    if (_disposed) return;
    _prepareCompletions();
    final current = record;
    if (current != null &&
        (!identical(current.utterances, _memoryWorkflowSources) ||
            !identical(current.insights, _memoryWorkflowInsights) ||
            current.id != _memoryWorkflowRecordId)) {
      // 只在证据或分析变更时清理旧等待卡；波形与计时刷新不重复扫描。
      record = projectMemoryWorkflow(current);
      _memoryWorkflowSources = record!.utterances;
      _memoryWorkflowInsights = record!.insights;
      _memoryWorkflowRecordId = record!.id;
    }
    notifyListeners();
  }

  @override
  void dispose() {
    questions.dispose();
    transcriptHighlights.dispose();
    for (final timer in _audioRetries.values) {
      timer.cancel();
    }
    _audioRetries.clear();
    _completionReadRetry?.cancel();
    _polishDelay?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _disposed = true;
    _turnTimer?.cancel();
    _valueTimer?.cancel();
    _valueCooldown?.cancel();
    _recoveryTimer?.cancel();
    _evidenceTimer?.cancel();
    ++_cloudGeneration;
    _cloudTimer?.cancel();
    _liveTimer?.cancel();
    _riskTimer?.cancel();
    _cloudRetryTimer?.cancel();
    ++_generation;
    ++_analysisRevision;
    _ticker?.cancel();
    _demoTimer?.cancel();
    _persistTimer?.cancel();
    _clock.stop();
    unawaited(_levels?.cancel());
    unawaited(_states?.cancel());
    unawaited(_transcripts?.cancel());
    unawaited(recorder.dispose());
    super.dispose();
  }

  Future<List<MeetingRecord>> _readHistory() async {
    final owner = remote?.accountId;
    final local = await store.read();
    if (owner == null) return local.where((r) => r.ownerId == null).toList();
    final records = {
      for (final r in local.where((r) => r.ownerId == owner)) r.id: r,
    };
    try {
      final cloud = await remote!.history();
      if (_disposed || remote?.accountId != owner) return [];
      if (remote is MeetingDeletionRemote) {
        final deleted = await (remote as MeetingDeletionRemote)
            .deletedMeetingIds();
        if (_disposed || remote?.accountId != owner) return [];
        for (final id in deleted) {
          _deletedRecords.add('$owner:$id');
          await store.delete(id, ownerId: owner);
          records.remove(id);
        }
      }
      for (final row in cloud) {
        if (_deletedRecords.contains('$owner:${row.id}')) continue;
        // 本机记录保留其音频、人工修改和未上传的修订；其他设备的会议可只读恢复。
        if (!records.containsKey(row.id)) {
          records[row.id] = row;
          await store.save(row);
        } else if (row.speakerIdentityRevision >=
            records[row.id]!.speakerIdentityRevision) {
          final merged = records[row.id]!.copy(
            speakerIdentities: row.speakerIdentities,
            speakerIdentityRevision: row.speakerIdentityRevision,
            clearCloudMinutes:
                row.speakerIdentityRevision !=
                records[row.id]!.speakerIdentityRevision,
          );
          records[row.id] = merged;
          await store.save(merged);
        }
      }
    } catch (_) {
      cloudError = '云端历史暂不可用，本地记录已保留';
    }
    final result =
        records.values
            .where(
              (r) => !_deletedRecords.contains('${r.ownerId ?? ''}:${r.id}'),
            )
            .toList()
          ..sort((a, b) => b.startedAt.compareTo(a.startedAt));
    unawaited(questions.resumePending(result));
    return result;
  }

  List<MeetingUtterance>? _signatureInput, _factsInput;
  String? _signatureRecord, _signaturePhase, _signatureValue, _factsValue;
  bool? _signatureEnded;
  Duration? _signatureFinalElapsed;
  String _cloudSignature() {
    final source = record;
    if (_signatureRecord != source?.id ||
        _signaturePhase != phase.name ||
        _signatureEnded != source?.ended ||
        _signatureFinalElapsed !=
            (source?.ended == true ? source?.elapsed : null) ||
        !identical(_signatureInput, source?.utterances)) {
      _signatureInput = source?.utterances;
      _signatureRecord = source?.id;
      _signaturePhase = phase.name;
      _signatureEnded = source?.ended;
      _signatureFinalElapsed = source?.ended == true ? source?.elapsed : null;
      _signatureValue = _buildCloudSignature();
    }
    return _signatureValue ?? '';
  }

  String _meetingFacts() {
    if (_factsValue == null || !identical(_factsInput, record?.utterances)) {
      _factsInput = record?.utterances;
      _factsValue = _buildMeetingFacts();
    }
    return _factsValue!;
  }

  String _buildCloudSignature() => jsonEncode({
    'id': record?.id,
    'phase': phase.name,
    'ended': record?.ended,
    if (record?.ended == true) 'finalElapsed': record?.elapsed.inMilliseconds,
    'utterances': [
      for (final u in record?.utterances ?? <MeetingUtterance>[])
        [
          u.id,
          u.raw,
          u.turnStatus,
          u.speaker,
          u.speakerId,
          u.speakerSeparated,
          u.speakerRevision,
          u.at.inMilliseconds,
          u.correction,
          u.withdrawn,
          u.manual,
        ],
    ],
  });

  String _buildMeetingFacts() => jsonEncode([
    for (final u in record?.utterances ?? <MeetingUtterance>[])
      if (u.turnStatus != 'pending')
        [
          u.id,
          u.raw,
          u.turnStatus,
          u.speaker,
          u.speakerId,
          u.speakerSeparated,
          u.speakerRevision,
          u.at.inMilliseconds,
          u.correction,
          u.withdrawn,
          u.manual,
        ],
  ]);

  void _scheduleCloud() {
    if (_disposed ||
        record == null ||
        record!.demo ||
        record!.offlineSyncHeld ||
        remote?.accountId == null ||
        record!.ownerId != remote?.accountId) {
      return;
    }
    _scheduleLiveHints();
    _scheduleLiveRisks();
    final signature = _cloudSignature();
    if (signature == _cloudObserved) return;
    if (remote is RealtimeMeetingBusiness) {
      _evidenceTimer ??= Timer(const Duration(milliseconds: 500), () {
        _evidenceTimer = null;
        unawaited(_uploadEvidence().catchError((_) => null));
      });
    }
    _cloudObserved = signature;
    _cloudPending = true;
    // 固定批次节流，不能每来一句都重置等待，否则连续讲话永远不分析。
    if (_cloudTimer?.isActive == true) return;
    _cloudTimer = Timer(
      remote is LiveMeetingAnalysis && remote is StreamingMeetingAnalysis
          ? const Duration(milliseconds: 300)
          : const Duration(seconds: 3),
      () => unawaited(syncCloud()),
    );
  }

  Future<MeetingRecord?> _uploadEvidence({bool force = false}) async {
    if (record?.offlineSyncHeld == true) return null;
    final running = _evidenceWork;
    if (running != null) {
      await running;
      if (!_disposed &&
          record != null &&
          (force || _evidenceObserved != _cloudSignature())) {
        return _uploadEvidence(force: force);
      }
      return _lastUploaded;
    }
    if (_disposed || record == null || record!.ownerId != remote?.accountId) {
      return null;
    }
    final done = Completer<void>();
    _evidenceWork = done.future;
    final generation = _cloudGeneration;
    try {
      while (!_disposed &&
          record != null &&
          record!.ownerId == remote?.accountId &&
          !record!.offlineSyncHeld &&
          generation == _cloudGeneration) {
        final signature = _cloudSignature();
        if (!force && signature == _evidenceObserved) break;
        force = false;
        final source = record!.copy(
          syncRevision: record!.syncRevision + 1,
          elapsed: elapsed,
        );
        record = source;
        await store.save(source);
        if (_disposed ||
            generation != _cloudGeneration ||
            remote?.accountId != source.ownerId) {
          return null;
        }
        await remote!.sync(source, paused: phase == MeetingPhase.paused);
        if (_disposed ||
            generation != _cloudGeneration ||
            remote?.accountId != source.ownerId) {
          return null;
        }
        _lastUploaded = source;
        _evidenceObserved = signature;
        _queueBusiness(source);
      }
      return _lastUploaded;
    } finally {
      _evidenceWork = null;
      done.complete();
    }
  }

  String _businessSignature(MeetingRecord source) => jsonEncode([
    source.id,
    source.ownerId,
    for (final u in source.utterances.where((u) => u.turnStatus != 'pending'))
      [
        u.id,
        u.raw,
        u.correction,
        u.withdrawn,
        u.turnStatus,
        u.speakerId,
        u.speakerRevision,
      ],
  ]);

  void _queueBusiness(MeetingRecord source) {
    if (remote is! RealtimeMeetingBusiness ||
        source.demo ||
        source.offlineSyncHeld ||
        !source.utterances.any((u) => u.turnStatus != 'pending')) {
      return;
    }
    if (_businessSignature(source) == _businessFacts) return;
    _businessPendingSource = source;
    if (_businessWork == null) unawaited(_drainBusiness());
  }

  Future<void> _drainBusiness() async {
    final done = Completer<void>();
    _businessWork = done.future;
    final generation = _cloudGeneration;
    try {
      while (_businessPendingSource != null &&
          !_disposed &&
          generation == _cloudGeneration) {
        final source = _businessPendingSource!;
        _businessPendingSource = null;
        if (remote?.accountId != source.ownerId || record?.id != source.id) {
          break;
        }
        final signature = _businessSignature(source);
        if (signature == _businessFacts) continue;
        try {
          await (remote as RealtimeMeetingBusiness).updateBusiness(source, (
            event,
          ) {
            if (_disposed ||
                generation != _cloudGeneration ||
                record?.id != source.id ||
                remote?.accountId != source.ownerId ||
                event['business_updated'] != true) {
              return;
            }
            _corePreviewReady = true;
            _analysisConfigured = true;
            // 候选已提交就刷新现有业务区域，不等待后续模型复核完成。
            if (event['review_pending'] == true) {
              unawaited(_refreshBusinessViews(source, generation));
            }
            final report = event['analysis'];
            if (report is Map && _analysisSourceUnchanged(source)) {
              record = applyMeetingAnalysis(
                record!,
                Map<String, dynamic>.from(report),
                preserveInferences: true,
              );
            }
            _emit();
          });
          if (_disposed ||
              generation != _cloudGeneration ||
              record?.id != source.id ||
              remote?.accountId != source.ownerId) {
            break;
          }
          _businessFacts = signature;
          cloudError = null;
          await _refreshBusinessViews(source, generation);
          if (!_disposed &&
              generation == _cloudGeneration &&
              record?.id == source.id &&
              remote?.accountId == source.ownerId) {
            await store.save(record!);
          }
          _emit();
        } catch (_) {
          // 小批次失败不停止收音；新发言、恢复同步及完整分析仍可接续处理。
          if (!_disposed &&
              generation == _cloudGeneration &&
              record?.id == source.id &&
              remote?.accountId == source.ownerId) {
            cloudError = '会中业务更新暂未完成，原话已保存，将继续重试';
            _emit();
          }
        }
      }
    } finally {
      _businessWork = null;
      done.complete();
    }
  }

  Future<void> _refreshBusinessViews(
    MeetingRecord source,
    int generation,
  ) async {
    if (_disposed ||
        generation != _cloudGeneration ||
        record?.id != source.id ||
        remote?.accountId != source.ownerId) {
      return;
    }
    try {
      ++_completionRevision;
      _emit();
      await Future.wait([
        refreshSourceChanges(),
        onProgressChanged?.call() ?? Future<void>.value(),
        _refreshNotices(),
      ]);
    } catch (_) {
      // 刷新失败保留原显示，下一次业务事件继续读取。
    }
  }

  void _scheduleLiveRisks() {
    if (_disposed ||
        remote is! LiveMeetingRiskAnalysis ||
        record == null ||
        record!.demo ||
        record!.ended ||
        record!.ownerId != remote?.accountId ||
        _riskBusy ||
        _riskFacts == _meetingFacts() ||
        _riskTimer?.isActive == true) {
      return;
    }
    // 固定小批次；运行中只记最新事实，不为每句话累加请求。
    _riskTimer = Timer(
      const Duration(milliseconds: 500),
      () => unawaited(_updateLiveRisks()),
    );
  }

  Future<void> _updateLiveRisks() async {
    final source = record;
    final service = remote;
    if (_disposed ||
        _riskBusy ||
        source == null ||
        source.demo ||
        source.ended ||
        source.ownerId != service?.accountId ||
        service is! LiveMeetingRiskAnalysis ||
        !source.utterances.any((u) => u.turnStatus != 'pending')) {
      return;
    }
    final generation = _cloudGeneration, facts = _meetingFacts();
    _riskFacts = facts;
    _riskBusy = true;
    final streamedIds = <String>{};
    bool current() =>
        !_disposed &&
        generation == _cloudGeneration &&
        record?.id == source.id &&
        source.ownerId == remote?.accountId;
    void finishStream() {
      if (!current()) return;
      record = record!.copy(
        insights: [
          for (final i in record!.insights)
            if (i.streaming && streamedIds.contains(i.id))
              MeetingInsight.fromJson({
                ...i.toJson(),
                'streaming': false,
                'interrupted': true,
              })
            else
              i,
        ],
      );
    }

    try {
      await (service as LiveMeetingRiskAnalysis).liveRisks(source, (preview) {
        if (!current() || !_analysisSourceUnchanged(source)) return;
        final projected = applyMeetingAnalysis(record!, {
          'insights': preview['insights'] ?? [],
        }, preserveInferences: true);
        streamedIds.addAll(
          (preview['insights'] is List ? preview['insights'] as List : const [])
              .whereType<Map>()
              .map((i) => i['id'])
              .whereType<String>(),
        );
        record = record!.copy(
          insights: compactMeetingInsights(
            projected.insights,
            record!.utterances,
          ),
        );
        if (preview['event'] == 'done') finishStream();
        if (_previewRows(
          preview['insights'],
        ).any((i) => i['body'] is String && (i['body'] as String).isNotEmpty)) {
          _coreHasContent = true;
          _corePreviewReady = true;
          _analysisConfigured = true;
          _releasePolish();
        }
        _emit();
      });
    } catch (_) {
      // 只收尾本条风险流，不能误结束并行的 AI 补充或完整分析。
      finishStream();
    } finally {
      _riskBusy = false;
      if (current()) {
        _emit();
        await store.save(record!);
        if (facts != _meetingFacts()) _scheduleLiveRisks();
      }
    }
  }

  void _scheduleLiveHints() {
    if (remote is! LiveMeetingAnalysis ||
        record?.ended == true ||
        _disposed ||
        _liveFacts == _meetingFacts() ||
        _liveBusy ||
        _liveTimer?.isActive == true) {
      return;
    }
    _liveTimer = Timer(
      const Duration(milliseconds: 500),
      () => unawaited(_updateLiveHints()),
    );
  }

  Future<void> refreshSourceChanges() async {
    final service = remote;
    final source = record;
    if (service is! MeetingChangeReader ||
        source == null ||
        source.demo ||
        source.ownerId != remote?.accountId) {
      return;
    }
    final generation = _cloudGeneration;
    try {
      final changes = await (service as MeetingChangeReader).readChanges(
        source,
      );
      if (!_disposed &&
          generation == _cloudGeneration &&
          record?.id == source.id &&
          source.ownerId == remote?.accountId) {
        record = record!.copy(sourceChanges: changes);
        await store.save(record!);
        _emit();
      }
    } catch (_) {
      /* 离线时保留上次状态，不把未确认显示成成功。 */
    }
  }

  Future<void> _updateLiveHints() async {
    if (_disposed ||
        _liveBusy ||
        record == null ||
        record!.demo ||
        record!.ended ||
        record!.ownerId != remote?.accountId ||
        remote is! LiveMeetingAnalysis) {
      return;
    }
    final source = record!;
    if (!source.utterances.any((u) => u.turnStatus != 'pending')) return;
    final generation = _cloudGeneration;
    final facts = _meetingFacts();
    _liveFacts = facts;
    // 本次请求发起时固定归属，新发言不能带走正在加载的提示。
    final stable = source.utterances
        .where((u) => u.turnStatus != 'pending' && !u.withdrawn)
        .toList();
    _liveHintAnchorId = stable.lastOrNull?.id;
    _liveBusy = true;
    _liveHasContent = false;
    _livePreviewDone = false;
    _emit();
    bool current() =>
        !_disposed &&
        generation == _cloudGeneration &&
        record?.id == source.id &&
        remote?.accountId == source.ownerId;
    final streamedIds = <String>{};
    try {
      await (remote as LiveMeetingAnalysis).liveHints(source, (preview) {
        if (!current() || !_analysisSourceUnchanged(source)) return;
        if (preview['event'] == 'done') {
          // 流已经完成，即使没有建议，也不能继续等待正文或连接关闭。
          _livePreviewDone = true;
          _emit();
        }
        streamedIds.addAll(
          (preview['insights'] is List ? preview['insights'] as List : const [])
              .whereType<Map>()
              .map((i) => i['id'])
              .whereType<String>(),
        );
        if (_previewRows(preview['insights']).isNotEmpty ||
            (preview['inferred_completions'] as List? ?? []).isNotEmpty ||
            (preview['repairs'] as List? ?? []).isNotEmpty) {
          _liveHasContent = true;
        }
        final projected = applyMeetingAnalysis(
          record!,
          preview,
          preserveInferences: true,
        );
        final insights = {for (final i in record!.insights) i.id: i};
        insights.addAll({for (final i in projected.insights) i.id: i});
        if (preview['event'] == 'done') {
          // 末帧未包含的半截卡片保留为中断，不能一直显示生成中或冒充完整结论。
          for (final entry in insights.entries.toList()) {
            if (entry.value.streaming && streamedIds.contains(entry.key)) {
              insights[entry.key] = MeetingInsight.fromJson({
                ...entry.value.toJson(),
                'streaming': false,
                'interrupted': true,
              });
            }
          }
        }
        record = record!.copy(
          sourceChanges: [
            ...record!.sourceChanges,
            for (final change in projected.sourceChanges)
              if (!record!.sourceChanges.any(
                (old) =>
                    old['target_id'] == change['target_id'] &&
                    old['replacement_id'] == change['replacement_id'],
              ))
                change,
          ],
          insights: compactMeetingInsights(insights.values, record!.utterances),
          utterances: [
            for (final u in projected.utterances)
              if (preview['event'] == 'done' && u.repair?.streaming == true)
                u.revise(
                  repair: SpeechRepair.fromJson({
                    ...u.repair!.toJson(),
                    'streaming': false,
                    'interrupted': true,
                  }),
                )
              else if (u.repair == null)
                u.revise(
                  repair: record!.utterances
                      .where((old) => old.id == u.id)
                      .firstOrNull
                      ?.repair,
                )
              else
                u,
          ],
        );
        if (projected.insights.isNotEmpty ||
            projected.sourceChanges.isNotEmpty ||
            projected.utterances.any((u) => u.repair != null)) {
          _corePreviewReady = true;
          _analysisConfigured = true;
          _emit();
        }
      });
    } catch (_) {
      // 断流保留已收到的提示，标明未完成，不能一直显示生成中。
      if (current()) {
        record = record!.copy(
          utterances: [
            for (final u in record!.utterances)
              if (u.repair?.streaming == true)
                u.revise(
                  repair: SpeechRepair.fromJson({
                    ...u.repair!.toJson(),
                    'streaming': false,
                    'interrupted': true,
                  }),
                )
              else
                u,
          ],
          insights: [
            for (final i in record!.insights)
              i.streaming && streamedIds.contains(i.id)
                  ? MeetingInsight.fromJson({
                      ...i.toJson(),
                      'streaming': false,
                      'interrupted': true,
                    })
                  : i,
          ],
        );
      }
    } finally {
      _liveBusy = false;
      if (current()) {
        _emit();
        await store.save(record!);
        if (facts != _meetingFacts()) _scheduleLiveHints();
      }
    }
  }

  /// 网络失败不影响录音；显式调用可等待所有已排队的文本同步，供重试和联调使用。
  Future<void> syncCloud() async {
    if (record?.offlineSyncHeld == true) return;
    _cloudTimer?.cancel();
    final running = _cloudWork;
    if (running != null) {
      await running;
      return;
    }
    if (_disposed ||
        record == null ||
        record!.demo ||
        record!.offlineSyncHeld ||
        remote?.accountId == null ||
        record!.ownerId != remote?.accountId) {
      return;
    }
    // 所有调用者等待同一个完整队列，而不是只等待当前的第一批请求。
    final drained = Completer<void>();
    _cloudWork = drained.future;
    try {
      do {
        await _pushCloud();
      } while (_cloudPending &&
          !_disposed &&
          record != null &&
          record!.ownerId == remote?.accountId);
    } finally {
      _cloudWork = null;
      drained.complete();
    }
  }

  Future<void> _pushCloud() async {
    _cloudRetryTimer?.cancel();
    // Minutes are generated from immutable raw speech and explicit corrections.
    // Display-only polishing continues independently and cannot hold archival.
    if (_disposed || record == null || record!.ownerId != remote?.accountId) {
      return;
    }
    _cloudPending = false;
    final generation = _cloudGeneration;
    var facts = _meetingFacts();
    final effectiveElapsed = record!.ended && record!.elapsed > elapsed
        ? record!.elapsed
        : elapsed;
    var source = record!.copy(
      syncRevision: record!.syncRevision + 1,
      elapsed: effectiveElapsed,
    );
    final paused = phase == MeetingPhase.paused;
    bool current() =>
        !_disposed &&
        generation == _cloudGeneration &&
        record?.id == source.id &&
        remote?.accountId == source.ownerId;
    if (remote is! RealtimeMeetingBusiness) record = source;
    cloudError = null;
    try {
      // 先保存同步版本再发送，避免进程重启后复用旧版本号。
      if (remote is RealtimeMeetingBusiness) {
        final uploaded = await _uploadEvidence();
        if (uploaded == null) return;
        source = uploaded;
        facts = _meetingFacts();
      } else {
        await store.save(source);
        if (!current()) return;
        await remote!.sync(source, paused: paused);
      }
      if (!current()) return;
      _queueCloudAudio(source);
      // Final minutes depend on the stable transcript, not on completion of
      // the independent realtime business review. Let that review finish in
      // the background without holding the archive queue.
      // Final minutes have their own evidence-bound generation job. A failed
      // realtime Agent review must not prevent an ended meeting being archived.
      if (!source.ended &&
          source.utterances.any((u) => u.turnStatus != 'pending') &&
          facts != _lastAnalyzedFacts) {
        cloudAnalyzing = true;
        _corePreviewReady = false;
        _coreHasContent = false;
        _coreInitialResultReady = false;
        _coreHintAnchorId = source.utterances
            .where((u) => u.turnStatus != 'pending' && !u.withdrawn)
            .lastOrNull
            ?.id;
        _emit();
        final service = remote!;
        void showCorePreview(Map<String, dynamic> preview) {
          if (current() && preview['actions_prepared'] == true) {
            unawaited(_refreshNotices());
          }
          if (!current() || !_analysisSourceUnchanged(source)) return;
          final resultReady =
              preview['actions_prepared'] == true ||
              (preview['agents_completed'] as List? ?? []).isNotEmpty ||
              (preview['commitments'] as List? ?? []).isNotEmpty ||
              (preview['goals'] as List? ?? []).isNotEmpty;
          if (resultReady) {
            // 已产出事项、角色已结束或转为人工补全，不等慢速后台收尾。
            _corePreviewReady = true;
            _coreInitialResultReady = true;
            _releasePolish();
            _emit();
          }
          if (_previewRows(preview['insights']).isEmpty &&
              (preview['repairs'] as List? ?? []).isEmpty) {
            return;
          }
          if (!current() || !_analysisSourceUnchanged(source)) {
            return;
          }
          final projected = applyMeetingAnalysis(record!, {
            'insights': preview['insights'] ?? [],
            'repairs': preview['repairs'] ?? [],
          }, preserveInferences: true);
          // 预览只能改变推测展示，不能清空承诺、撤回决定或执行行动。
          record = record!.copy(
            utterances: projected.utterances,
            insights: projected.insights,
          );
          _coreHasContent =
              _previewRows(preview['insights']).any(
                (i) => i['body'] is String && (i['body'] as String).isNotEmpty,
              ) ||
              (preview['repairs'] as List? ?? []).any(
                (r) => (r['text'] as String? ?? '').isNotEmpty,
              ) ||
              _coreHasContent;
          _corePreviewReady = true;
          if (_coreHasContent) _releasePolish();
          _emit();
        }

        final report = service is StreamingMeetingAnalysis
            ? await (service as StreamingMeetingAnalysis).analyzeWithUpdates(
                source,
                showCorePreview,
              )
            : await service.analyze(source);
        if (!current()) return;
        if (_analysisSourceUnchanged(source)) {
          final newest = record!;
          record = applyMeetingAnalysis(
            record!,
            report,
            preserveInferences: true,
          );
          final analyzedIds = source.utterances.map((u) => u.id).toSet();
          // 完整分析只能替换自己覆盖的来源，不能清掉等待期间新发言的即时提示。
          final newer = newest.insights.where(
            (i) => i.evidenceIds.any((id) => !analyzedIds.contains(id)),
          );
          record = record!.copy(
            insights: {
              for (final i in record!.insights) i.id: i,
              for (final i in newer) i.id: i,
            }.values.toList(),
            utterances: [
              for (final u in record!.utterances)
                if (u.repair == null &&
                    (newest.utterances
                            .where((old) => old.id == u.id)
                            .firstOrNull
                            ?.repair
                            ?.evidenceIds
                            .any((id) => !analyzedIds.contains(id)) ??
                        false))
                  u.revise(
                    repair: newest.utterances
                        .firstWhere((old) => old.id == u.id)
                        .repair,
                  )
                else
                  u,
            ],
          );
          await refreshSourceChanges();
          await onProgressChanged?.call();
          if (!current()) return;
          ++_completionRevision;
          _analysisConfigured = true;
          cloudAnalyzed = _meetingFacts() == facts;
          _lastAnalyzedFacts = facts;
          if (cloudAnalyzed) {
            _cloudObserved = _cloudSignature();
          } else {
            _cloudPending = true;
          }
          await store.save(record!);
          _emit();
        }
      }
      if (source.ended && source.canGenerateMinutes && current()) {
        if (audioRecovery != null && await audioRecovery!.hasPending(record!)) {
          cloudError = '录音已保存，补转写完成后再生成最终纪要';
          return;
        }
        // 核对尾句或纠错，只在证据变化时再同步，不重复递增相同快照版本。
        if (remote is RealtimeMeetingBusiness) {
          final finalized = await _uploadEvidence();
          if (!current() || finalized == null || !finalized.ended) return;
          source = finalized;
        }
        final archive = await remote!.archive(source);
        if (!current()) return;
        final content = archive['markdown'] as String;
        // 归档与知识库已在服务端同一事务提交，先读取最新版本，避免旧快照覆盖。
        await knowledge.load();
        if (!current()) return;
        final existing = knowledge.document('meeting-${source.id}');
        final id =
            knowledge.repository is DioKnowledgeRepository && existing != null
            ? existing.id
            : await knowledge.archiveMeeting(
                meetingId: source.id,
                ownerUserId: source.ownerId,
                title: archive['title'] as String,
                content: content,
                demo: false,
                refreshExisting: true,
              );
        if (id == null) throw StateError('本地纪要更新失败');
        record = record!.copy(
          title: archive['meetingTitle'] as String? ?? record!.title,
          cloudMinutes: content,
          speakerIdentities: archive['speakerIdentities'] is Map
              ? Map<String, dynamic>.from(archive['speakerIdentities'])
              : null,
          speakerIdentityRevision: archive['speakerIdentityRevision'] as int?,
          documentId: id,
          minutesDetails: archive['details'] is Map
              ? Map<String, dynamic>.from(archive['details'])
              : null,
        );
        await store.save(record!);
        try {
          await onProgressChanged?.call();
        } on ApiFailure catch (failure) {
          if (failure.status == 401 || failure.status == 403) rethrow;
          // The archive is already committed. An ancillary refresh outage
          // must not turn it into a failed archive or resubmit model work.
        }
        unawaited(questions.afterArchive(record!));
        ++_completionRevision;
      }
      if (current()) {
        _cloudFailures = 0;
        record = record!.copy(recoveryPendingSync: false);
        await store.save(record!);
      }
    } catch (failure) {
      if (current()) {
        if (failure is ApiFailure && failure.code == 'meeting_deleted') {
          await _forgetDeleted(source);
          await knowledge.load();
          return;
        }
        cloudError = failure is ApiFailure
            ? failure.message
            : '云端同步或分析未完成，本地录音与转写已保留';
        if (failure is! ApiFailure || ![401, 403].contains(failure.status)) {
          _cloudFailures++;
          _cloudRetryTimer = Timer(
            Duration(
              seconds: (5 * (1 << (_cloudFailures - 1).clamp(0, 3))).clamp(
                5,
                30,
              ),
            ),
            () {
              if (current()) {
                _cloudPending = true;
                unawaited(syncCloud());
              }
            },
          );
        }
      }
    } finally {
      if (current()) {
        cloudAnalyzing = false;
        _emit();
      }
    }
  }

  Future<void> _refreshNotices() async {
    try {
      await onNoticesChanged?.call();
    } catch (_) {
      /* 通知刷新失败不阻断会议。 */
    }
  }

  bool _analysisSourceUnchanged(MeetingRecord source) {
    final now = record?.utterances ?? <MeetingUtterance>[];
    if (now.length < source.utterances.length) return false;
    for (var i = 0; i < source.utterances.length; i++) {
      final a = source.utterances[i], b = now[i];
      if (a.turnStatus == 'pending') continue;
      if (a.id != b.id ||
          a.raw != b.raw ||
          a.turnStatus != b.turnStatus ||
          a.correction != b.correction ||
          a.withdrawn != b.withdrawn ||
          a.speakerId != b.speakerId ||
          a.speakerRevision != b.speakerRevision ||
          a.speaker != b.speaker ||
          a.speakerSeparated != b.speakerSeparated ||
          a.manual != b.manual ||
          a.at != b.at) {
        return false;
      }
    }
    return true;
  }

  /// 扫描本机录音与业务同步标记；账户切换、重新录音会停止这一批恢复。
  Future<void> recoverAudio() async {
    final recovery = audioRecovery;
    final owner = remote?.accountId;
    if (recovery == null ||
        owner == null ||
        _recovering ||
        _disposed ||
        busy ||
        phase == MeetingPhase.recording) {
      return;
    }
    _recovering = true;
    final generation = _generation;
    bool current() =>
        !_disposed &&
        !busy &&
        generation == _generation &&
        owner == remote?.accountId &&
        phase != MeetingPhase.recording;
    try {
      final saved = await store.read();
      for (final initial in saved.where(
        (r) => !r.demo && !r.offlineSyncHeld && r.ownerId == owner,
      )) {
        if (!current()) return;
        var source = record?.id == initial.id ? record! : initial;
        if (!source.recoveryPendingSync && !await recovery.hasPending(source)) {
          continue;
        }
        // 即使剩余录音只有静音，业务同步失败后也必须保留重试标记。
        source = source.copy(recoveryPendingSync: true);
        await store.save(source);
        if (record?.id == source.id) record = source;
        await for (final event in recovery.recover(
          source,
          isCurrent: current,
        )) {
          if (!current()) return;
          if (record?.id == source.id) source = record!;
          final t = event.transcript;
          final old = source.utterances
              .where((u) => u.id == event.id)
              .firstOrNull;
          final sid = t.speakerSeparated ? t.speakerId : null;
          final identities = <String, String>{
            for (final u in source.utterances)
              if (u.speakerSeparated && u.speakerId != null)
                u.speakerId!: u.speaker,
          };
          final speaker = sid == null
              ? '待区分发言人'
              : identities.putIfAbsent(
                  sid,
                  () =>
                      '发言人 ${identities.length < 26 ? String.fromCharCode(65 + identities.length) : identities.length + 1}',
                );
          MeetingUtterance? item;
          if (old == null && !t.isSpeakerUpdate) {
            final audioEnd = event.offset + (t.audioEnd ?? Duration.zero);
            final at = event.timelineOffset + audioEnd;
            item = MeetingUtterance(
              id: event.id,
              speaker: speaker,
              speakerId: sid ?? 'unseparated',
              speakerSeparated: sid != null,
              speakerRevision: t.speakerRevision,
              speakerHistory: [
                {
                  'revision': t.speakerRevision,
                  'speaker': speaker,
                  'speakerId': sid ?? 'unseparated',
                  'speakerSeparated': sid != null,
                },
              ],
              raw: t.text,
              turnStatus: isUnfinishedSpeech(t.text)
                  ? 'interrupted'
                  : 'complete',
              cleaned: tidySpeech(t.text),
              at: at,
              audioPath: event.path,
              audioStart: event.offset + (t.audioStart ?? Duration.zero),
              audioEnd: audioEnd,
            );
          } else if (old != null &&
              t.isSpeakerUpdate &&
              t.speakerRevision > old.speakerRevision) {
            item = old.revise(
              speaker: speaker,
              speakerId: sid ?? 'unseparated',
              speakerSeparated: sid != null,
              speakerRevision: t.speakerRevision,
              clearRepair: true,
              speakerHistory: [
                ...old.speakerHistory,
                {
                  'revision': t.speakerRevision,
                  'speaker': speaker,
                  'speakerId': sid ?? 'unseparated',
                  'speakerSeparated': sid != null,
                },
              ],
            );
          }
          if (item != null) {
            final utterances = old == null
                ? [...source.utterances, item]
                : [
                    for (final u in source.utterances)
                      u.id == item.id ? item : u,
                  ];
            source = source.copy(
              utterances: utterances,
              recoveryPendingSync: true,
              elapsed: item.at > source.elapsed ? item.at : source.elapsed,
            );
            await store.save(source);
            unawaited(questions.associate(source).catchError((Object _) {}));
            if (record?.id == source.id) {
              record = source;
              if (source.elapsed > elapsed) _base = source.elapsed;
              _emit();
            }
          }
        }
        if (!current()) return;
        if (record?.id == source.id) {
          record = source;
          await syncCloud();
        } else {
          source = source.copy(syncRevision: source.syncRevision + 1);
          await store.save(source);
          await remote!.sync(source, paused: !source.ended);
          if (!current()) return;
          if (source.utterances.isNotEmpty) await remote!.analyze(source);
          if (!current()) return;
          if (source.ended && source.canGenerateMinutes) {
            final archive = await remote!.archive(source);
            source = source.copy(
              title: archive['meetingTitle'] as String? ?? source.title,
              cloudMinutes: archive['markdown'] as String,
              speakerIdentities: archive['speakerIdentities'] is Map
                  ? Map<String, dynamic>.from(archive['speakerIdentities'])
                  : null,
              speakerIdentityRevision:
                  archive['speakerIdentityRevision'] as int?,
              minutesDetails: archive['details'] is Map
                  ? Map<String, dynamic>.from(archive['details'])
                  : null,
              documentId: 'meeting-${source.id}',
            );
          }
          await store.save(source.copy(recoveryPendingSync: false));
          _queueCloudAudio(source);
          if (source.ended) unawaited(questions.afterArchive(source));
          await knowledge.load();
          await onProgressChanged?.call();
        }
      }
    } catch (_) {
      if (current()) {
        cloudError = '补转写或同步尚未完成，原始录音保留，将自动重试';
        _emit();
      }
    } finally {
      _recovering = false;
    }
  }

  void _queuePolish(MeetingUtterance utterance) {
    if (remote is! MeetingTranscriptPolisher ||
        record?.ownerId == null ||
        record!.ownerId != remote?.accountId) {
      return;
    }
    _polishQueue.add((record!, utterance, _cloudGeneration));
    if (phase == MeetingPhase.recording && remote is StreamingMeetingAnalysis) {
      // 实时提示优先；不让逐切片的字词整理抢占刚到达的核心分析名额。
      _polishDelay ??= Timer(const Duration(seconds: 6), _releasePolish);
    } else {
      _startPolish();
    }
  }

  void _releasePolish() {
    _polishDelay?.cancel();
    _polishDelay = null;
    if (!_disposed) _startPolish();
  }

  void _startPolish() {
    if (_polishDelay?.isActive == true) return;
    if (_polishWork == null) {
      final work = _drainPolish();
      _polishWork = work;
      unawaited(
        work.whenComplete(() {
          _polishWork = null;
          if (_polishQueue.isNotEmpty && !_disposed) _startPolish();
        }),
      );
    }
  }

  Future<void> waitForPolish() async {
    // 等自然收尾，不因调用等待函数而把半句强制送入后续流程。
    if (_turnTimer?.isActive == true) {
      await Future<void>.delayed(
        isUnfinishedSpeech(_turnText) ? unfinishedQuiet : turnQuiet,
      );
    }
    _releasePolish();
    while (_polishWork != null) {
      await _polishWork;
    }
  }

  Future<void> _drainPolish() async {
    while (_polishQueue.isNotEmpty &&
        !_disposed &&
        _polishDelay?.isActive != true) {
      final (source, item, generation) = _polishQueue.removeAt(0);
      bool current() =>
          !_disposed &&
          generation == _cloudGeneration &&
          record?.id == source.id &&
          remote?.accountId == source.ownerId;
      if (!current()) continue;
      try {
        final cleaned = await (remote as MeetingTranscriptPolisher).polish(
          source,
          item,
        );
        if (!current()) continue;
        if (cleaned != item.raw && cleaned.trim().isNotEmpty) {
          record = record!.copy(
            utterances: [
              for (final u in record!.utterances)
                u.id == item.id && u.raw == item.raw && u.correction == null
                    ? u.revise(cleaned: cleaned)
                    : u,
            ],
          );
          await store.save(record!);
          polishError = null;
          _emit();
        }
      } catch (_) {
        if (current()) polishError = 'AI 整理未完成，已保留原始转写';
      }
    }
  }
}

List<Map<String, dynamic>> _previewRows(Object? value) => [
  for (final row in value is List ? value : const [])
    if (row is Map && row['id'] is String) Map<String, dynamic>.from(row),
];
