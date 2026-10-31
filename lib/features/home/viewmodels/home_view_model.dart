import 'package:flutter/foundation.dart';
import 'dart:async';
import '../repositories/dio_home_repository.dart';
import '../../progress/models/progress_models.dart';

/// 首页账户数据与显式演示状态分开；设备状态不冒充硬件授权。
class HomeViewModel extends ChangeNotifier {
  HomeViewModel({this.repository});
  final DioHomeRepository? repository;
  Map<String, dynamic> data = {};
  String? error;
  bool loading = false;
  String? _owner;
  bool _disposed = false, _demo = false;
  int _revision = 0;
  Timer? _timer;
  bool get isDemo => _demo;
  bool get usesAccountData => repository != null && !_demo;
  ProgressGoal? get situationGoal {
    final value = data['situationGoal'];
    if (_demo || value is! Map) return null;
    final end = DateTime.tryParse(value['deadline'] ?? '');
    if (end != null && !DateTime.now().isBefore(end)) return null;
    return ProgressGoal(
      id: value['id'],
      title: value['title'],
      code: value['code'] ?? '',
      phase: value['phase'] ?? '待明确',
      condition: value['condition'],
      acceptance: value['acceptance'] ?? '待明确',
      deadline: end,
      status: GoalStatus.values.byName(value['status']),
      milestones: [
        for (final m in value['milestones'] ?? [])
          Milestone(
            m['title'],
            weight: m['weight'],
            status: MilestoneStatus.values.byName(m['status']),
            statusBasis: m['statusBasis'],
          ),
      ],
      history: const [],
      projectId: value['projectId'],
    );
  }

  bool get hasSessionData =>
      _demo || (data['rows'] as List? ?? []).isNotEmpty || decisions.isNotEmpty;
  List<Map<String, dynamic>> get decisions => [
    for (final d in data['decisions'] as List? ?? [])
      Map<String, dynamic>.from(d),
  ];
  void refreshAccount() {
    final owner = repository?.accountId;
    if (owner == _owner) return;
    _owner = owner;
    ++_revision;
    data = {};
    loading = false;
    error = null;
    _demo = false;
    _timer?.cancel();
    scheduleMicrotask(() {
      if (!_disposed) notifyListeners();
    });
    if (owner != null) {
      unawaited(refresh());
      _timer = Timer.periodic(const Duration(seconds: 30), (_) => refresh());
    }
  }

  Future<void> refresh() async {
    final owner = repository?.accountId;
    if (owner == null || _disposed) return;
    final revision = ++_revision;
    loading = true;
    scheduleMicrotask(() {
      if (!_disposed && revision == _revision) notifyListeners();
    });
    try {
      final next = await repository!.snapshot();
      if (_disposed ||
          revision != _revision ||
          owner != repository!.accountId) {
        return;
      }
      data = next;
      error = null;
    } catch (_) {
      if (_disposed ||
          revision != _revision ||
          owner != repository!.accountId) {
        return;
      }
      error = '首页数据读取失败，请稍后重试';
    }
    loading = false;
    notifyListeners();
  }

  bool sessionActive = false;
  bool sessionCapsuleHidden = false;
  bool phoneRecording = false;

  void startMeeting() {
    phoneRecording = true;
    sessionActive = true;
    notifyListeners();
  }

  void hideSessionCapsule() {
    sessionCapsuleHidden = true;
    notifyListeners();
  }

  void showSessionCapsule() {
    sessionCapsuleHidden = false;
    notifyListeners();
  }

  void startDemo() {
    phoneRecording = false;
    sessionActive = true;
    _demo = true;
    notifyListeners();
  }

  void endDemo() {
    _demo = false;
    phoneRecording = false;
    sessionActive = false;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}
