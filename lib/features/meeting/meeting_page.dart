import '../../shared/widgets/confirmation_dialog.dart';
import '../../shared/widgets/content_skeleton.dart';
import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:go_router/go_router.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:path_provider/path_provider.dart';
import 'meeting_audio.dart';
import '../knowledge/widgets/knowledge_sources_section.dart';
import '../home/views/home_style.dart';
import '../profile/viewmodels/profile_view_model.dart';
import '../notifications/notification_views.dart';
import 'meeting_models.dart';
import 'meeting_insights.dart';
import 'speech_turn.dart';
import 'meeting_view_model.dart';
import 'meeting_completion_panel.dart';
import 'meeting_ai_glow.dart';
import 'meeting_terms.dart';
import 'meeting_remote.dart';
import 'meeting_question_widgets.dart';

class MeetingPage extends StatefulWidget {
  const MeetingPage({
    super.key,
    this.id,
    this.focusUtterance,
    this.startRecording = false,
  });
  final String? id, focusUtterance;
  final bool startRecording;
  @override
  State<MeetingPage> createState() => _MeetingPageState();
}

class _MeetingPageState extends State<MeetingPage> with WidgetsBindingObserver {
  final _transcriptScroll = ScrollController();
  String _lastStream = '';
  List<MeetingInsight>? _insightInput;
  List<MeetingUtterance>? _insightSources;
  List<MeetingInsight> _compactedInsights = const [];
  List<MeetingUtterance>? _groupInput;
  List<List<MeetingUtterance>> _speechGroups = const [];
  Object? _paragraphChanges;
  final _paragraphCache = <List<MeetingUtterance>, List<SpeechParagraph>>{};
  List<SpeechParagraph> _paragraphs(
    List<MeetingUtterance> group,
    List<Map<String, dynamic>> changes,
  ) {
    if (!identical(_paragraphChanges, changes)) {
      _paragraphChanges = changes;
      _paragraphCache.clear();
    }
    return _paragraphCache.putIfAbsent(
      group,
      () => speechParagraphs(
        group,
        protectedIds: {
          for (final c in changes)
            if (c['status'] != 'rejected' && c['target_id'] is String)
              c['target_id'] as String,
        },
      ),
    );
  }

  bool _follow = true, _autoScroll = false;
  bool _opened = false, _minutesNavigationScheduled = false;
  bool _finishDialogOpen = false;
  String? _startedRecordId;
  MeetingViewModel? _observedModel;
  void _rememberSession() {
    final model = _observedModel;
    if (model != null && model.active && model.record?.ended == false) {
      _startedRecordId = model.record!.id;
    }
  }

  final _sourceAnchor = GlobalKey();
  bool _sourceFocused = false, _sourceSearching = false;
  final _anchors = <String, GlobalKey>{};
  AudioPlayer? _player;
  bool _playing = false, _audioBusy = false;
  String? _playId;
  int _playRequest = 0;
  Duration _playPosition = Duration.zero;
  Directory? _clipDirectory;
  Completer<void>? _replayDone;
  StreamSubscription<Duration>? _positionSubscription;
  StreamSubscription<void>? _completion;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _transcriptScroll.addListener(() {
      if (!_autoScroll && _transcriptScroll.hasClients) {
        _follow =
            _transcriptScroll.position.maxScrollExtent -
                _transcriptScroll.offset <
            72;
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final model = context.read<MeetingViewModel>();
      _observedModel = model;
      model.addListener(_rememberSession);
      _rememberSession();
      if (widget.focusUtterance != null) _follow = false;
      if (widget.startRecording) {
        if (!model.active && !model.busy) await model.start(demo: false);
      } else {
        await model.open(widget.id);
      }
      if (mounted) setState(() => _opened = true);
      if (mounted &&
          ModalRoute.of(context)?.isCurrent == true &&
          !widget.startRecording &&
          widget.id != null &&
          model.record?.id == widget.id &&
          !model.busy &&
          !model.active &&
          model.record?.ended == true &&
          widget.focusUtterance == null) {
        _minutesNavigationScheduled = true;
        context.replace(
          '/meetings/${Uri.encodeComponent(model.record!.id)}/minutes',
        );
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      // 录音生命周期由 ViewModel 与原生后台服务决定；页面只暂停音频回放。
      ++_playRequest;
      unawaited(_player?.pause());
      if (mounted && _playing) setState(() => _playing = false);
    }
  }

  @override
  void dispose() {
    _observedModel?.removeListener(_rememberSession);
    WidgetsBinding.instance.removeObserver(this);
    _transcriptScroll.dispose();
    unawaited(_completion?.cancel());
    ++_playRequest;
    unawaited(_positionSubscription?.cancel());
    unawaited(_disposeAudio());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<MeetingViewModel>();
    final record = vm.record;
    if (record != null && !record.ended && vm.active) {
      _startedRecordId = record.id;
    }
    if (_opened &&
        record?.ended == true &&
        !vm.active &&
        _startedRecordId == record?.id &&
        widget.focusUtterance == null &&
        !_minutesNavigationScheduled) {
      _minutesNavigationScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted &&
            ModalRoute.of(context)?.isCurrent == true &&
            !vm.active &&
            vm.record?.id == record?.id &&
            vm.record?.ended == true) {
          context.replace(
            '/meetings/${Uri.encodeComponent(record!.id)}/minutes?processing=1',
          );
        } else {
          _minutesNavigationScheduled = false;
        }
      });
    }
    final profileName = context.watch<ProfileViewModel>().data.name;
    final name = profileName.trim().isEmpty ? '我' : profileName.trim();
    void leaveMeeting() {
      if (context.canPop()) {
        context.pop();
      } else {
        context.go('/home');
      }
    }

