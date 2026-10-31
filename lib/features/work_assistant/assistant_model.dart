import '../../core/network/api_config.dart';
import 'dart:async';
import 'package:flutter/widgets.dart';
import '../../core/network/api_client.dart';

class AssistantModel extends ChangeNotifier with WidgetsBindingObserver {
  AssistantModel(this.client, this.owner, {this.onBound}) {
    try {
      _binding = WidgetsBinding.instance;
      _binding?.addObserver(this);
    } catch (_) {}
    _poll = Timer.periodic(const Duration(seconds: 3), (_) {
      if (!current ||
          loading ||
          saving ||
          _polling ||
          (_binding?.lifecycleState != null &&
              _binding?.lifecycleState != AppLifecycleState.resumed)) {
        return;
      }
      _ticks++;
      if (['pending', 'scanned'].contains(channel['bindingStatus']) ||
          _ticks % 3 == 0) {
        unawaited(load(silent: true));
      }
    });
  }
  final ApiClient client;
  final String owner;
  final Future<void> Function()? onBound;
  bool loading = true, saving = false, _disposed = false;
  WidgetsBinding? _binding;
  Timer? _poll;
  bool _polling = false;
  int _ticks = 0;
  String? error;
  Map<String, dynamic> channel = {};
  bool get current => !_disposed && client.accountId?.call() == owner;
  void emit() {
    if (current) notifyListeners();
  }

  Future<void> load({bool silent = false}) async {
    if (!current || _polling || saving) return;
    _polling = true;
    loading = !silent;
    error = null;
    emit();
    try {
      final response = await client.get(
        'assistant/wechat',
        authenticated: true,
        accountId: owner,
      );
      if (!current) return;
      final wasBound = channel['bindingStatus'] == 'bound';
      channel = Map<String, dynamic>.from(response['data'] as Map);
      if (!wasBound && channel['bindingStatus'] == 'bound' && onBound != null) {
        unawaited(onBound!());
      }
    } on ApiFailure catch (e) {
      if (current) error = e.message;
    } catch (_) {
      if (current) error = '助手信息暂时无法读取，请重试';
    } finally {
      loading = false;
      _polling = false;
      emit();
    }
  }

  Future<bool> setAutoAnalyze(bool enabled) async {
    if (!current || saving) return false;
    saving = true;
    error = null;
    emit();
    try {
      final value = await client.post(
        'assistant/preferences',
        authenticated: true,
        accountId: owner,
        data: {'autoAnalyze': enabled},
      );
      if (!current) return false;
      channel = {...channel, 'analysisPreferences': value['data']};
      return true;
    } on ApiFailure catch (e) {
      if (current) error = e.message;
      return false;
    } finally {
      saving = false;
      emit();
    }
  }

  Future<void> createQr() async => _change('assistant/wechat/qr', {});
  Future<void> unbind() async {
    if (channel['version'] is! int) {
      error = '请先刷新微信连接状态';
      emit();
      return;
    }
    await _change('assistant/wechat/unbind', {'version': channel['version']});
  }

  Future<void> preference(String key, bool value) async {
    // The reference UI has one automatic-results control. Keep the existing
    // server opt-in behind it instead of exposing a second analysis switch.
    if (key == 'autoMeeting' &&
        value &&
        (channel['analysisPreferences'] as Map?)?['autoAnalyze'] != true) {
      if (!await setAutoAnalyze(true)) return;
    }
    if (channel['version'] is! int) {
      error = '请先刷新微信连接状态';
      emit();
      return;
    }
    final old = {
      'autoMeeting': true,
      'importantOnly': true,
      'aiDone': true,
      'paused': false,
      'sendPdf': true,
      'preMeeting': true,
      ...?channel['preferences'] as Map?,
    };
    await _change('assistant/wechat/preferences', {
      'version': channel['version'],
      for (final name in [
        'autoMeeting',
        'importantOnly',
        'aiDone',
        'paused',
        'sendPdf',
        'preMeeting',
      ])
        name: name == key ? value : old[name] == true,
    });
  }

  Future<void> _change(String path, Map<String, dynamic> data) async {
    if (!current || saving) return;
    saving = true;
    error = null;
    emit();
    try {
      final result = await client.post(
        path,
        authenticated: true,
        accountId: owner,
        data: data,
      );
      if (current) {
        final analysis = channel['analysisPreferences'];
        channel = Map<String, dynamic>.from(result['data'] as Map);
        if (analysis != null) channel['analysisPreferences'] = analysis;
      }
    } on ApiFailure catch (e) {
      if (current) error = e.message;
    } catch (_) {
      if (current) error = '微信连接暂时无法更新，请重试';
    } finally {
      saving = false;
      emit();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && current) {
      unawaited(load(silent: true));
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _poll?.cancel();
    _binding?.removeObserver(this);
    super.dispose();
  }
}
