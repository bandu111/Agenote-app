import '../models/personalization_data.dart';
import 'dart:convert';
import 'dart:async';
import '../../../core/network/api_config.dart';
import 'package:flutter/material.dart';
import '../models/profile_data.dart';
import '../repositories/profile_repository.dart';

class ProfileViewModel extends ChangeNotifier {
  ProfileViewModel({ProfileRepository? repository})
    : repository =
          repository ??
          ProfileRepository(LocalProfileStore(), initialSessionActive: false);
  final ProfileRepository repository;
  ProfileData data = const ProfileData();
  bool loading = true, saving = false, ready = false;
  String? error;
  bool _disposed = false;
  bool resolvingAccount = false;
  int _revision = 0;
  Completer<void>? _savingCompleted;
  bool get automaticExecutionEnabled => false;
  String get deviceStatus => '尚未检测';
  Locale? get locale =>
      data.language == 'system' ? null : Locale(data.language);
  ThemeMode get themeMode => ThemeMode.values.byName(data.appearance);
  Future<void> load() async {
    if (saving || _disposed) return;
    final revision = ++_revision;
    loading = true;
    error = null;
    _emit();
    try {
      var value = await repository.load();
      if (value.sessionActive && repository.remoteActive) {
        try {
          value = await repository.fetchCloud(value);
        } on ApiFailure catch (failure) {
          if (!_disposed) error = failure.message;
        }
      }
      if (!_disposed && revision == _revision) {
        data = value;
        ready = true;
      }
    } catch (_) {
      if (!_disposed && revision == _revision) error = '资料读取失败，原有设置未被覆盖';
    }
    if (!_disposed && revision == _revision) {
      loading = false;
      _emit();
    }
  }

  Future<bool> _save(
    ProfileData next, {
    bool personal = false,
    Map<String, dynamic>? personalization,
  }) async {
    if (loading || saving || _disposed || !ready) return false;
    saving = true;
    final completed = Completer<void>();
    _savingCompleted = completed;
    error = null;
    ++_revision;
    _emit();
    try {
      if (personalization != null) {
        await repository.savePersonalization(next, personalization);
      } else if (personal) {
        await repository.savePersonal(next);
      } else {
        await repository.save(next);
      }
      final saved = await repository.load();
      if (_disposed) return false;
      data = saved;
      return true;
    } on ApiFailure catch (failure) {
      if (personalization != null && failure.status == 409 && !_disposed) {
        data = await repository.load();
      }
      if (!_disposed) error = failure.message;
      return false;
    } catch (_) {
      if (!_disposed) error = '保存未完成，请重试';
      return false;
    } finally {
      completed.complete();
      if (identical(_savingCompleted, completed)) _savingCompleted = null;
      if (!_disposed) {
        saving = false;
        _emit();
      }
    }
  }

  Future<bool> updatePersonal({
    required String name,
    required String job,
    required String company,
    required String email,
    required String phone,
    String? avatar,
  }) async {
    if (name.trim().isEmpty ||
        name.trim().length > 40 ||
        job.length > 80 ||
        company.length > 80 ||
        email.length > 254 ||
        phone.length > 32 ||
        (email.trim().isNotEmpty &&
            !RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(email.trim()))) {
      error = '请检查个人资料';
      _emit();
      return false;
    }
    if (avatar != null) {
      try {
        final bytes = base64Decode(avatar);
        if (bytes.length > 2 * 1024 * 1024 ||
            bytes.length < 8 ||
            bytes[0] != 137 ||
            bytes[1] != 80 ||
            bytes[2] != 78 ||
            bytes[3] != 71) {
          throw const FormatException();
        }
      } catch (_) {
        error = '头像格式无效，请重新选择';
        _emit();
        return false;
      }
    }
    return _save(
      data.copyWith(
        name: name.trim(),
        job: job.trim(),
        company: company.trim(),
        email: email.trim(),
        phone: phone.trim(),
        avatar: avatar,
        clearAvatar: avatar == null,
      ),
      personal: true,
    );
  }

  Future<bool> savePersonalization(Map<String, dynamic> payload) =>
      _save(data, personalization: payload);

  Future<bool> setLanguage(String value) =>
      ['zh', 'en', 'system'].contains(value)
      ? _save(data.copyWith(language: value))
      : Future.value(false);
  Future<bool> setAppearance(String value) =>
      ['light', 'dark', 'system'].contains(value)
      ? _save(data.copyWith(appearance: value))
      : Future.value(false);
  Future<bool> signOut() async {
    // 认证失效可能发生在资料保存中，必须等该次写入收尾后再锁定页面。
    await _savingCompleted?.future;
    if (_disposed) return false;
    final saved = await _save(data.copyWith(sessionActive: false));
    repository.sessionActiveOverride = false;
    data = data.copyWith(sessionActive: false);
    _emit();
    return saved;
  }

  Future<bool> setHapticFeedback(bool value) =>
      _save(data.copyWith(hapticFeedback: value));
  Future<bool> setBackgroundNotifications(bool value) =>
      _save(data.copyWith(backgroundNotifications: value));
  Future<bool> resumeLocalAccount() =>
      _save(data.copyWith(sessionActive: true));

  Future<bool> acceptAccount({
    required String name,
    required String email,
    String id = '',
    bool newlyRegistered = false,
  }) async {
    resolvingAccount = true;
    try {
      final saved = await _save(
        data.copyWith(
          personalization: newlyRegistered ? const PersonalizationData() : null,
          clearPersonalization: id != data.accountId && !newlyRegistered,
          accountId: id.isEmpty ? null : id,
          name:
              id == data.accountId &&
                  data.cloudVersion == 0 &&
                  data.name.isNotEmpty
              ? data.name
              : name,
          email: id == data.accountId && data.email.isNotEmpty
              ? data.email
              : email,
          cloudVersion: id != data.accountId ? 0 : null,
          job: id != data.accountId ? '' : null,
          company: id != data.accountId ? '' : null,
          phone: id != data.accountId ? '' : null,
          clearAvatar: id != data.accountId,
          sessionActive: true,
        ),
      );
      if (saved && repository.remoteActive) await load();
      return saved;
    } finally {
      resolvingAccount = false;
      _emit();
    }
  }

  Future<void> forgetPersonal() async {
    ++_revision;
    await repository.clearPersonal();
    data = await repository.load();
    _emit();
  }

  void _emit() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    ++_revision;
    super.dispose();
  }
}