    return PopScope(
      canPop: ModalRoute.of(context)?.canPop ?? context.canPop(),
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) leaveMeeting();
      },
      child: Scaffold(
        backgroundColor: HomeStyle.canvas(context),
        appBar: AppBar(
          leading: BackButton(onPressed: leaveMeeting),
          title: Text(record?.title ?? '录音会议'),
          actions: [
            const NotificationAction(),
            if (record != null)
              MeetingQuestionList(questions: vm.questions, record: record, toolbar: true),
          ],
        ),
        body: SafeArea(
          bottom: false,
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                    child: Text(
                      record?.demo == true
                          ? '演示模式 · 未录音 · 推演为示例'
                          : vm.recordingStatus,
                      style: HomeStyle.text(
                        11,
                        color: HomeStyle.secondary(context),
                      ),
                    ),
                  ),
                  if (vm.error != null || vm.storageError != null)
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(
                        vm.storageError ?? vm.error!,
                        style: HomeStyle.text(
                          12,
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  Expanded(
                    child: vm.loading && vm.record == null
                        ? const ContentSkeleton(
                            layout: SkeletonLayout.transcript,
                            label: '正在加载会议记录',
                          )
                        : _stream(context, vm, name),
                  ),
                ],
              ),
            ),
          ),
        ),
        bottomNavigationBar: record?.ended == true
            ? _MeetingEndPanel(child: _controls(context, vm, name))
            : ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight:
                      MediaQuery.sizeOf(context).height *
                      (vm.active ? .48 : .62),
                ),
                child: Material(
                  color: HomeStyle.surface(context),
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(24),
                  ),
                  child: SafeArea(
                    top: false,
                    child: SingleChildScrollView(
                      child: Center(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 640),
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
                            child: _controls(context, vm, name),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
      ),
    );
  }

  Widget _stream(BuildContext context, MeetingViewModel vm, String name) {
    final utterances = vm.record?.utterances ?? [];
    final input = vm.record?.insights ?? const <MeetingInsight>[];
    if (!identical(input, _insightInput) ||
        !identical(utterances, _insightSources)) {
      _insightInput = input;
      _insightSources = utterances;
      _compactedInsights = compactMeetingInsights(input, utterances);
    }
    final insights = _compactedInsights;
    if (!identical(_groupInput, utterances)) {
      _groupInput = utterances;
      _speechGroups = speechTurnGroups(utterances);
      _paragraphCache.clear();
    }
    final speechGroups = _speechGroups;
    final pendingCompletionIds = pendingSpeechCompletionIds(utterances);
    final hintLayout = MeetingHintLayout(insights, speechGroups);
    final inlineInsights = hintLayout.inlineSuggestions(insights);
    final signature =
        '${vm.record?.id}:${utterances.length}:${vm.partial}:${utterances.lastOrNull?.display}';
    if (_lastStream != signature) {
      _lastStream = signature;
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted || !_follow || !_transcriptScroll.hasClients) {
          return;
        }
        _autoScroll = true;
        if (MediaQuery.disableAnimationsOf(context)) {
          _transcriptScroll.jumpTo(_transcriptScroll.position.maxScrollExtent);
        } else {
          await _transcriptScroll.animateTo(
            _transcriptScroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 120),
            curve: Curves.easeOutCubic,
          );
        }
        _autoScroll = false;
      });
    }
    if (widget.focusUtterance != null &&
        !_sourceFocused &&
        !_sourceSearching &&
        utterances.any((u) => u.id == widget.focusUtterance)) {
      _sourceSearching = true;
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        try {
          if (!mounted || !_transcriptScroll.hasClients) return;
          final target = utterances.indexWhere(
            (u) => u.id == widget.focusUtterance,
          );
          var low = 0.0, high = _transcriptScroll.position.maxScrollExtent;
          var offset = high * target / utterances.length;
          var boundedAbove = false;
          for (var attempt = 0; attempt < 24 && mounted; attempt++) {
            _transcriptScroll.jumpTo(
              offset.clamp(0, _transcriptScroll.position.maxScrollExtent),
            );
            await WidgetsBinding.instance.endOfFrame;
            if (!mounted) return;
            final anchor = _sourceAnchor.currentContext;
            if (anchor != null && anchor.mounted) {
              await Scrollable.ensureVisible(anchor, alignment: .15);
              _sourceFocused = true;
              return;
            }
            final built = [
              for (var i = 0; i < utterances.length; i++)
                if (_anchors[utterances[i].id]?.currentContext != null) i,
            ];
            if (built.isEmpty) return;
            if (target < built.first) {
              high = offset;
              boundedAbove = true;
            } else {
              low = offset;
              if (!boundedAbove) {
                high = _transcriptScroll.position.maxScrollExtent;
              }
            }
            final next = (low + high) / 2;
            if ((next - offset).abs() < 1) return;
            offset = next;
          }
        } finally {
          _sourceSearching = false;
        }
      });
    }
    return ListView(
      controller: _transcriptScroll,
      key: const PageStorageKey('meeting-transcript'),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
      children: [
        if (vm.selfIdentificationHint.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Text(
              vm.selfIdentificationHint,
              key: const ValueKey('meeting-self-identification'),
              style: HomeStyle.text(12),
            ),
          ),
        if (utterances.isEmpty && vm.partial.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 42, horizontal: 20),
            child: Column(
              children: [
                Icon(
                  Icons.graphic_eq,
                  size: 38,
                  color: HomeStyle.blue.withValues(alpha: .5),
                ),
                const SizedBox(height: 12),
                Text(
                  vm.active ? '正在听，请开始说话' : '让对话的线索清晰可见',
                  style: HomeStyle.text(16, bold: true),
                ),
                const SizedBox(height: 8),
                Text(
                  '可先体验示例，查看疑点、对话分支与片段拼接。',
                  textAlign: TextAlign.center,
                  style: HomeStyle.text(
                    12,
                    color: HomeStyle.secondary(context),
                  ),
                ),
              ],
            ),
          ),
        for (final group in speechGroups) ...[
          Padding(
            key: ValueKey('speech-turn-${group.first.id}'),
            padding: const EdgeInsets.only(bottom: 10),
            child: MeetingAiGlow(
              active: group.any(
                (u) =>
                    vm.liveGenerationAnchorId == u.id ||
                    (vm.coreHintsLoading &&
                        vm.coreHintAnchorId == u.id &&
                        !vm.hasCompletion(group.map((s) => s.id).toList())) ||
                    (u.repair?.streaming ?? false) ||
                    inlineInsights.any(
                      (i) => i.streaming && i.evidenceIds.contains(u.id),
                    ),
              ),
              child: Container(
                decoration: HomeStyle.card(context: context, radius: 14),
                child: Column(
                  children: [
                    for (final paragraph in _paragraphs(
                      group,
                      vm.record!.sourceChanges,
                    )) ...[
                      for (final u in [paragraph.display])
                        KeyedSubtree(
                          key: ValueKey(u.id),
                          child: _UtteranceCard(
                            key:
                                paragraph.sources.any(
                                  (s) => s.id == widget.focusUtterance,
                                )
                                ? _sourceAnchor
                                : _anchors.putIfAbsent(u.id, () => GlobalKey()),
                            utterance: u,
                            questionBadge: MeetingQuestionList(questions: vm.questions, record: vm.record!,
                              sourceIds: paragraph.sources
                                  .map((s) => s.id)
                                  .toList(),
                              compact: true,
                              transcriptBadge: true,
                              badgeLabel: '已标记疑问',
                            ),
                            sourceIds: paragraph.sources
                                .map((s) => s.id)
                                .toList(),
                            hasCompletion: vm.hasCompletion(
                              paragraph.sources.map((s) => s.id).toList(),
                            ),
                            awaitingCompletion: paragraph.sources.any(
                              (s) => pendingCompletionIds.contains(s.id),
                            ),
                            grouped: true,
                            continuation: u.id != group.first.id,
                            change: vm.record!.sourceChanges
                                .where(
                                  (c) =>
                                      c['target_id'] == u.id &&
                                      c['status'] != 'rejected',
                                )
                                .lastOrNull,
                            demo: vm.record!.demo,
                            name: u.speaker == '项目负责人'
                                ? name
                                : vm.speakerDisplayName(u),
                            editable: vm.active && !vm.busy,
                            playing: _playId == u.id && _playing,
                            audioBusy: _audioBusy,
                            playPosition: _playId == u.id
                                ? _playPosition
                                : Duration.zero,
                            onPlay: u.hasAudio && !vm.busy && !_audioBusy
                                ? () => _replay(u.audioPath!, utterance: u)
                                : null,
                            onCorrect: () => _paragraphAction(
                              context,
                              paragraph.sources,
                              (source) => _edit(
                                context,
                                name: source.speaker,
                                item: source,
                              ),
                            ),
                            onRetract: () => _paragraphAction(
                              context,
                              paragraph.sources,
                              (source) async {
                                await vm.retract(source.id);
                              },
                            ),
                            repairSources: vm.record!.utterances
                                .where(
                                  (s) =>
                                      s.id != u.id &&
                                      (u.repair?.evidenceIds.contains(s.id) ??
                                          false),
                                )
                                .toList(),
                            suggestions: inlineInsights
                                .where(
                                  (i) =>
                                      hintLayout.isInline(i) &&
                                      paragraph.sources.any(
                                        (s) => suggestionsForSource([
                                          i,
                                        ], s.id).isNotEmpty,
                                      ),
                                )
                                .toList(),
                            evidenceSources: utterances,
                            aiLoading:
                                vm.liveHintsLoading &&
                                !vm.hasCompletion(
                                  paragraph.sources.map((s) => s.id).toList(),
                                ) &&
                                paragraph.sources.any(
                                  (s) => vm.liveHintAnchorId == s.id,
                                ),
                          ),
                        ),
                    ],
                  ],
                ),
              ),
            ),
          ),
          for (final u in group)
            for (final insight in suggestionsForSource(
              insights,
              u.id,
            ).where((i) => !hintLayout.isInline(i)))
              _InsightCard(
                key: ValueKey('meeting-insight-${insight.id}'),
                insight: insight,
                record: vm.record!,
              ),
        ],
        if (vm.partial.isNotEmpty)
          _UtteranceCard(
            key: const ValueKey('meeting-partial'),
            utterance: MeetingUtterance(
              id: 'partial',
              speaker: vm.partialSpeaker,
              raw: vm.partial,
              at: vm.elapsed,
            ),
            demo: vm.record!.demo,
            name: vm.partialSpeaker == '项目负责人'
                ? name
                : vm.partialSpeakerDisplay,
            editable: false,
            partial: true,
          ),
      ],
    );
  }

  Widget _controls(BuildContext context, MeetingViewModel vm, String name) {
    final ended = vm.phase == MeetingPhase.ended;
    final controlStyle = ButtonStyle(
      minimumSize: const WidgetStatePropertyAll(Size.zero),
      padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 12)),
      textStyle: WidgetStatePropertyAll(HomeStyle.text(13, bold: true)),
      iconSize: const WidgetStatePropertyAll(18),
      shape: const WidgetStatePropertyAll(StadiumBorder()),
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            CircleAvatar(
              radius: 16,
              backgroundColor: HomeStyle.blue.withValues(alpha: .1),
              child: Text(
                name.characters.first,
                style: HomeStyle.text(13, bold: true, color: HomeStyle.blue),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                ended
                    ? '会议已结束'
                    : vm.phase == MeetingPhase.paused
                    ? '采音中断'
                    : vm.active
                    ? vm.record!.demo
                          ? '会议示例播放中'
                          : '正在录音'
                    : '准备开始',
                style: HomeStyle.text(12),
              ),
            ),
            if (vm.record?.demo == true)
              Text(
                '演示',
                style: HomeStyle.text(11, color: HomeStyle.secondary(context)),
              ),
          ],
        ),
        const SizedBox(height: 8),
        Text(meetingTime(vm.elapsed), style: HomeStyle.text(34, bold: true)),
        if (vm.active) ...[
          const SizedBox(height: 4),
          SizedBox(
            height: 38,
            width: double.infinity,
            child: CustomPaint(
              painter: _RecordingWave(
                vm.record?.demo == true ? [] : List.of(vm.waveform),
                HomeStyle.blue,
              ),
            ),
          ),
          if (vm.record?.demo == true)
            Text(
              '示例文字流，未采集麦克风',
              style: HomeStyle.text(10, color: HomeStyle.secondary(context)),
            ),
          LayoutBuilder(builder: (context, constraints) {
            final width = (constraints.maxWidth - 12) / 2;
            final height = (MediaQuery.textScalerOf(context).scale(13) * 1.3 + 20).clamp(48.0, double.infinity);
            return Wrap(
            spacing: 12,
            runSpacing: 8,
            alignment: WrapAlignment.center,
            children: [
              if (vm.phase == MeetingPhase.paused)
                SizedBox(width: constraints.maxWidth, height: height, child: FilledButton.tonalIcon(
                  style: controlStyle,
                  key: const ValueKey('meeting-recover-recording'),
                  onPressed: vm.busy ? null : () => _resumeRecording(vm),
                  icon: const Icon(Icons.mic_none),
                  label: const Text('恢复录音'),
                )),
              SizedBox(width: width, height: height, child: OutlinedButton.icon(
                style: controlStyle,
                key: const ValueKey('meeting-mark-question'),
                onPressed: !vm.canMarkQuestion ? null : () async {
                  try {
                    final marked = await vm.markQuestion();
                    if (context.mounted && marked) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('疑问已标记，可稍后补充'), duration: Duration(seconds: 2)));
                    } else if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('当前发言已标记，或暂时无法关联发言'), duration: Duration(seconds: 2)));
                    }
                  } catch (_) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('疑问尚未保存，请重试')));
                    }
                  }
                },
                icon: const Icon(Icons.help_outline), label: const Text('疑问标记', maxLines: 1),
              )),
              SizedBox(width: width, height: height, child: FilledButton.icon(
                style: controlStyle,
                key: const ValueKey('meeting-finish'),
                onPressed: vm.busy ? null : () => _finish(context),
                icon: const Icon(Icons.stop_rounded),
                label: Text(vm.busy ? '处理中' : '结束并归档', maxLines: 1),
              )),
            ],
          ); }),
        ] else if (ended) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            alignment: WrapAlignment.center,
            children: [
              if (vm.record!.documentId != null ||
                  !vm.record!.canGenerateMinutes)
                TextButton.icon(
                  onPressed: () => context.push(
                    '/meetings/${Uri.encodeComponent(vm.record!.id)}/minutes',
                  ),
                  icon: const Icon(Icons.menu_book_outlined),
                  label: Text(
                    vm.record!.canGenerateMinutes ? '查看会议纪要' : '查看录音与逐字稿',
                  ),
                )
              else
                TextButton(
                  onPressed: vm.busy ? null : vm.finish,
                  child: const Text('重试归档'),
                ),
              FilledButton(
                onPressed: vm.busy ? null : () => _startRecording(vm),
                child: const Text('开始新录音'),
              ),
            ],
          ),
        ] else ...[
          const SizedBox(height: 8),
          FilledButton.icon(
            key: const ValueKey('meeting-start-recording'),
            onPressed: vm.busy ? null : () => _startRecording(vm),
            icon: const Icon(Icons.mic_none),
            label: Text(vm.busy ? '正在准备' : '开始录音'),
          ),
          TextButton(
            key: const ValueKey('start-live-meeting'),
            onPressed: vm.busy ? null : () => _startRecording(vm),
            child: const Text('开始真实会话'),
          ),
        ],
      ],
    );
  }

  Future<void> _finish(BuildContext context) async {
    final vm = context.read<MeetingViewModel>();
    if (_finishDialogOpen || vm.busy || !vm.active) return;
    final meetingId = vm.record?.id;
    _finishDialogOpen = true;
    try {
      final answer = await showAppConfirmation(
        context,
        title: '结束并归档会议？',
        message: '原始录音与逐字稿将保留。会议满 1 分钟后生成纪要并保存到知识库。',
        cancel: '继续录音',
        action: '结束并归档',
        icon: Icons.stop_circle_outlined,
      );
      if (answer == true &&
          mounted &&
          vm.record?.id == meetingId &&
          vm.active &&
          !vm.busy) {
        await vm.finish();
      }
    } finally {
      _finishDialogOpen = false;
    }
  }

  Future<void> _paragraphAction(
    BuildContext context,
    List<MeetingUtterance> sources,
    Future<void> Function(MeetingUtterance) action,
  ) async {
    if (sources.length == 1) {
      await action(sources.single);
      return;
    }
    // 编辑和撤回仍定位原始证据，不能把展示合段回写成某一个切片的原话。
    final source = await showModalBottomSheet<MeetingUtterance>(
      context: context,
      useSafeArea: true,
      builder: (sheet) => ListView(
        shrinkWrap: true,
        children: [
          const ListTile(title: Text('选择原话片段')),
          for (final item in sources)
            ListTile(
              title: Text(item.display),
              onTap: () => Navigator.pop(sheet, item),
            ),
        ],
      ),
    );
    if (source != null && context.mounted) await action(source);
  }

  Future<void> _edit(
    BuildContext context, {
    required String name,
    MeetingUtterance? item,
  }) async {
    final vm = context.read<MeetingViewModel>();
    final speaker = TextEditingController(text: name);
    final text = TextEditingController(text: item?.display);
    await showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(
            20,
            16,
            20,
            MediaQuery.viewInsetsOf(context).bottom + 20,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                item == null ? '手工补录' : '纠错（原文保留）',
                style: HomeStyle.text(18, bold: true),
              ),
              const SizedBox(height: 16),
              if (item == null)
                TextField(
                  controller: speaker,
                  decoration: const InputDecoration(labelText: '发言人（身份待确认）'),
                ),
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey('meeting-edit-text'),
                controller: text,
                minLines: 3,
                maxLines: 8,
                decoration: const InputDecoration(labelText: '文字内容'),
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () async {
                  if (text.text.trim().isEmpty) return;
                  if (item == null) {
                    await vm.addManual(speaker.text, text.text);
                  } else {
                    await vm.correct(item.id, text.text);
                  }
                  if (context.mounted) Navigator.pop(context);
                },
                child: const Text('保存'),
              ),
            ],
          ),
        ),
      ),
    );
    // The route transition can still render its fields for one frame.
    await Future<void>.delayed(const Duration(milliseconds: 350));
    speaker.dispose();
    text.dispose();
  }

  Future<void> _disposeAudio() async {
    await _replayDone?.future;
    await _player?.dispose();
    final directory = _clipDirectory;
    if (directory != null && await directory.exists()) {
      await directory.delete(recursive: true);
    }
  }

  Future<void> _stopPlayback() async {
    ++_playRequest;
    await _player?.stop();
    if (mounted) {
      setState(() {
        _playing = false;
        _playId = null;
        _playPosition = Duration.zero;
      });
    }
  }

  Future<void> _startRecording(MeetingViewModel vm) async {
    await _stopPlayback();
    if (mounted) await vm.start(demo: false);
  }

  Future<void> _resumeRecording(MeetingViewModel vm) async {
    await _stopPlayback();
    if (mounted) await vm.resume();
  }

  Future<void> _replay(String path, {MeetingUtterance? utterance}) async {
    if (_audioBusy) return;
    final request = ++_playRequest;
    final id = utterance?.id ?? path;
    final done = _replayDone = Completer<void>();
    setState(() => _audioBusy = true);
    try {
      final vm = context.read<MeetingViewModel>();
      if (vm.record?.demo == false && vm.phase == MeetingPhase.recording) {
        // 不能为了回放暂停会议，也不能让扬声器回声混入原始转写。
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('会议正在持续录音，结束后可回放原声')));
        return;
      }
      if (!mounted || request != _playRequest) return;
      final cloud = Uri.tryParse(path)?.scheme == 'yanshu-audio';
      _player ??= AudioPlayer();
      _completion ??= _player!.onPlayerComplete.listen((_) {
        if (mounted) {
          setState(() {
            _playing = false;
            _playId = null;
            _playPosition = Duration.zero;
          });
        }
      });
      _positionSubscription ??= _player!.onPositionChanged.listen((position) {
        if (mounted) setState(() => _playPosition = position);
      });
      if (_playId == id) {
        if (_playing) {
          await _player!.pause();
        } else {
          await _player!.resume();
        }
        if (mounted && request == _playRequest) {
          setState(() => _playing = !_playing);
        }
        return;
      }
      await _player!.stop();
      var source = path;
      if (utterance != null) {
        _clipDirectory ??= await (await getTemporaryDirectory()).createTemp(
          'meeting-playback-',
        );
        final clip = File('${_clipDirectory!.path}/clip-$request.wav');
        String? cloudId = cloud ? Uri.parse(path).path : null;
        if (!cloud &&
            !await File(path).exists() &&
            vm.remote is DioMeetingRepository &&
            vm.record != null) {
          cloudId = await (vm.remote as DioMeetingRepository).cloudAudioId(
            vm.record!,
            utterance,
          );
        }
        if (cloudId != null &&
            vm.remote is DioMeetingRepository &&
            vm.record != null) {
          await (vm.remote as DioMeetingRepository).downloadAudioClip(
            vm.record!,
            cloudId,
            clip.path,
            utterance.audioStart!,
            utterance.audioEnd!,
          );
        } else {
          await writeMeetingAudioClip(
            File(path),
            clip,
            utterance.audioStart!,
            utterance.audioEnd!,
          );
        }
        source = clip.path;
      }
      if (!mounted || request != _playRequest) return;
      setState(() {
        _playId = id;
        _playing = true;
        _playPosition = Duration.zero;
      });
      await _player!.play(DeviceFileSource(source));
      if (!mounted || request != _playRequest) await _player!.stop();
    } catch (_) {
      if (mounted && request == _playRequest) {
        setState(() {
          _playing = false;
          _playId = null;
        });
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('录音暂不可播放，请检查原文件')));
      }
    } finally {
      done.complete();
      if (mounted) setState(() => _audioBusy = false);
    }
  }
}

