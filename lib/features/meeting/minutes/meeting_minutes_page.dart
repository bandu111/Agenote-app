import 'meeting_processing_view.dart';
import '../../../shared/widgets/content_skeleton.dart';
import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../../../core/network/api_config.dart';
import '../../home/views/home_style.dart';
import '../../knowledge/viewmodels/knowledge_view_model.dart';
import '../meeting_models.dart';
import '../meeting_remote.dart';
import '../meeting_view_model.dart';
import 'meeting_minutes_data.dart';
import 'meeting_evidence_link.dart';
import 'meeting_minutes_playback.dart';
import 'minutes_mind_map.dart';
import 'meeting_reference_focus.dart';
import '../transcript_highlights.dart';
import '../meeting_question_widgets.dart';

class MeetingMinutesPage extends StatefulWidget {
  const MeetingMinutesPage({
    super.key,
    required this.id,
    this.documentId,
    this.processing = false,
    this.previewRecord,
    this.previewData,
    this.playback,
    this.focusUtterance,
    this.focusAction,
    this.relationLabel,
    this.relationQuery,
    this.relationQuote,
  });
  final String id;
  final bool processing;
  final String? documentId;
  final String? focusUtterance;
  final String? focusAction;
  final String? relationLabel, relationQuery, relationQuote;
  // Used by deterministic visual and interaction tests, never seeds production data.
  final MeetingRecord? previewRecord;
  final MeetingMinutesData? previewData;
  final MeetingMinutesPlayback? playback;
  @override
  State<MeetingMinutesPage> createState() => _MeetingMinutesPageState();
}

