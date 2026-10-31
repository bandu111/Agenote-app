import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../profile/viewmodels/profile_view_model.dart';

abstract interface class PersonalizationDraftStore {
  Future<String?> read(String owner);
  Future<void> write(String owner, String? value);
}

class SecurePersonalizationDrafts implements PersonalizationDraftStore {
  const SecurePersonalizationDrafts();
  static const _storage = FlutterSecureStorage();
  String _key(String owner) => 'agenote.personalization.v1.$owner';
  @override
  Future<String?> read(String owner) => _storage.read(key: _key(owner));
  @override
  Future<void> write(String owner, String? value) => value == null
      ? _storage.delete(key: _key(owner))
      : _storage.write(key: _key(owner), value: value);
}

class PersonalizationController extends ChangeNotifier {
  PersonalizationController(
    this.profile, {
    this.store = const SecurePersonalizationDrafts(),
  }) : owner = profile.data.accountId {
    final saved = profile.data.personalization;
    name = profile.data.name;
    step = saved?.step ?? 1;
    profession = saved?.profession ?? '';
    professionOther = saved?.professionOther ?? '';
    scenarios = {...?saved?.scenarios};
    scenarioOther = saved?.scenarioOther ?? '';
  }
  final ProfileViewModel profile;
  final PersonalizationDraftStore store;
  final String owner;
  late String name, profession, professionOther, scenarioOther;
  late int step;
  late Set<String> scenarios;
  bool busy = false, loading = true, dirty = false, _disposed = false;
  String? error;
  Timer? _timer;
  Future<bool>? _inFlight;
  Future<void> _localWrites = Future.value();
  bool get _current =>
      !_disposed &&
      profile.data.accountId == owner &&
      profile.data.sessionActive;
  Future<void> initialize() async {
    try {
      final raw = await store.read(owner);
      if (!_current) return;
      if (raw != null) {
        final j = jsonDecode(raw) as Map;
        if (j['version'] == profile.data.cloudVersion &&
            profile.data.personalization?.required == true) {
          name = j['name'] as String? ?? name;
          profession = j['profession'] as String? ?? profession;
          professionOther = j['profession_other'] as String? ?? professionOther;
          scenarios = Set<String>.from(
            j['scenarios'] as List? ?? scenarios.toList(),
          );
          scenarioOther = j['scenario_other'] as String? ?? scenarioOther;
          step = j['step'] == 2 ? 2 : 1;
          dirty = true;
        }
      }
    } catch (_) {
      error = '本机草稿读取失败，已使用云端资料';
    }
    if (!_current) return;
    loading = false;
    notifyListeners();
    if (dirty) changed();
  }

  Map<String, dynamic> payload(String action) => {
    'step': step,
    'action': action,
    'name': name.trim(),
    'profession': profession,
    'profession_other': professionOther.trim(),
    'scenarios': scenarios.toList(),
    'scenario_other': scenarioOther.trim(),
  };
  void _cache({bool clear = false}) {
    final value = clear
        ? null
        : jsonEncode({
            ...payload('draft'),
            'version': profile.data.cloudVersion,
          });
    _localWrites = _localWrites
        .catchError((_) {})
        .then((_) => store.write(owner, value));
    unawaited(_localWrites.catchError((_) {}));
  }

  void changed() {
    if (!_current || busy) return;
    dirty = true;
    error = null;
    _cache();
    _timer?.cancel();
    _timer = Timer(const Duration(milliseconds: 800), () => _draft());
    notifyListeners();
  }

  bool _valid() {
    if (name.trim().runes.length > 40) {
      error = '昵称最多 40 个字';
      return false;
    }
    if (profession == 'other' && professionOther.trim().isEmpty) {
      error = '请填写你的专业领域';
      return false;
    }
    if (professionOther.trim().runes.length > 80) {
      error = '专业领域最多 80 个字';
      return false;
    }
    if (scenarios.contains('other') && scenarioOther.trim().isEmpty) {
      error = '请填写其他使用场景';
      return false;
    }
    if (scenarioOther.trim().runes.length > 120) {
      error = '使用场景最多 120 个字';
      return false;
    }
    return true;
  }

  Future<bool> _persist(Map<String, dynamic> data) async {
    final ok = await profile.savePersonalization(data);
    if (profile.data.accountId != owner) return false;
    if (!_disposed && !ok) {
      error = profile.error ?? '保存未完成，请重试';
    }
    return ok;
  }

  Future<void> _draft() async {
    if (!_current || busy || !dirty) return;
    if (_inFlight != null || profile.saving) {
      _timer = Timer(const Duration(milliseconds: 500), () => _draft());
      return;
    }
    final data = payload('draft');
    final request = _persist(data);
    _inFlight = request;
    final ok = await request;
    _inFlight = null;
    if (!_current) return;
    if (ok) {
      dirty = jsonEncode(data) != jsonEncode(payload('draft'));
      _cache();
      if (dirty) {
        _timer = Timer(const Duration(milliseconds: 800), () => _draft());
      }
    }
    notifyListeners();
  }

  Future<bool> submit(String action) async {
    if (!_current || busy || loading) return false;
    if (action != 'skip' && !_valid()) {
      notifyListeners();
      return false;
    }
    busy = true;
    error = null;
    _timer?.cancel();
    notifyListeners();
    await _inFlight;
    if (!_current) return false;
    final value = payload(action);
    if (action == 'skip') {
      if (profession == 'other' && professionOther.trim().isEmpty) {
        value['profession'] = '';
      }
      if (scenarios.contains('other') && scenarioOther.trim().isEmpty) {
        value['scenarios'] = scenarios.where((s) => s != 'other').toList();
      }
    }
    final ok = await _persist(value);
    if (profile.data.accountId != owner) return false;
    if (ok) {
      dirty = false;
      if (action == 'continue') step = 2;
      _cache(clear: action == 'complete' || action == 'skip');
      await _localWrites.catchError((_) {});
    }
    if (!_current) return false;
    busy = false;
    notifyListeners();
    return ok;
  }

  void back() {
    if (busy || step != 2) return;
    step = 1;
    changed();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}