class _UtteranceCard extends StatefulWidget {
  const _UtteranceCard({
    super.key,
    required this.utterance,
    required this.name,
    required this.demo,
    required this.editable,
    this.partial = false,
    this.grouped = false,
    this.continuation = false,
    this.onCorrect,
    this.onRetract,
    this.onPlay,
    this.playing = false,
    this.audioBusy = false,
    this.playPosition = Duration.zero,
    this.repairSources = const [],
    this.change,
    this.suggestions = const [],
    this.aiLoading = false,
    this.evidenceSources = const [],
    this.awaitingCompletion = false,
    this.sourceIds = const [],
    this.hasCompletion = false,
    this.questionBadge,
  });
  final MeetingUtterance utterance;
  final String name;
  final bool demo, editable, partial, grouped, continuation;
  final VoidCallback? onCorrect, onRetract, onPlay;
  final bool playing, audioBusy;
  final Duration playPosition;
  final List<MeetingUtterance> repairSources;
  final Map<String, dynamic>? change;
  final List<MeetingInsight> suggestions;
  final bool aiLoading;
  final List<MeetingUtterance> evidenceSources;
  final bool awaitingCompletion;
  final List<String> sourceIds;
  final bool hasCompletion;
  final Widget? questionBadge;
  @override
  State<_UtteranceCard> createState() => _UtteranceCardState();
}