class _MeetingMinutesPageState extends State<MeetingMinutesPage>
    with WidgetsBindingObserver {
  MeetingRecord? _record;
  MeetingMinutesData _data = const MeetingMinutesData();
  MeetingMinutesPlayback? _audio;
  final _scroll = ScrollController();
  final _keys = <String, GlobalKey>{};
  final _actionKeys = <String, GlobalKey>{};
  final _expandedTopics = <String>{};
  String? _selectedAction;
  bool _actionFocused = false;
  bool _relationFocused = false;
  final _relatedSources = <String>{};
  int _tab = 0, _generation = 0;
  String? _error, _taskSaving;
  String _sourceLabel = '';
  String? _playingSource;
  bool _followPlayback = true;
  Duration? _seekPreview;

  // 播放来源与引用选中独立维护；只在片段切换时滚动，静音不冒充上一段发言。
  void _playbackUpdated() {
    if (!mounted || _record == null || _audio == null) return;
    final p = _audio!.position;
    final items = _record!.utterances;
    MeetingUtterance? active;
    for (var i = 0; i < items.length; i++) {
      final u = items[i];
      final start = minutesUtteranceStart(u);
      final end = u.hasAudio
          ? u.at
          : (i + 1 < items.length
                ? minutesUtteranceStart(items[i + 1])
                : _record!.elapsed);
      if (!u.withdrawn && p >= start && p < end) active = u;
    }
    if (_playingSource != active?.id) {
      setState(() => _playingSource = active?.id);
      if (_tab == 2 && _followPlayback && _seekPreview == null) {
        _revealPlaying();
      }
    }
  }

  void _revealPlaying() {
    final id = _playingSource;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _tab != 2 || !_followPlayback || id != _playingSource) {
        return;
      }
      final target = _keys[id]?.currentContext;
      if (target != null) {
        unawaited(
          Scrollable.ensureVisible(
            target,
            alignment: .24,
            duration: MediaQuery.disableAnimationsOf(context)
                ? Duration.zero
                : const Duration(milliseconds: 220),
          ),
        );
      }
    });
  }

  void _selectTab(int tab) {
    setState(() {
      _tab = tab;
      _mapInteracting = false;
    });
    if (tab == 2 && _followPlayback) _revealPlaying();
  }

  void _playUtterance(MeetingUtterance u) {
    setState(() {
      _followPlayback = true;
    });
    unawaited(_audio?.seek(minutesUtteranceStart(u)));
  }

  Future<void> _seekRecording(Duration target) async {
    final audio = _audio;
    if (audio == null) return;
    setState(() => _followPlayback = true);
    await audio.seek(target, play: audio.playing);
    if (!mounted) return;
    setState(() => _seekPreview = null);
    _playbackUpdated();
    if (_tab == 2) _revealPlaying();
  }

  bool _loading = true;
  bool _refreshing = false;
  bool _processingDismissed = false;
  bool _deleting = false;
  bool _mapInteracting = false;
  MeetingViewModel? _viewModel;
  bool _initialSourceFocused = false;
  String? _observedMinutes;
  final _savedHighlights = TranscriptHighlightStore();

  void _restoreHighlights(MeetingRecord record) {
    final target = _viewModel?.transcriptHighlights ?? _savedHighlights;
    for (final u in record.utterances) {
      final batch = TranscriptHighlightBatch.restore(
        record.transcriptHighlights[u.id],
        u.raw,
      );
      if (batch != null) target.accept(u.id, u.raw, batch);
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (widget.previewRecord != null) {
      _record = widget.previewRecord;
      _restoreHighlights(_record!);
      _data = widget.previewData ?? MeetingMinutesData.fromRecord(_record!);
      _audio = widget.playback;
      _audio?.addListener(_playbackUpdated);
      _loading = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _focusAction();
        _focusRelation();
      });
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _viewModel = context.read<MeetingViewModel>()..addListener(_updated);
        unawaited(_load());
      });
    }
  }

  void _updated() {
    if (!mounted) return;
    final current = _viewModel?.record;
    if (_record?.ownerId != null &&
        _record!.ownerId != _viewModel?.remote?.accountId) {
      ++_generation;
      unawaited(_audio?.pause());
      setState(() {
        _record = null;
        _loading = false;
        _error = '账户已切换';
      });
      return;
    }
    if (current?.id == widget.id) {
      final signature = jsonEncode([
        current?.cloudMinutes,
        current?.minutesDetails,
      ]);
      if (!_loading &&
          !_refreshing &&
          signature != _observedMinutes &&
          (current?.cloudMinutes != null || current?.minutesDetails != null)) {
        _observedMinutes = signature;
        unawaited(_load(background: true));
      }
    }
  }

  Future<void> _load({bool background = false}) async {
    if (background && (_loading || _refreshing)) return;
    _refreshing = true;
    final generation = ++_generation;
    final vm = context.read<MeetingViewModel>();
    final owner = vm.remote?.accountId;
    bool current() =>
        mounted && generation == _generation && owner == vm.remote?.accountId;
    setState(() {
      if (!background) _loading = true;
      _error = null;
    });
    try {
      if (widget.processing) {
        final deadline = DateTime.now().add(const Duration(minutes: 3));
        while (current() && vm.busy && vm.record?.id == widget.id) {
          if (DateTime.now().isAfter(deadline)) {
            throw TimeoutException('会议保存超时，请重试');
          }
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }
        if (!current()) return;
        if (vm.storageError != null) throw StateError(vm.storageError!);
      }
      final r = await vm.readMeeting(widget.id);
      if (!current()) return;
      if (r == null) throw StateError('会议记录暂不可用');
      // Preserve transcript access even when remote minutes generation fails.
      _record = r;
      _data = MeetingMinutesData.fromRecord(r);
      var saved = r;
      if (r.ownerId != null && r.ownerId != owner) throw StateError('账户已切换');
      Map<String, dynamic>? details = saved.minutesDetails;
      if (r.ended && vm.remote != null && r.ownerId != null) {
        try {
          // 直接打开纪要页也要核对身份快照，不能依赖录音页曾经收到实时事件。
          if (vm.remote is MeetingSpeakerIdentityRemote) {
            try {
              final identities =
                  await (vm.remote as MeetingSpeakerIdentityRemote)
                      .readSpeakerIdentities(saved);
              if (!current()) return;
              final revision = identities['revision'] as int;
              if (revision >= saved.speakerIdentityRevision) {
                saved = saved.copy(
                  speakerIdentities: Map<String, dynamic>.from(
                    identities['identities'],
                  ),
                  speakerIdentityRevision: revision,
                );
                await vm.store.save(saved);
                _record = saved;
              }
            } on ApiFailure catch (error) {
              if (!current() || error.status == 401 || error.status == 403) {
                rethrow;
              }
              // Optional identity enrichment must not gate minutes generation.
              // Keep only the previously verified identity snapshot.
            }
          }
          // 进入生成/重试即明确请求处理本场会议，兼容旧版错误留下的暂缓同步标记。
          if (saved.offlineSyncHeld) {
            saved = saved.copy(
              offlineSyncHeld: false,
              recoveryPendingSync: true,
            );
            await vm.store.save(saved);
            if (vm.record?.id == saved.id) vm.record = saved;
          }
          final recoveryDeadline = DateTime.now().add(
            const Duration(minutes: 3),
          );
          while (vm.audioRecovery != null &&
              await vm.audioRecovery!.hasPending(saved)) {
            if (!current()) return;
            if (DateTime.now().isAfter(recoveryDeadline)) {
              throw const ApiFailure('录音补转写仍在处理中，请稍后重新加载');
            }
            await vm.recoverAudio();
            if (!current()) return;
            saved = vm.record?.id == saved.id ? vm.record! : saved;
            await Future<void>.delayed(const Duration(milliseconds: 300));
          }
          var archive = await vm.remote!.readArchive(saved);
          if (archive == null && saved.canGenerateMinutes) {
            if (vm.record?.id == saved.id) {
              await vm.syncCloud();
              if (!current()) return;
              saved = vm.record ?? saved;
              archive = await vm.remote!.readArchive(saved);
              // 会中分析失败不等于纪要生成失败；下面独立调用归档接口，仍校验真实引用。
            } else {
              // 历史会议也可能只在本机保存了结束状态，先同步再归档。
              saved = saved.copy(syncRevision: saved.syncRevision + 1);
              await vm.store.save(saved);
              await vm.remote!.sync(saved, paused: false);
              if (!current()) return;
            }
            if (archive == null) {
              // 页面可能读取了已结束的本机历史，而 VM 仍持有录音中的快照。
              // 归档前显式提交本场结束快照，不依赖会中同步的去重缓存。
              if (!saved.ended) {
                saved = r.copy(syncRevision: saved.syncRevision);
              }
              saved = saved.copy(
                syncRevision: saved.syncRevision + 1,
                ended: true,
              );
              await vm.store.save(saved);
              if (vm.record?.id == saved.id) vm.record = saved;
              await vm.remote!.sync(saved, paused: false);
              if (!current()) return;
              archive = await vm.remote!.archive(saved);
              if (!current()) return;
              await vm.onProgressChanged?.call().catchError((Object error) {
                if (error is ApiFailure &&
                    (error.status == 401 || error.status == 403)) {
                  throw error;
                }
                // Progress refresh is independent from the saved archive.
              });
            }
          }
          if (!current()) return;
          if (archive != null) {
            saved = saved.copy(
              title: archive['meetingTitle'] as String? ?? saved.title,
              cloudMinutes: archive['markdown'] as String?,
              speakerIdentities: archive['speakerIdentities'] is Map
                  ? Map<String, dynamic>.from(archive['speakerIdentities'])
                  : null,
              speakerIdentityRevision:
                  archive['speakerIdentityRevision'] as int?,
              minutesDetails: archive['details'] is Map
                  ? Map<String, dynamic>.from(archive['details'])
                  : null,
            );
            details = saved.minutesDetails;
            await vm.store.save(saved);
            if (archive['stale'] != true) {
              unawaited(vm.questions.afterArchive(saved));
            }
            if (!current()) return;
            if (archive['stale'] == true) {
              details = {};
              _error = '原始发言已更新，纪要待重新整理；请先核对逐字稿';
            }
          }
        } catch (failure) {
          _error = failure is ApiFailure
              ? failure.message
              : '云端生成或连接失败：${failure is TimeoutException ? "请求超时" : "请检查网络后重试"}';
          /* Preserve cached minutes for ordinary historical browsing. */
          if (!widget.processing) {
            _error = saved.cloudMinutes == null && details == null
                ? '云端纪要尚未生成，请通过右上角重新加载重试。录音与逐字稿已保留。'
                : '当前显示已保存的纪要，联网后可重新加载';
          }
        }
      }
      if (!mounted || !current()) return;
      final documentId = widget.documentId ?? saved.documentId;
      if (saved.cloudMinutes == null && documentId != null) {
        final kb = context.read<KnowledgeViewModel>();
        saved = saved.copy(
          cloudMinutes: kb.document(documentId)?.selected.content,
        );
      }
      _audio?.removeListener(_playbackUpdated);
      _audio?.dispose();
      _audio = MeetingMinutesPlayback(saved, vm.remote);
      _audio!.addListener(_playbackUpdated);
      unawaited(_audio!.prepareWaveform());
      _record = saved;
      if (vm.record?.id == saved.id) {
        _observedMinutes = jsonEncode([
          vm.record?.cloudMinutes,
          vm.record?.minutesDetails,
        ]);
      }
      _restoreHighlights(saved);
      _data = MeetingMinutesData.fromRecord(saved, details: details);
    } catch (failure) {
      if (current()) {
        _error = failure is ApiFailure
            ? failure.message
            : failure is StateError
            ? failure.message.toString()
            : failure is TimeoutException
            ? '请求超时，请稍后重试'
            : '会议纪要加载失败，请重试';
      }
    } finally {
      if (current()) {
        _refreshing = false;
        setState(() => _loading = false);
        _focusAction();
        _focusRelation();
        final source = widget.focusUtterance;
        if (!_initialSourceFocused &&
            source != null &&
            _record != null &&
            _record!.utterances.any((u) => u.id == source)) {
          _initialSourceFocused = true;
          _source(
            MinutesEntry(id: 'citation', text: '知识库引用', evidenceIds: [source]),
            '知识库引用',
          );
        }
      }
    }
  }

  void _focusAction() {
    final id = widget.focusAction;
    if (!mounted || _actionFocused || id == null || _record == null) return;
    final action = _data.actions.where((a) => a.id == id).firstOrNull;
    _actionFocused = true;
    if (action == null) {
      setState(() => _error = '该行动项已更新或移除，请查看最新纪要');
      return;
    }
    setState(() {
      _tab = 0;
      _selectedAction = action.id;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final target = _actionKeys[action.id]?.currentContext;
      if (target != null) {
        unawaited(
          Scrollable.ensureVisible(
            target,
            alignment: .3,
            duration: MediaQuery.disableAnimationsOf(context)
                ? Duration.zero
                : const Duration(milliseconds: 280),
          ),
        );
      }
    });
  }

  void _focusRelation() {
    if (!mounted ||
        _relationFocused ||
        widget.relationLabel == null ||
        _record == null) {
      return;
    }
    _relationFocused = true;
    final ids = meetingReferenceSources(
      _record!,
      quote: widget.relationQuote ?? '',
      query: widget.relationQuery ?? '',
    );
    setState(() {
      _tab = 2;
      _relatedSources.addAll(ids);
      _sourceLabel = widget.relationLabel!;
      if (ids.isEmpty) _error = '已打开关联会议，但未找到可核对的对应原话';
    });
    if (ids.isEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final target = _keys[ids.first]?.currentContext;
      if (target != null) {
        unawaited(
          Scrollable.ensureVisible(
            target,
            alignment: .28,
            duration: MediaQuery.disableAnimationsOf(context)
                ? Duration.zero
                : const Duration(milliseconds: 280),
          ),
        );
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) unawaited(_audio?.pause());
  }

  @override
  void dispose() {
    _savedHighlights.dispose();
    ++_generation;
    _viewModel?.removeListener(_updated);
    WidgetsBinding.instance.removeObserver(this);
    _audio?.removeListener(_playbackUpdated);
    if (!identical(_audio, widget.playback)) _audio?.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _source(MinutesEntry entry, String label) {
    final u = _data.source(_record!, entry);
    if (u == null) return;
    setState(() {
      _tab = 2;
      _mapInteracting = false;
      _relatedSources
        ..clear()
        ..add(u.id);
      // 空标签用于行动来源：保留定位选中，不额外展示来源说明。
      _sourceLabel = label.isEmpty
          ? ''
          : (entry.title.isNotEmpty ? entry.title : label);
      _followPlayback = true;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final target = _keys[u.id]?.currentContext;
      if (target != null) {
        unawaited(
          Scrollable.ensureVisible(
            target,
            alignment: .24,
            duration: MediaQuery.disableAnimationsOf(context)
                ? Duration.zero
                : const Duration(milliseconds: 280),
          ),
        );
      }
    });
    unawaited(_audio?.seek(minutesUtteranceStart(u)));
  }

  Future<void> _complete(MinutesEntry item) async {
    final vm = context.read<MeetingViewModel>();
    final remote = vm.remote;
    if (remote is! DioMeetingRepository ||
        item.taskId == null ||
        item.taskVersion == null ||
        _taskSaving != null) {
      return;
    }
    final owner = remote.accountId;
    setState(() => _taskSaving = item.id);
    try {
      await remote.client.post(
        'home/tasks/${Uri.encodeComponent(item.taskId!)}/${item.completed ? 'reopen' : 'complete'}',
        data: {'version': item.taskVersion},
        authenticated: true,
        accountId: owner,
      );
      if (!mounted || owner != remote.accountId) return;
      await vm.onProgressChanged?.call();
      if (mounted && owner == remote.accountId) await _load();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('任务未完成更新，请重新加载后重试')));
      }
    } finally {
      if (mounted) setState(() => _taskSaving = null);
    }
  }

  Future<void> _showMenu() async {
    final action = await showModalBottomSheet<String>(
      context: context,
      useSafeArea: true,
      showDragHandle: true,
      backgroundColor: HomeStyle.surface(context),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
      ),
      builder: (sheet) => Padding(
        key: const ValueKey('minutes-menu-sheet'),
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('会议操作', style: _text(14, bold: true)),
            const SizedBox(height: 10),
            _menuRow(
              sheet,
              action: 'reload',
              icon: Icons.refresh_rounded,
              title: '重新加载',
              subtitle: '读取最新会议纪要，不会重新分析',
            ),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Divider(height: 1, color: _line),
            ),
            _menuRow(
              sheet,
              action: 'delete',
              icon: Icons.delete_outline_rounded,
              title: '删除这场会议',
              destructive: true,
            ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    if (action == 'reload') await _load();
    if (action == 'delete') await _deleteMeeting();
  }

  Widget _menuRow(
    BuildContext sheet, {
    required String action,
    required IconData icon,
    required String title,
    String? subtitle,
    bool destructive = false,
  }) {
    final color = destructive ? const Color(0xFFAB761F) : HomeStyle.ink;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      leading: Container(
        width: 34,
        height: 34,
        decoration: BoxDecoration(
          color: destructive
              ? HomeStyle.tintColor(context, const Color(0xFFFAF5EC))
              : HomeStyle.tint(context),
          borderRadius: BorderRadius.circular(11),
        ),
        child: Icon(icon, size: 19, color: destructive ? color : _muted),
      ),
      title: Text(title, style: _text(14, color: destructive ? color : null)),
      subtitle: subtitle == null
          ? null
          : Text(subtitle, style: _text(11, color: _muted)),
      trailing: destructive
          ? null
          : Icon(Icons.chevron_right, size: 18, color: _muted),
      onTap: () => Navigator.pop(sheet, action),
    );
  }

  Future<void> _deleteMeeting() async {
    final source = _record;
    if (source == null || _deleting) return;
    final confirmed = await showAdaptiveDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog.adaptive(
        title: const Text('删除这场会议？'),
        content: const Text(
          '将清除本场录音、逐字稿和自动生成的会议纪要，删除后无法恢复。\n\n单独导入的资料不会删除；已创建的任务和日历不会撤销，但本场会议的原始依据将失效。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialog, true),
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('删除会议'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;
    setState(() => _deleting = true);
    try {
      await _audio?.pause();
      if (!mounted) return;
      await context.read<MeetingViewModel>().deleteMeetingRecord(source);
      if (!mounted) return;
      if (context.canPop()) {
        context.pop();
      } else {
        context.go('/knowledge');
      }
    } catch (error) {
      if (mounted) {
        final message = error is ApiFailure
            ? (error.code == 'meeting_revision_conflict'
                  ? '会议已更新，请重新加载后再删除'
                  : error.message)
            : '删除未完成，请重新加载后重试';
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(message)));
      }
    } finally {
      if (mounted) setState(() => _deleting = false);
    }
  }

  TextStyle _text(double size, {bool bold = false, Color? color}) =>
      HomeStyle.text(
        size,
        bold: bold,
        color:
            color ??
            (Theme.of(context).brightness == Brightness.dark
                ? HomeStyle.foreground(context)
                : HomeStyle.ink),
      );
  Color get _muted => Theme.of(context).brightness == Brightness.dark
      ? HomeStyle.secondary(context)
      : HomeStyle.muted;
  Color get _line => HomeStyle.tintColor(context, const Color(0xFFEAF0FD));

  @override
  Widget build(BuildContext context) {
    if (widget.processing &&
        !_processingDismissed &&
        (_record?.canGenerateMinutes ?? true)) {
      final remote = context.read<MeetingViewModel>().remote;
      if (remote is MeetingArchiveProgressRemote) {
        return ValueListenableBuilder<Map<String, dynamic>?>(
          valueListenable:
              (remote as MeetingArchiveProgressRemote).archiveProgress,
          builder: (context, value, _) => _processingView(
            value != null &&
                    value['meetingId'] == widget.id &&
                    value['ownerId'] ==
                        context.read<MeetingViewModel>().remote?.accountId
                ? value['progress'] as Map<String, dynamic>?
                : null,
          ),
        );
      }
      return _processingView(null);
    }
    return _buildMinutes(context);
  }

  Widget _processingView(Map<String, dynamic>? progress) {
    final valid =
        _record?.cloudMinutes != null && _record?.minutesDetails != null;
    return MeetingProcessingView(
      progress: progress,
      loading: _loading,
      title: _record?.title ?? '会议整理',
      transcripts: _record?.utterances.length ?? 0,
      actions: _data.actions.length,
      error: _loading ? null : _error ?? (valid ? null : '尚未收到完整的云端纪要结果，请重试'),
      onRetry: _load,
      onOpen: () => setState(() => _processingDismissed = true),
      onHome: () => context.go('/home'),
    );
  }

  Widget _buildMinutes(BuildContext context) => Scaffold(
    floatingActionButton: _tab == 2 && !_followPlayback
        ? FloatingActionButton.extended(
            key: const ValueKey('minutes-follow-playback'),
            onPressed: () {
              setState(() => _followPlayback = true);
              _revealPlaying();
            },
            icon: const Icon(Icons.my_location),
            label: const Text('跟随播放'),
          )
        : null,
    backgroundColor: HomeStyle.surface(context),
    appBar: AppBar(
      backgroundColor: HomeStyle.surface(context),
      surfaceTintColor: Colors.transparent,
      centerTitle: true,
      title: Text('会议纪要', style: _text(15, bold: true)),
      leading: IconButton(
        tooltip: '返回',
        icon: const Icon(
          Icons.arrow_back_ios_new_rounded,
          size: 18,
          color: HomeStyle.blue,
        ),
        onPressed: () {
          if (context.canPop()) {
            context.pop();
          } else {
            context.go('/knowledge');
          }
        },
      ),
      actions: [
        IconButton(
          tooltip: '会议操作',
          onPressed: _loading || _deleting ? null : _showMenu,
          icon: _deleting
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Icon(Icons.more_horiz, color: _muted),
        ),
      ],
    ),
    body: _loading && _record == null
        ? const ContentSkeleton(
            layout: SkeletonLayout.detail,
            label: '正在加载会议纪要',
          )
        : _record == null
        ? Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(_error ?? '会议记录不存在'),
                TextButton(onPressed: _load, child: const Text('重试')),
              ],
            ),
          )
        : SafeArea(
            top: false,
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 720),
                child: NotificationListener<ScrollStartNotification>(
                  // 仅用户拖动关闭跟随，程序定位产生的滚动不能反过来关闭自己。
                  onNotification: (event) {
                    if (_tab == 2 &&
                        event.dragDetails != null &&
                        _followPlayback) {
                      setState(() => _followPlayback = false);
                    }
                    return false;
                  },
                  child: CustomScrollView(
                    controller: _scroll,
                    physics: _mapInteracting
                        ? const NeverScrollableScrollPhysics()
                        : null,
                    slivers: [
                      SliverToBoxAdapter(child: _header()),
                      SliverPersistentHeader(
                        pinned: true,
                        delegate: _MinutesTabs(
                          surface: HomeStyle.surface(context),
                          tint: HomeStyle.tint(context),
                          ink: HomeStyle.foreground(context),
                          muted: _muted,
                          selected: _tab,
                          onSelect: _selectTab,
                        ),
                      ),
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
                        sliver: SliverToBoxAdapter(
                          child: switch (_tab) {
                            0 => _minutes(),
                            1 => MinutesMindMap(
                              record: _record!,
                              data: _data,
                              onSource: (e) => _source(e, '议题来源'),
                              onInteractionChanged: (active) {
                                if (mounted && _mapInteracting != active) {
                                  setState(() => _mapInteracting = active);
                                }
                              },
                            ),
                            _ => _transcript(),
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
  );

  Widget _header() {
    final r = _record!;
    return Container(
      color: HomeStyle.tint(context),
      padding: const EdgeInsets.fromLTRB(22, 16, 22, 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            r.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: _text(26, bold: true),
          ),
          const SizedBox(height: 8),
          Text(
            '${r.startedAt.year} 年 ${r.startedAt.month} 月 ${r.startedAt.day} 日  ·  ${r.elapsed.inMinutes >= 1 ? '${r.elapsed.inMinutes} 分钟' : '${r.elapsed.inSeconds} 秒'}  ·  会议录音',
            style: _text(12, color: _muted),
          ),
          const SizedBox(height: 7),
          // 状态与分析标记同行，长状态单行截断，为右侧标记保留空间。
          Row(
            key: const ValueKey('minutes-header-status'),
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              const Icon(
                Icons.check_circle,
                size: 12,
                color: Color(0xFF78A3FF),
              ),
              const SizedBox(width: 5),
              Expanded(
                child: Text(
                  '${r.ended ? '会议已结束' : '会议进行中'}  ·  逐字稿 ${r.utterances.length} 段',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: _text(12, color: _muted),
                ),
              ),
              const SizedBox(width: 10),
              Row(
                key: const ValueKey('minutes-analysis-badge'),
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.auto_awesome,
                    size: 13,
                    color: HomeStyle.blue,
                  ),
                  const SizedBox(width: 5),
                  Text(
                    _data.summary.isNotEmpty ? 'AI 已分析' : '录音已保存',
                    style: _text(12, color: HomeStyle.blue),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 18),
          _recording(),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(_error!, style: _text(12, color: _muted)),
            ),
        ],
      ),
    );
  }

  Widget _recording() => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
    decoration: BoxDecoration(
      color: HomeStyle.surface(context),
      borderRadius: BorderRadius.circular(18),
    ),
    child: ListenableBuilder(
      listenable: _audio ?? const AlwaysStoppedAnimation(0),
      builder: (context, _) => Row(
        children: [
          _playButton(),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(child: Text('会议录音', style: _text(13))),
                    Text(
                      // 时间统一放在标题右侧，播放与拖动预览共用同一进度。
                      '${meetingTime(_seekPreview ?? _audio?.position ?? Duration.zero)} / ${meetingTime(_record!.elapsed)}',
                      key: const ValueKey('minutes-recording-time'),
                      style: _text(11, color: _muted),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                LayoutBuilder(
                  builder: (context, constraints) {
                    final total = _record!.elapsed.inMilliseconds;
                    final position =
                        _seekPreview ?? _audio?.position ?? Duration.zero;
                    final progress = total > 0
                        ? (position.inMilliseconds / total)
                              .clamp(0.0, 1.0)
                              .toDouble()
                        : 0.0;
                    final enabled =
                        _audio != null && !_audio!.loading && total > 0;
                    Duration target(double x) => Duration(
                      milliseconds: (x / constraints.maxWidth * total)
                          .clamp(0, total)
                          .round(),
                    );
                    // 波形与无振幅数据时的中性轨道共用时间轴，拖动预览只在松手后提交一次定位。
                    return Semantics(
                      label: '会议录音播放进度',
                      value: meetingTime(position),
                      increasedValue: enabled
                          ? meetingTime(
                              Duration(
                                milliseconds: (position.inMilliseconds + 5000)
                                    .clamp(0, total),
                              ),
                            )
                          : null,
                      decreasedValue: enabled
                          ? meetingTime(
                              Duration(
                                milliseconds: (position.inMilliseconds - 5000)
                                    .clamp(0, total),
                              ),
                            )
                          : null,
                      onIncrease: enabled
                          ? () => _seekRecording(
                              position + const Duration(seconds: 5),
                            )
                          : null,
                      onDecrease: enabled
                          ? () => _seekRecording(
                              position - const Duration(seconds: 5),
                            )
                          : null,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          GestureDetector(
                            key: const ValueKey('minutes-recording-waveform'),
                            behavior: HitTestBehavior.opaque,
                            onTapUp: enabled
                                ? (e) =>
                                      _seekRecording(target(e.localPosition.dx))
                                : null,
                            onHorizontalDragStart: enabled
                                ? (e) => setState(
                                    () => _seekPreview = target(
                                      e.localPosition.dx,
                                    ),
                                  )
                                : null,
                            onHorizontalDragUpdate: enabled
                                ? (e) => setState(
                                    () => _seekPreview = target(
                                      e.localPosition.dx,
                                    ),
                                  )
                                : null,
                            onHorizontalDragEnd: enabled
                                ? (_) =>
                                      _seekRecording(_seekPreview ?? position)
                                : null,
                            onHorizontalDragCancel: () =>
                                setState(() => _seekPreview = null),
                            child: SizedBox(
                              height: 44,
                              child: Center(
                                child: SizedBox(
                                  height: 18,
                                  width: double.infinity,
                                  child: _audio?.waveform.isNotEmpty == true
                                      ? CustomPaint(
                                          painter: _MinutesWaveform(
                                            _audio!.waveform,
                                            progress,
                                          ),
                                        )
                                      : LinearProgressIndicator(
                                          value: progress,
                                          minHeight: 4,
                                          color: HomeStyle.blue,
                                          backgroundColor: HomeStyle.tint(
                                            context,
                                          ),
                                        ),
                                ),
                              ),
                            ),
                          ),
                          if (_audio?.error != null)
                            Padding(
                              padding: const EdgeInsets.only(top: 6),
                              child: Text(
                                _audio!.error!,
                                style: _text(11, color: _muted),
                              ),
                            ),
                        ],
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: '打开逐字稿',
            onPressed: () => _selectTab(2),
            icon: Icon(Icons.chevron_right, size: 20, color: _muted),
          ),
        ],
      ),
    ),
  );

  Widget _playButton() => SizedBox(
    width: 38,
    height: 38,
    child: IconButton.filled(
      tooltip: _audio?.playing == true ? '暂停回放' : '播放会议录音',
      onPressed: _audio == null || _audio!.loading ? null : _audio!.toggle,
      style: IconButton.styleFrom(
        backgroundColor: HomeStyle.blue,
        disabledBackgroundColor: HomeStyle.tint(context),
        padding: EdgeInsets.zero,
      ),
      icon: _audio?.loading == true
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Icon(
              _audio?.playing == true
                  ? Icons.pause_rounded
                  : Icons.play_arrow_rounded,
              color: Colors.white,
              size: 24,
            ),
    ),
  );

  Widget _heading(String text, [String? trailing, bool marked = true]) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 18),
        child: Row(
          children: [
            if (marked) ...[
              Container(
                key: ValueKey('minutes-heading-bar-$text'),
                width: 3,
                height: 18,
                decoration: BoxDecoration(
                  color: HomeStyle.blue,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 9),
            ],
            Expanded(child: Text(text, style: _text(18, bold: true))),
            if (trailing != null)
              Text(trailing, style: _text(11, color: _muted)),
          ],
        ),
      );
  Widget _divider() => Padding(
    padding: const EdgeInsets.symmetric(vertical: 24),
    child: Divider(height: 1, color: _line),
  );
  Widget _empty(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(text, style: _text(14, color: _muted)),
  );

  Widget _evidence(
    MinutesEntry entry,
    String label, {
    double topSpacing = 8,
    bool compact = false,
    bool inline = false,
  }) {
    final source = _data.source(_record!, entry);
    if (source == null) return const SizedBox.shrink();
    return MeetingEvidenceLink(
      at: minutesUtteranceStart(source),
      label: label,
      onPressed: () => _source(entry, label),
      topSpacing: topSpacing,
      compact: compact,
      inline: inline,
    );
  }

  Widget _myQuestions({List<String>? sourceIds, bool compact = false}) =>
      _viewModel == null
      ? const SizedBox.shrink()
      : MeetingQuestionList(
          questions: _viewModel!.questions,
          record: _record!,
          minutesStyle: !compact && sourceIds == null,
          sourceIds: sourceIds,
          compact: compact,
          transcriptBadge: sourceIds != null && compact,
          onSource: (id) => _source(
            MinutesEntry(id: id, text: '', evidenceIds: [id]),
            '我的疑问',
          ),
        );

  Widget _topic(MinutesEntry topic, int index) {
    // 各议题默认折叠，仅记录主动展开的议题；标题始终单行，正文与来源一起收起。
    final identity = '${topic.id}-$index';
    final expanded = _expandedTopics.contains(identity);
    return Padding(
      key: ValueKey('minutes-topic-$index'),
      padding: EdgeInsets.only(bottom: expanded ? 8 : 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            key: ValueKey('minutes-topic-header-$index'),
            children: [
              Text(
                (index + 1).toString().padLeft(2, '0'),
                style: _text(11, color: HomeStyle.blue),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  topic.title.isEmpty ? topic.text : topic.title,
                  key: ValueKey('minutes-topic-title-$index'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: _text(15).copyWith(fontWeight: FontWeight.w500),
                ),
              ),
              IconButton(
                key: ValueKey('minutes-topic-toggle-$index'),
                // 压缩默认按钮占位，避免折叠列表被触控留白撑高。
                padding: const EdgeInsets.all(4),
                constraints: const BoxConstraints(minWidth: 36, minHeight: 32),
                style: IconButton.styleFrom(
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                iconSize: 20,
                tooltip: expanded ? '折叠议题' : '展开议题',
                isSelected: expanded,
                onPressed: () => setState(() {
                  if (expanded) {
                    _expandedTopics.remove(identity);
                  } else {
                    _expandedTopics.add(identity);
                  }
                }),
                icon: Icon(
                  expanded ? Icons.expand_less : Icons.expand_more,
                  color: _muted,
                ),
              ),
            ],
          ),
          if (expanded) ...[
            Text(
              topic.text,
              key: ValueKey('minutes-topic-body-$index'),
              style: _text(14, color: _muted).copyWith(height: 1.8),
            ),
            _evidence(topic, '查看原始依据', topSpacing: 4, compact: true),
          ],
        ],
      ),
    );
  }

  Widget _minutes() =>
      !_record!.canGenerateMinutes && _record!.cloudMinutes == null
      ? Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _heading('录音已保留'),
            _empty('会议不足 1 分钟，不生成纪要。录音和逐字稿已保留。'),
            TextButton(
              onPressed: () => setState(() => _tab = 2),
              child: const Text('查看逐字稿'),
            ),
          ],
        )
      : Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _heading('一页读懂会议'),
            !_record!.canGenerateMinutes && _record!.cloudMinutes == null
                ? _empty('会议不足 1 分钟，不生成纪要。录音和逐字稿已保留。')
                : _data.summary.isEmpty
                ? _empty('尚未形成会议概览')
                : Text(_data.summary, style: _text(15).copyWith(height: 1.8)),
            _divider(),
            _heading('主要讨论', '${_data.topics.length} 个议题'),
            if (_data.topics.isEmpty) _empty('暂无已整理的议题，可在逐字稿中查看原始发言'),
            for (final (i, topic) in _data.topics.indexed) _topic(topic, i),
            _divider(),
            _heading('会议结论'),
            if (_data.decisions.isEmpty) _empty('暂无明确结论'),
            for (final entry in _data.decisions)
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Icon(
                        entry.status == 'confirmed'
                            ? Icons.check_circle
                            : Icons.help,
                        size: 16,
                        color: entry.status == 'confirmed'
                            ? HomeStyle.blue
                            : entry.status == 'discussed'
                            ? _muted
                            : const Color(0xFFD79B27),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        entry.text,
                        style: _text(14).copyWith(height: 1.7),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: HomeStyle.tint(context),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(switch (entry.status) {
                        'confirmed' => '已明确',
                        'discussed' => '讨论中',
                        _ => '待确认',
                      }, style: _text(10, color: HomeStyle.blue)),
                    ),
                  ],
                ),
              ),
            _divider(),
            _heading(
              '后续行动',
              '${_data.actions.where((i) => i.completed).length}/${_data.actions.length} 已完成',
            ),
            if (_data.actions.isEmpty) _empty('暂无明确后续行动'),
            for (final action in _data.actions) _action(action),
            _divider(),
            _heading('待澄清', '${_data.questions.length} 个问题'),
            if (_data.questions.isEmpty) _empty('暂无待澄清问题'),
            for (final question in _data.questions)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border.all(color: _line),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Theme(
                    data: Theme.of(
                      context,
                    ).copyWith(dividerColor: Colors.transparent),
                    child: ExpansionTile(
                      tilePadding: const EdgeInsets.symmetric(horizontal: 12),
                      childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                      leading: const Icon(
                        Icons.help_outline,
                        size: 15,
                        color: Color(0xFF86A0CD),
                      ),
                      title: Text(question.text, style: _text(13)),
                      children: [
                        Container(
                          key: ValueKey(
                            'minutes-question-inference-${question.id}',
                          ),
                          width: double.infinity,
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: HomeStyle.tint(context),
                            borderRadius: BorderRadius.circular(12),
                            border: const Border(
                              left: BorderSide(
                                color: Color(0xFF9CBDFF),
                                width: 2,
                              ),
                            ),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 7,
                                  vertical: 3,
                                ),
                                decoration: BoxDecoration(
                                  color: HomeStyle.tintColor(
                                    context,
                                    const Color(0xFFFFF6E7),
                                  ),
                                  borderRadius: BorderRadius.circular(5),
                                ),
                                child: Text(
                                  'AI 推测·未经会议确认',
                                  style: _text(
                                    10,
                                    color: const Color(0xFFAE7417),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                '这一问题尚需参会人确认。相关发言：',
                                style: _text(13, color: _muted),
                              ),
                              for (final u in _record!.utterances.where(
                                (u) => question.evidenceIds.contains(u.id),
                              )) ...[
                                const SizedBox(height: 7),
                                Text(
                                  '${_record!.speakerDisplayName(u)} · ${meetingTime(minutesUtteranceStart(u))}：${u.display}',
                                  style: _text(
                                    13,
                                    color: _muted,
                                  ).copyWith(height: 1.8),
                                ),
                              ],
                            ],
                          ),
                        ),
                        _evidence(question, '查看原始依据'),
                      ],
                    ),
                  ),
                ),
              ),
            _myQuestions(),
          ],
        );

  Widget _action(MinutesEntry action) => Container(
    key: _actionKeys.putIfAbsent(action.id, GlobalKey.new),
    decoration: BoxDecoration(
      color: _selectedAction == action.id ? HomeStyle.tint(context) : null,
      borderRadius: BorderRadius.circular(12),
      border: _selectedAction == action.id
          ? Border.all(color: const Color(0xFFBED2FF))
          : null,
    ),
    padding: const EdgeInsets.only(bottom: 16),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 24,
          child: action.taskId == null
              ? Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Icon(
                    action.completed ? Icons.check_circle : Icons.remove,
                    size: 18,
                    color: action.completed
                        ? HomeStyle.blue
                        : const Color(0xFFBDCCEA),
                  ),
                )
              : IconButton(
                  tooltip: action.completed ? '撤销完成' : '标记任务已完成',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 24,
                    minHeight: 44,
                  ),
                  onPressed: _taskSaving == null
                      ? () => _complete(action)
                      : null,
                  icon: _taskSaving == action.id
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(
                          Icons.radio_button_unchecked,
                          size: 18,
                          color: Color(0xFFBDCCEA),
                        ),
                ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                action.text,
                style: _text(14, color: action.completed ? _muted : null)
                    .copyWith(
                      decoration: action.completed
                          ? TextDecoration.lineThrough
                          : null,
                      height: 1.7,
                    ),
              ),
              const SizedBox(height: 2),
              // 跳转仅占内容本身的宽度，剩余空间全部留给负责人和时间。
              Row(
                key: ValueKey('minutes-action-meta-${action.id}'),
                children: [
                  Expanded(
                    child: Text(
                      '${action.owner ?? '负责人未明确'} · ${action.deadlineLabel ?? '截止时间未提及'}',
                      style: _text(11, color: _muted),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IntrinsicWidth(
                    child: action.completed
                        ? Text('✓ 已完成', style: _text(12, color: HomeStyle.blue))
                        : _evidence(
                            action,
                            '',
                            topSpacing: 0,
                            compact: true,
                            inline: true,
                          ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    ),
  );

  Widget _transcript() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      _heading('逐字稿', '${_record!.utterances.length} 段 · 自动转写', false),
      Padding(
        padding: const EdgeInsets.only(bottom: 20),
        child: Text('发言人标识用于区分声音，未识别真实身份', style: _text(11, color: _muted)),
      ),
      if (_record!.utterances.isEmpty) _empty('暂无逐字稿，原始录音仍会保留'),
      for (final u in _record!.utterances) _utterance(u),
    ],
  );

  Widget _utterance(MeetingUtterance u) =>
      ValueListenableBuilder<TranscriptHighlightBatch?>(
        valueListenable: (_viewModel?.transcriptHighlights ?? _savedHighlights)
            .forSource(u.id),
        builder: (context, batch, _) => _utteranceBody(
          u,
          highlighted:
              !u.withdrawn &&
              u.correction == null &&
              (_data.importantSourceIds.contains(u.id) ||
                  (batch != null &&
                      batch.raw == u.raw &&
                      batch.items.isNotEmpty)),
        ),
      );

  Widget _utteranceBody(MeetingUtterance u, {required bool highlighted}) {
    // 整卡框选只取实际播放位置；来源引用仅显示标签，不能与当前回放竞争选中态。
    final current = _playingSource == u.id;
    final referenced = _relatedSources.contains(u.id);
    return Padding(
      key: _keys.putIfAbsent(u.id, GlobalKey.new),
      padding: const EdgeInsets.only(bottom: 10),
      // 卡片空白和普通正文均可播放；内部术语/按钮的手势优先，长按和滚动不触发点击。
      child: GestureDetector(
        key: ValueKey('minutes-play-source-${u.id}'),
        behavior: HitTestBehavior.opaque,
        onTap: () => _playUtterance(u),
        onLongPress: () {},
        child: AnimatedContainer(
          key: ValueKey('minutes-playback-card-${u.id}'),
          duration: MediaQuery.disableAnimationsOf(context)
              ? Duration.zero
              : const Duration(milliseconds: 180),
          decoration: BoxDecoration(
            color: current ? HomeStyle.tint(context) : Colors.transparent,
            border: Border.all(
              color: current ? const Color(0xFFBED2FF) : Colors.transparent,
            ),
            borderRadius: BorderRadius.circular(14),
          ),
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 48,
                child: Padding(
                  padding: const EdgeInsets.only(top: 25),
                  child: InkWell(
                    onTap: () => _playUtterance(u),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 44),
                      child: Text(
                        meetingTime(minutesUtteranceStart(u)),
                        style: _text(
                          11,
                          color: current ? HomeStyle.blue : _muted,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 三种文字按字体基线对齐；统一字号，避免标签内边距及缩放造成视觉错位。
                    Row(
                      key: ValueKey('minutes-speaker-row-${u.id}'),
                      crossAxisAlignment: CrossAxisAlignment.baseline,
                      textBaseline: TextBaseline.alphabetic,
                      children: [
                        Flexible(
                          flex: 3,
                          child: Container(
                            key: ValueKey('minutes-speaker-${u.id}'),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              // 选中时用白底区分标签与片段底色，未选中沿用原样式。
                              color: current
                                  ? Colors.white
                                  : HomeStyle.tint(context),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              _record!.speakerDisplayName(u),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: _text(
                                11,
                                color: current ? HomeStyle.blue : _muted,
                              ),
                            ),
                          ),
                        ),
                        if (highlighted)
                          Padding(
                            padding: const EdgeInsets.only(left: 7),
                            child: Container(
                              key: ValueKey('minutes-important-${u.id}'),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: HomeStyle.blue,
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                '重点',
                                style: _text(
                                  11,
                                  color: Colors.white,
                                  bold: true,
                                ),
                              ),
                            ),
                          ),
                        if (current && _audio != null)
                          ListenableBuilder(
                            listenable: _audio!,
                            builder: (_, _) => _audio!.playing
                                ? Flexible(
                                    flex: 2,
                                    child: Padding(
                                      padding: const EdgeInsets.only(left: 7),
                                      child: Text(
                                        '正在回放',
                                        key: ValueKey(
                                          'minutes-playing-${u.id}',
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: _text(11, color: HomeStyle.blue),
                                      ),
                                    ),
                                  )
                                : const SizedBox.shrink(),
                          ),
                      ],
                    ),
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Wrap(
                        spacing: 7,
                        runSpacing: 4,
                        children: [
                          _myQuestions(sourceIds: [u.id], compact: true),
                          if (referenced && _sourceLabel.isNotEmpty)
                            Text(
                              _sourceLabel,
                              key: ValueKey('minutes-reference-label-${u.id}'),
                              style: _text(11, color: HomeStyle.blue),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                    MeetingHighlightedText(
                      key: ValueKey('minutes-annotated-transcript-${u.id}'),
                      // 按 correction > cleaned > raw 展示并重新匹配唯一引用，不改写原文或复用旧偏移。
                      text: u.display,
                      sources: [u],
                      store:
                          _viewModel?.transcriptHighlights ?? _savedHighlights,
                      classify: _viewModel != null && !u.withdrawn,
                      useRawText: false,
                      paragraphEmphasis: true,
                      paragraphImportant: highlighted,
                      style: _text(14, color: u.withdrawn ? _muted : null)
                          .copyWith(
                            height: 1.8,
                            decoration: u.withdrawn
                                ? TextDecoration.lineThrough
                                : null,
                          ),
                    ),
                    if (u.withdrawn)
                      Text('已撤回', style: _text(11, color: _muted)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MinutesTabs extends SliverPersistentHeaderDelegate {
  _MinutesTabs({
    required this.surface,
    required this.tint,
    required this.ink,
    required this.muted,
    required this.selected,
    required this.onSelect,
  });
  final Color surface, tint, ink, muted;
  final int selected;
  final ValueChanged<int> onSelect;
  @override
  double get minExtent => 58;
  @override
  double get maxExtent => 58;
  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) => Container(
    color: surface,
    padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: tint,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          for (final (i, title) in ['AI 纪要', '思维导图', '逐字稿'].indexed)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(3),
                child: Semantics(
                  selected: selected == i,
                  button: true,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(9),
                    onTap: () => onSelect(i),
                    child: AnimatedContainer(
                      duration: MediaQuery.disableAnimationsOf(context)
                          ? Duration.zero
                          : const Duration(milliseconds: 160),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: selected == i ? surface : Colors.transparent,
                        borderRadius: BorderRadius.circular(9),
                        boxShadow: selected == i
                            ? const [
                                BoxShadow(
                                  color: Color(0x0F466CB0),
                                  blurRadius: 3,
                                  offset: Offset(0, 1),
                                ),
                              ]
                            : [],
                      ),
                      child: Text(
                        title,
                        style: HomeStyle.text(
                          13,
                          bold: selected == i,
                          color: selected == i ? ink : muted,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    ),
  );
  @override
  bool shouldRebuild(covariant _MinutesTabs old) =>
      old.selected != selected || old.surface != surface || old.ink != ink;
}

class _MinutesWaveform extends CustomPainter {
  const _MinutesWaveform(this.values, this.progress);
  final double progress;
  final List<double> values;
  @override
  void paint(Canvas canvas, Size size) {
    if (values.isEmpty) return;
    final paint = Paint()..color = const Color(0xFFBED6FF);
    final step = size.width / values.length;
    for (var i = 0; i < values.length; i++) {
      paint.color = i / values.length < progress
          ? HomeStyle.blue
          : const Color(0xFFBED6FF);
      final height = 3 + values[i].clamp(0, 1) * (size.height - 3);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(
            i * step,
            (size.height - height) / 2,
            step * .6,
            height,
          ),
          const Radius.circular(2),
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _MinutesWaveform old) =>
      !identical(values, old.values) || progress != old.progress;
}
