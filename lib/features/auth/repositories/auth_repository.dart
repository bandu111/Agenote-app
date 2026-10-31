class AuthIdentity {
  const AuthIdentity({required this.email, this.name = '', this.id = ''});
  final String id, email, name;
}

class AuthUnavailable implements Exception {
  const AuthUnavailable();
}

/// 密码仅传给账户接口，不写入个人资料或会话存储。
abstract interface class AuthRepository {
  Future<AuthIdentity> login(String email, String password);
  Future<AuthIdentity> register(String name, String email, String password);
}

/// 支持真实会话恢复和撤销的账户仓储。
abstract interface class SessionAuthRepository implements AuthRepository {
  bool get authenticated;
  Future<AuthIdentity?> restore();
  Future<void> logout();
  set onSessionExpired(void Function()? callback);
}

/// 保留给离线原型及注入测试；正式入口使用 Dio 仓储。
class UnconfiguredAuthRepository implements AuthRepository {
  @override
  Future<AuthIdentity> login(String email, String password) async =>
      throw const AuthUnavailable();

  @override
  Future<AuthIdentity> register(
    String name,
    String email,
    String password,
  ) async => throw const AuthUnavailable();
}

abstract interface class AccountSecurityRepository {
  Future<void> changePassword(String currentPassword, String newPassword);
  Future<void> deleteAccount(String currentPassword);
}

class RecoveryAccount {
  const RecoveryAccount({required this.found, this.resetToken});
  final bool found;
  final String? resetToken;
}

/// Explicit demo recovery capability, separate from ordinary authentication.
abstract interface class PasswordRecoveryRepository {
  Future<RecoveryAccount> lookupRegisteredEmail(String email);
  Future<void> resetDemoPassword(
    String email,
    String resetToken,
    String newPassword,
  );
}