class _UtteranceCardState extends State<_UtteranceCard> {
  bool _context = false;
  bool _moreSuggestions = false;
  bool _completion = false;
  bool _completionOpened = false;
  MeetingTermMatch? _selectedTerm;
  String? _termSource;
  @override
  Widget build(BuildContext context) {
    final u = widget.utterance;
    final name = widget.name.trim().isEmpty ? '待' : widget.name;
    final changed = u.withdrawn || widget.change != null;
    final color = changed
        ? Theme.of(context).colorScheme.error
        : HomeStyle.blue;
    final repair = u.repair;
    final showRepair =
        repair != null &&
        repair.validFor(u.raw) &&
        !changed &&
        u.correction == null &&
        !widget.partial;
    return Container(
      key: ValueKey('utterance-${u.id}'),
      margin: EdgeInsets.only(bottom: widget.grouped ? 0 : 10),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
      decoration: widget.grouped
          ? null
          : HomeStyle.card(context: context, radius: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (widget.continuation && widget.questionBadge != null)
            widget.questionBadge!,
          if (!widget.continuation)
            Row(
              children: [
                CircleAvatar(
                  radius: 11,
                  backgroundColor: color.withValues(alpha: .1),
                  child: Text(
                    name.characters.first,
                    style: HomeStyle.text(10, bold: true, color: color),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(name, style: HomeStyle.text(11, bold: true)),
                      if (widget.questionBadge != null) widget.questionBadge!,
                    ],
                  ),
                ),
                Text(
                  meetingTime(u.at),
                  style: HomeStyle.text(
                    10,
                    color: HomeStyle.secondary(context),
                  ),
                ),
              ],
            ),
          if (!widget.continuation) const SizedBox(height: 10),
          Container(
            width: double.infinity,
            padding: EdgeInsets.all(changed ? 8 : 0),
            decoration: changed
                ? BoxDecoration(
                    color: color.withValues(alpha: .06),
                    borderRadius: BorderRadius.circular(8),
                  )
                : null,
            child: showRepair
                ? Text.rich(
                    key: ValueKey('repair-text-${u.id}'),
                    TextSpan(
                      children: [
                        TextSpan(text: u.repairContext.$1),
                        WidgetSpan(
                          alignment: PlaceholderAlignment.middle,
                          child: ExcludeSemantics(
                            child: Container(
                              key: ValueKey('repair-cursor-${u.id}'),
                              width: 2,
                              height: MediaQuery.textScalerOf(
                                context,
                              ).scale(16),
                              margin: const EdgeInsets.symmetric(horizontal: 2),
                              color: HomeStyle.blue,
                            ),
                          ),
                        ),
                        TextSpan(
                          text: repair.text,
                          semanticsLabel: '推测补齐，未确认：${repair.text}',
                          style: TextStyle(
                            color:
                                Theme.of(context).brightness == Brightness.dark
                                ? const Color(0xFF9CA3B2)
                                : const Color(0xFF7A7E87),
                          ),
                        ),
                        TextSpan(text: u.repairContext.$2),
                      ],
                    ),
                    style: HomeStyle.text(14),
                  )
                : MeetingTermText(
                    onTermTap: (term) => setState(() {
                      _selectedTerm = term;
                      _termSource = changed ? u.raw : u.display;
                      _context = true;
                      _completion = false;
                    }),
                    classify: !widget.partial && !changed,
                    text: changed ? u.raw : u.display,
                    style: HomeStyle.text(14, color: changed ? color : null)
                        .copyWith(
                          decoration: changed
                              ? TextDecoration.lineThrough
                              : TextDecoration.none,
                        ),
                  ),
          ),
          if (widget.change case final change?) ...[
            const SizedBox(height: 8),
            Text(
              change['status'] == 'confirmed'
                  ? (change['operation'] == 'cancel'
                        ? '已确认撤回 · 原文保留'
                        : '已确认修改 · 原文保留')
                  : '变更待确认 · 原任务保持不变',
              style: HomeStyle.text(10, color: HomeStyle.secondary(context)),
            ),
            const SizedBox(height: 6),
            Text(
              change['new_text'] as String,
              key: ValueKey('source-change-${u.id}'),
              style: HomeStyle.text(14),
            ),
          ],
          if (!widget.partial) ...[
            const SizedBox(height: 10),
            Container(
              key: ValueKey('utterance-audio-${u.id}'),
              decoration: BoxDecoration(
                color: HomeStyle.blue.withValues(alpha: .055),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  IconButton(
                    key: ValueKey('play-utterance-${u.id}'),
                    tooltip: widget.playing ? '暂停语音' : '播放原声',
                    onPressed: widget.onPlay,
                    icon: Icon(
                      widget.playing
                          ? Icons.pause_circle_filled
                          : Icons.play_circle_fill,
                      color: u.hasAudio
                          ? HomeStyle.blue
                          : HomeStyle.secondary(context),
                      size: 26,
                    ),
                  ),
                  Icon(
                    Icons.graphic_eq,
                    color: HomeStyle.blue.withValues(alpha: .55),
                    size: 24,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      widget.playing
                          ? '正在播放'
                          : u.hasAudio
                          ? '原声片段'
                          : widget.demo
                          ? '示例未附音频'
                          : u.manual
                          ? '手工文字无录音'
                          : '暂无对应音频',
                      style: HomeStyle.text(
                        11,
                        color: HomeStyle.secondary(context),
                      ),
                    ),
                  ),
                  if (u.hasAudio)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      child: Text(
                        meetingTime(
                          widget.playing || widget.playPosition > Duration.zero
                              ? widget.playPosition
                              : u.audioEnd! - u.audioStart!,
                        ),
                        style: HomeStyle.text(10, color: HomeStyle.blue),
                      ),
                    ),
                ],
              ),
            ),
          ],
          if (showRepair) ...[
            const SizedBox(height: 8),
            Text(
              repair.streaming
                  ? '建议补充中 · 未确认'
                  : repair.interrupted
                  ? '补充中断 · 未确认'
                  : '推测补齐 · 未确认',
              style: HomeStyle.text(10, color: HomeStyle.secondary(context)),
            ),
            if (widget.repairSources.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  '关联片段 ${widget.repairSources.map((s) => meetingTime(s.at)).join(' · ')}',
                  style: HomeStyle.text(
                    10,
                    color: HomeStyle.secondary(context),
                  ),
                ),
              ),
          ],
          if (widget.awaitingCompletion &&
              !showRepair &&
              !changed &&
              !widget.partial &&
              u.correction == null) ...[
            const SizedBox(height: 8),
            Text(
              '待补全 · 发言尚未完成',
              key: ValueKey('pending-completion-${u.id}'),
              style: HomeStyle.text(10, color: HomeStyle.secondary(context)),
            ),
          ],
          if (widget.partial || u.manual || u.correction != null || u.withdrawn)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                widget.partial
                    ? '正在输出…'
                    : u.withdrawn
                    ? '已撤回 · 原文保留'
                    : u.manual
                    ? '手工补录 · 身份待确认'
                    : '人工纠错 · 原文保留',
                style: HomeStyle.text(10, color: HomeStyle.secondary(context)),
              ),
            ),
          if (!widget.partial)
            Wrap(
              spacing: 4,
              alignment: WrapAlignment.end,
              children: [
                TextButton(
                  onPressed: () => setState(() {
                    _context = _completion || !_context;
                    _completion = false;
                  }),
                  child: Text(
                    _context ? '收起上下文' : '展开上下文 ›',
                    style: const TextStyle(fontSize: 11),
                  ),
                ),
                if (widget.suggestions.isNotEmpty || widget.aiLoading)
                  TextButton.icon(
                    key: ValueKey('ai-context-${u.id}'),
                    onPressed: () => setState(() {
                      _context = _completion || !_context;
                      _completion = false;
                    }),
                    icon: const Icon(Icons.auto_awesome_outlined, size: 13),
                    label: Text(
                      widget.aiLoading ? 'AI 分析中' : 'AI 补充',
                      style: const TextStyle(fontSize: 11),
                    ),
                  ),
                if (widget.hasCompletion)
                  TextButton(
                    key: ValueKey('complete-info-${u.id}'),
                    onPressed: () => setState(() {
                      _completion = !_completion;
                      _completionOpened = true;
                      _context = false;
                    }),
                    child: Text(
                      _completion ? '收起补全' : '补全 ›',
                      style: const TextStyle(fontSize: 11),
                    ),
                  ),
              ],
            ),
          if (_completionOpened)
            Offstage(
              offstage: !_completion || widget.partial,
              child: MeetingCompletionPanel(
                key: ValueKey(
                  'completion-scope-${context.read<MeetingViewModel>().record?.ownerId}-${context.read<MeetingViewModel>().record?.id}-${u.id}',
                ),
                sourceId: u.id,
                active: _completion,
                dataRevision: context
                    .read<MeetingViewModel>()
                    .completionRevision,
                analysisPending: context
                    .read<MeetingViewModel>()
                    .completionUpdating,
                loadItems: () =>
                    context.read<MeetingViewModel>().completionItems(
                      widget.sourceIds.isEmpty ? [u.id] : widget.sourceIds,
                    ),
                onConfirm: (item, side, date) => context
                    .read<MeetingViewModel>()
                    .confirmCompletion(item, side: side, deadline: date),
              ),
            ),
          if (_context) ...[
            if (_selectedTerm != null &&
                _termSource == (changed ? u.raw : u.display))
              for (final term in [_selectedTerm!])
                Container(
                  key: ValueKey('term-explanation-${u.id}'),
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  margin: const EdgeInsets.only(bottom: 8),
                  decoration: BoxDecoration(
                    color: HomeStyle.blue.withValues(alpha: .045),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '术语解释 · ${term.term}',
                        style: HomeStyle.text(
                          11,
                          bold: true,
                          color: HomeStyle.blue,
                        ),
                      ),
                      const SizedBox(height: 7),
                      Text(term.definition, style: HomeStyle.text(12)),
                    ],
                  ),
                ),
            // 请求进行中由卡片流光表示，不提前插入一个空文字面板。
            if (widget.suggestions.isNotEmpty)
              Container(
                key: ValueKey('ai-suggestions-${u.id}'),
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                margin: const EdgeInsets.only(bottom: 8),
                decoration: BoxDecoration(
                  color: HomeStyle.blue.withValues(alpha: .045),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'AI 补充 · 待核对',
                      style: HomeStyle.text(
                        11,
                        bold: true,
                        color: HomeStyle.blue,
                      ),
                    ),
                    for (final insight in widget.suggestions.take(
                      _moreSuggestions ? widget.suggestions.length : 2,
                    ))
                      Padding(
                        key: ValueKey('meeting-insight-${insight.id}'),
                        padding: const EdgeInsets.only(top: 7),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (insight.title != 'AI 补充')
                              Text(
                                '${switch (insight.kind) {
                                  InsightKind.risk => '风险提醒',
                                  InsightKind.prediction => '前瞻推演',
                                  InsightKind.stitch => '记忆拼图',
                                  InsightKind.question => '待澄清',
                                }} · ${insight.title}',
                                key: ValueKey('insight-type-${insight.id}'),
                                style: HomeStyle.text(
                                  11,
                                  bold: true,
                                  color: insight.kind == InsightKind.risk
                                      ? Theme.of(context).colorScheme.error
                                      : HomeStyle.blue,
                                ),
                              ),
                            Text(
                              insight.title == 'AI 补充'
                                  ? '建议确认：${insight.body.replaceFirst(RegExp(r'^建议确认[：:，,\s]*'), '')}'
                                  : insight.body,
                              style: HomeStyle.text(12),
                            ),
                            if (insight.evidenceIds.length > 1)
                              Text(
                                '依据 ${widget.evidenceSources.where((s) => insight.evidenceIds.contains(s.id)).map((s) => '${meetingTime(s.at)} ${s.speaker}').join(' · ')}',
                                style: HomeStyle.text(
                                  10,
                                  color: HomeStyle.secondary(context),
                                ),
                              ),
                          ],
                        ),
                      ),
                    if (widget.suggestions.length > 2)
                      TextButton(
                        onPressed: () => setState(
                          () => _moreSuggestions = !_moreSuggestions,
                        ),
                        child: Text(
                          _moreSuggestions ? '收起其他建议' : '查看其他建议',
                          style: const TextStyle(fontSize: 11),
                        ),
                      ),
                    // 只有实际返回的建议仍在等待正文时才占位；首字后直接显示流。
                    if (widget.aiLoading &&
                        widget.suggestions.any(
                          (i) => i.streaming && i.body.trim().isEmpty,
                        ))
                      KnowledgeSourceSkeleton(
                        key: const ValueKey('meeting-ai-loading'),
                        reduced: MediaQuery.disableAnimationsOf(context),
                        label: 'AI 正在分析',
                      ),
                  ],
                ),
              ),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              margin: const EdgeInsets.only(bottom: 8),
              decoration: BoxDecoration(
                color: HomeStyle.tint(context),
                borderRadius: BorderRadius.circular(8),
              ),
              child: SelectableText(
                '${widget.demo
                    ? '演示原句'
                    : u.manual
                    ? '手工原文'
                    : '原始转写'} · ${meetingTime(u.at)}\n${u.raw}${showRepair ? widget.repairSources.map((s) => '\n\n关联片段 ${meetingTime(s.at)} · ${s.speaker}\n${s.raw}').join() : ''}',
                style: HomeStyle.text(12, color: HomeStyle.secondary(context)),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 保留原有独立建议样式，在绑定原话之后显示；去重在展示前完成。
