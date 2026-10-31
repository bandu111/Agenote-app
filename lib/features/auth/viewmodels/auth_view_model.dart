import 'package:flutter/foundation.dart';
import 'dart:async';
import '../../../core/network/api_config.dart';
import '../../profile/viewmodels/profile_view_model.dart';
import '../repositories/auth_repository.dart';

class AuthViewModel extends ChangeNotifier {
  AuthViewModel(
    this.repository,
    this.profile, {
    this.error,
    this.onSessionEnded,
  }) {
    final sessionRepository = repository;
    if (sessionRepository is SessionAuthRepository) {
      sessionRepository.onSessionExpired = () {
        if (!_disposed) unawaited(_expireSession());
      };
    }
  }
  final AuthRepository repository;
  final ProfileViewModel profile;
  final Future<void> Function()? onSessionEnded;

  Future<void> _expireSession() async {
    try {
      await onSessionEnded?.call();
    } finally {
      if (!_disposed) await profile.signOut();
    }
  }

  bool get isRemoteAccount =>
      repository is SessionAuthRepository &&
      (repository as SessionAuthRepository).authenticated;
  bool submitting = false, _disposed = false;
  String? error;

  void clearError() {
    if (error == null || _disposed) return;
    error = null;
    notifyListeners();
  }

  Future<bool> submit({
    required bool register,
    required String email,
    required String password,
    String name = '',
  }) async {
    if (submitting || _disposed) return false;
    submitting = true;
    error = null;
    notifyListeners();
    try {
      final identity = register
          ? await repository.register(name.trim(), email.trim(), password)
          : await repository.login(email.trim(), password);
      if (_disposed) return false;
      final saved = await profile.acceptAccount(
        id: identity.id,
        newlyRegistered: register,
        name: identity.name,
        email: identity.email,
      );
      if (!saved) error = '账户状态保存失败，请重试';
      return saved;
    } on AuthUnavailable {
      if (!_disposed) error = '账户服务暂不可用，请稍后重试';
      return false;
    } on ApiFailure catch (failure) {
      if (!_disposed) error = failure.message;
      return false;
    } catch (_) {
      if (!_disposed) error = '暂时无法连接账户服务，请稍后重试';
      return false;
    } finally {
      submitting = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<bool> signOut() async {
    if (submitting || _disposed) return false;
    submitting = true;
    error = null;
    notifyListeners();
    try {
      final sessionRepository = repository;
      if (sessionRepository is SessionAuthRepository) {
        await sessionRepository.logout();
      }
      return await profile.signOut();
    } on ApiFailure catch (failure) {
      error = failure.message;
      return false;
    } catch (_) {
      error = '退出未完成，请重试';
      return false;
    } finally {
      submitting = false;
      if (!_disposed) notifyListeners();
    }
  }

  bool get supportsAccountSecurity =>
      isRemoteAccount && repository is AccountSecurityRepository;

  Future<bool> secureAccount({
    required String currentPassword,
    String? newPassword,
    bool delete = false,
  }) async {
    if (submitting || _disposed || !supportsAccountSecurity) return false;
    submitting = true;
    error = null;
    notifyListeners();
    try {
      final security = repository as AccountSecurityRepository;
      // 先停止会议，避免在注销后继续上传录音或业务事件。
      await onSessionEnded?.call();
      if (delete) {
        await security.deleteAccount(currentPassword);
      } else {
        await security.changePassword(currentPassword, newPassword!);
      }
      if (delete) {
        await profile.forgetPersonal();
      } else {
        await profile.signOut();
      }
      return true;
    } on ApiFailure catch (failure) {
      error = failure.message;
      return false;
    } catch (_) {
      error = '操作未完成，请重试';
      return false;
    } finally {
      submitting = false;
      if (!_disposed) notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    final sessionRepository = repository;
    if (sessionRepository is SessionAuthRepository) {
      sessionRepository.onSessionExpired = null;
    }
    super.dispose();
  }
}
