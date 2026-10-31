import 'dart:async';
import 'package:flutter/widgets.dart';
import '../repositories/dio_progress_repository.dart';
import '../../../core/network/api_config.dart';
import '../models/progress_models.dart';
import '../repositories/progress_repository.dart';

class ProgressViewModel extends ChangeNotifier with WidgetsBindingObserver {
  ProgressViewModel(this.repository) {
    try {
      _binding = WidgetsBinding.instance..addObserver(this);
    } catch (_) {
      /* Headless model tests have no binding. */
    }
    _clock = Timer.periodic(const Duration(seconds: 30), (_) {
      _emit();
      _refreshRemote();
    });
  }
  void _refreshRemote() {
    if (!_disposed &&
        !loading &&
        !saving &&
        repository is AccountProgressRepository &&
        _owner != null &&
        _binding?.lifecycleState == AppLifecycleState.resumed) {
      unawaited(load(silent: true));
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refreshRemote();
  }

  String? get dataWarning =>
      repository is DioProgressRepository &&
          (repository as DioProgressRepository).skippedRows > 0
      ? '部分进展资料不完整，已保留有效记录，请刷新核对'
      : null;
  bool canConfirm(Commitment item) =>
      !item.reviewPending &&
      !data.pending.any((p) => p.id == item.id && p.reviewPending) &&
      item.status == CommitmentStatus.pending &&
      item.statusAt(DateTime.now()) != CommitmentStatus.overdue;
  Future<bool> confirmCommitment(Commitment expected) {
    final current = commitment(expected.id);
    if (current == null ||
        !canConfirm(current) ||
        current.confirmationKey != expected.confirmationKey) {
      actionError = '承诺已更新或正在复核，请刷新核对后确认';
      _emit();
      return Future.value(false);
    }
    return _save(
      () => repository is DioProgressRepository
          ? (repository as DioProgressRepository).confirmCommitment(expected)
          : repository.updateCommitment(
              expected.id,
              CommitmentStatus.planned,
              '用户明确确认当前版本承诺成立',
            ),
    );
  }

  WidgetsBinding? _binding;
  late final Timer _clock;
  final ProgressRepository repository;
  ProgressSnapshot _data = const ProgressSnapshot();
  String? _loadedOwner;
  int accountScopeRevision = 0;
  String? get _owner => repository is AccountProgressRepository
      ? (repository as AccountProgressRepository).accountId
      : null;
  bool get _accountMatches =>
      repository is! AccountProgressRepository || _loadedOwner == _owner;
  ProgressSnapshot get data =>
      _accountMatches ? _data : const ProgressSnapshot(demo: false);
  String? _observedOwner;
  void refreshAccount() {
    if (repository is! AccountProgressRepository || _observedOwner == _owner) {
      return;
    }
    _observedOwner = _owner;
    accountScopeRevision++;
    ++_loadRevision;
    _data = const ProgressSnapshot(demo: false);
    error = null;
    Future.microtask(() {
      if (!_disposed) load();
    });
  }

  bool loading = true, saving = false;
  String? error, actionError;
  CommitmentSide side = CommitmentSide.ours;
  ArtifactFilter artifactFilter = ArtifactFilter.all;
  bool allGoals = false, allCommitments = false;
  bool _disposed = false;
  int _loadRevision = 0;

  Future<void> load({bool silent = false}) async {
    final revision = ++_loadRevision;
    final owner = _owner;
    if (!silent) loading = true;
    error = null;
    _emit();
    try {
      final result = await repository.load();
      if (_disposed || revision != _loadRevision || owner != _owner) return;
      _data = result;
      _loadedOwner = owner;
    } catch (_) {
      if (_disposed || revision != _loadRevision || owner != _owner) return;
      error = '进展暂时加载失败，请重试';
    }
    if (_disposed || revision != _loadRevision || owner != _owner) return;
    loading = false;
    _emit();
  }

  // 撤回记录保留在数据中用于核对；当前列表、目标关联及本地搜索统一排除，刷新后也不会重新出现。
  List<Commitment> get listedCommitments => data.commitments
      .where((c) => c.status != CommitmentStatus.withdrawn)
      .toList();
  List<Commitment> get selectedCommitments =>
      listedCommitments.where((c) => c.side == side).toList();
  List<Commitment> get visibleCommitments => allCommitments
      ? selectedCommitments
      : selectedCommitments.take(1).toList();
  List<ProgressGoal> get visibleGoals =>
      allGoals ? data.goals : data.goals.take(1).toList();
  List<ProgressArtifact> get visibleArtifacts =>
      data.artifacts.where(artifactFilter.matches).toList();
  int followUpCount(CommitmentSide value) => data.commitments
      .where((c) => c.side == value && c.status.needsFollowUp)
      .length;
  int artifactCount(ArtifactFilter value) =>
      data.artifacts.where(value.matches).length;
  List<Commitment> commitmentsFor(String goalId) =>
      listedCommitments.where((c) => c.goalId == goalId).toList();
  List<ProgressArtifact> artifactsFor(String goalId) =>
      data.artifacts.where((a) => a.goalId == goalId).toList();
  ProgressGoal? goal(String id) => _find(data.goals, (g) => g.id == id);
  Commitment? commitment(String id) =>
      _find(data.commitments, (c) => c.id == id);
  ProgressArtifact? artifact(String id) =>
      _find(data.artifacts, (a) => a.id == id);
  T? _find<T>(Iterable<T> source, bool Function(T) test) {
    for (final item in source) {
      if (test(item)) return item;
    }
    return null;
  }

  void selectSide(CommitmentSide value) {
    side = value;
    _emit();
  }

  void selectArtifacts(ArtifactFilter value) {
    artifactFilter = value;
    _emit();
  }

  void toggleGoals() {
    allGoals = !allGoals;
    _emit();
  }

  void toggleCommitments() {
    allCommitments = !allCommitments;
    _emit();
  }

  void showAllArtifacts() {
    artifactFilter = ArtifactFilter.all;
    _emit();
  }

  List<ProgressSearchHit> search(String query) {
    final term = query.trim().toLowerCase();
    if (term.isEmpty) return [];
    final hits = [
      ...data.goals.map(
        (g) =>
            ProgressSearchHit('目标', g.title, g.code, '/progress/goals/${g.id}'),
      ),
      ...listedCommitments.map(
        (c) => ProgressSearchHit(
          '承诺',
          c.title,
          '${c.side.itemLabel} · ${c.evidence.transcript}',
          '/progress/commitments/${c.id}',
        ),
      ),
      ...data.artifacts.map(
        (a) => ProgressSearchHit(
          '通知',
          a.title,
          a.status == ArtifactStatus.confirmation ? '确认这份成果' : a.status.label,
          '/notifications',
        ),
      ),
    ];
    return hits
        .where((h) => '${h.title} ${h.subtitle}'.toLowerCase().contains(term))
        .toList();
  }

  Future<bool> _save(Future<void> Function() operation) async {
    if (saving || _disposed) return false;
    saving = true;
    final owner = _owner;
    actionError = null;
    ++_loadRevision;
    _emit();
    try {
      await operation();
      if (_disposed || owner != _owner) return false;
      final revision = ++_loadRevision;
      final result = await repository.load();
      if (_disposed || owner != _owner) return false;
      if (revision != _loadRevision) return true;
      if (_disposed || owner != _owner) return false;
      _data = result;
      _loadedOwner = owner;
      return true;
    } catch (failure) {
      if (!_disposed && owner == _owner) {
        actionError = failure is ApiFailure
            ? failure.message
            : '更新未完成，请重试并核对当前状态';
      }
      return false;
    } finally {
      if (!_disposed) {
        saving = false;
        _emit();
      }
    }
  }

  Future<bool> updateCommitment(
    String id,
    CommitmentStatus status,
    String note,
  ) => _save(() => repository.updateCommitment(id, status, note));
  bool get supportsGoalConfirmation => repository is GoalConfirmationRepository;
  Future<bool> confirmGoal(ProgressGoal expected) async {
    if (!identical(goal(expected.id), expected) || !supportsGoalConfirmation) {
      actionError = '目标已更新，请刷新后重新确认';
      _emit();
      return false;
    }
    return _save(
      () => (repository as GoalConfirmationRepository).confirmGoal(expected.id),
    );
  }

  bool get supportsGoalRemoval => repository is GoalRemovalRepository;
  Future<bool> removeGoal(ProgressGoal expected) async {
    if (!identical(goal(expected.id), expected) || !supportsGoalRemoval) {
      actionError = '目标已更新，请刷新后重新确认';
      _emit();
      return false;
    }
    final saved = await _save(
      () => (repository as GoalRemovalRepository).removeGoal(expected.id),
    );
    if (saved && goal(expected.id) != null) {
      actionError = '移除状态尚未确认，请刷新后重试';
      _emit();
      return false;
    }
    return saved;
  }

  Future<bool> completeMissing(
    PendingProgressItem item, {
    CommitmentSide? side,
    DateTime? deadline,
  }) {
    final repo = repository;
    if (repo is! ProgressCompletionRepository ||
        !data.pending.any(
          (p) => p.id == item.id && p.version == item.version,
        )) {
      return Future.value(false);
    }
    return _save(
      () => (repo as ProgressCompletionRepository).completeMissing(
        item,
        side: side,
        deadline: deadline,
      ),
    );
  }

  Future<bool> reschedule(String id, DateTime deadline, String reason) =>
      _save(() => repository.rescheduleCommitment(id, deadline, reason));
  Future<bool> approveArtifact(String id, String note) =>
      _save(() => repository.approveArtifact(id, note));
  void _emit() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _binding?.removeObserver(this);
    _clock.cancel();
    _disposed = true;
    ++_loadRevision;
    super.dispose();
  }
}