class _InsightCard extends StatelessWidget {
  const _InsightCard({super.key, required this.insight, required this.record});
  final MeetingInsight insight;
  final MeetingRecord record;
  @override
  Widget build(BuildContext context) {
    final risk = insight.kind == InsightKind.risk;
    final color = risk ? Theme.of(context).colorScheme.error : HomeStyle.blue;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .045),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: .12)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                risk
                    ? Icons.warning_amber_rounded
                    : Icons.auto_awesome_outlined,
                size: 16,
                color: color,
              ),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  insight.title,
                  style: HomeStyle.text(13, bold: true, color: color),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(insight.body, style: HomeStyle.text(12)),
          const SizedBox(height: 8),
          Text(
            insight.streaming
                ? 'AI 正在推演 · 尚未确认'
                : insight.interrupted
                ? '推演中断 · 仅供参考'
                : '${record.demo ? '演示推演' : 'AI 推演'} · 尚未确认',
            style: HomeStyle.text(10, color: HomeStyle.secondary(context)),
          ),
          if (insight.kind == InsightKind.stitch)
            for (final source in record.utterances.where(
              (u) => insight.evidenceIds.contains(u.id),
            ))
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  '${meetingTime(source.at)} · ${source.speaker}\n${source.raw}',
                  style: HomeStyle.text(
                    10,
                    color: HomeStyle.secondary(context),
                  ),
                ),
              ),
        ],
      ),
    );
  }
}

class _RecordingWave extends CustomPainter {
  _RecordingWave(this.values, this.color);
  final List<double> values;
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color.withValues(alpha: .6)
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    if (values.isEmpty) {
      canvas.drawLine(
        Offset(0, size.height / 2),
        Offset(size.width, size.height / 2),
        paint,
      );
      return;
    }
    for (var i = 0; i < values.length; i++) {
      final height = (values[i] * size.height).clamp(2.0, size.height);
      final x = (i + .5) * size.width / values.length;
      canvas.drawLine(
        Offset(x, (size.height - height) / 2),
        Offset(x, (size.height + height) / 2),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _RecordingWave old) => true;
}

/// 仅结束状态使用可收起面板，展开高度上限为屏幕的 36%。
class _MeetingEndPanel extends StatefulWidget {
  const _MeetingEndPanel({required this.child});
  final Widget child;
  @override
  State<_MeetingEndPanel> createState() => _MeetingEndPanelState();
}

class _MeetingEndPanelState extends State<_MeetingEndPanel> {
  double _fraction = .28;
  @override
  Widget build(BuildContext context) {
    final screenHeight = MediaQuery.sizeOf(context).height;
    return SizedBox(
      key: const ValueKey('meeting-ended-panel'),
      height: screenHeight * _fraction,
      child: Material(
        color: HomeStyle.surface(context),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        clipBehavior: Clip.antiAlias,
        child: SafeArea(
          top: false,
          child: Column(
            children: [
              Semantics(
                label: '拖动收起或展开会议面板',
                onIncrease: () => setState(() => _fraction = .36),
                onDecrease: () => setState(() => _fraction = .10),
                child: GestureDetector(
                  key: const ValueKey('meeting-ended-drag-handle'),
                  behavior: HitTestBehavior.opaque,
                  onTap: () =>
                      setState(() => _fraction = _fraction > .20 ? .10 : .28),
                  onVerticalDragUpdate: (details) => setState(
                    () => _fraction =
                        (_fraction - details.delta.dy / screenHeight).clamp(
                          .10,
                          .36,
                        ),
                  ),
                  child: SizedBox(
                    height: 28,
                    width: double.infinity,
                    child: Center(
                      child: Container(
                        width: 36,
                        height: 4,
                        decoration: BoxDecoration(
                          color: HomeStyle.secondary(
                            context,
                          ).withValues(alpha: .25),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              Expanded(
                child: SingleChildScrollView(
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 640),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                        child: widget.child,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
