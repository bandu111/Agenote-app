import 'dart:async';
import 'dart:convert';
import '../../../core/network/api_client.dart';
import '../../../core/network/api_config.dart';
import '../services/session_store.dart';
import 'auth_repository.dart';

class DioAuthRepository
    implements
        SessionAuthRepository,
        AccountSecurityRepository,
        PasswordRecoveryRepository {
  DioAuthRepository(this.client, this.store) {
    client.accessToken = () async => _session?.accessToken;
    client.accountId = () => _session?.identity.id;
    client.refreshSession = _refreshAfterUnauthorized;
  }
  final ApiClient client;
  final SessionStore store;
  _Session? _session;
  Future<bool>? _refreshing;
  @override
  bool get authenticated => _session != null;
  String? get accountId => _session?.identity.id;
  @override
  void Function()? onSessionExpired;

  AuthIdentity _identity(Object? value) {
    if (value is! Map ||
        value['id'] is! String ||
        (value['id'] as String).isEmpty ||
        value['email'] is! String ||
        value['name'] is! String) {
      throw const ApiFailure('账户服务返回的数据无法读取');
    }
    return AuthIdentity(
      id: value['id'],
      email: value['email'],
      name: value['name'],
    );
  }

  Future<AuthIdentity> _save(Map<String, dynamic> envelope) async {
    final data = envelope['data'];
    if (data is! Map ||
        data['access_token'] is! String ||
        data['refresh_token'] is! String ||
        data['token_type'] != 'bearer' ||
        (data['access_token'] as String).isEmpty ||
        (data['refresh_token'] as String).isEmpty) {
      throw const ApiFailure('账户服务返回的数据无法读取');
    }
    final identity = _identity(data['user']);
    final next = _Session(
      identity,
      data['access_token'],
      data['refresh_token'],
    );
    try {
      await store.write(next.encode());
      _session = next;
    } catch (_) {
      // 刷新令牌已轮换时不能继续使用旧记录，保存失败必须结束本机会话。
      await _clear();
      throw const ApiFailure('账户状态保存失败，请重试');
    }
    return identity;
  }

  @override
  Future<AuthIdentity> login(String email, String password) async => _save(
    await client.post(
      'auth/login',
      data: {'email': email.trim(), 'password': password},
    ),
  );

  @override
  Future<AuthIdentity> register(
    String name,
    String email,
    String password,
  ) async => _save(
    await client.post(
      'auth/register',
      data: {'name': name.trim(), 'email': email.trim(), 'password': password},
    ),
  );

  @override
  Future<AuthIdentity?> restore() async {
    final raw = await store.read();
    if (raw == null) return null;
    try {
      final data = jsonDecode(raw) as Map<String, dynamic>;
      _session = _Session(
        _identity(data['user']),
        data['access_token'] as String,
        data['refresh_token'] as String,
      );
      if (_session!.accessToken.isEmpty || _session!.refreshToken.isEmpty) {
        throw const FormatException();
      }
    } catch (_) {
      await _clear();
      return null;
    }
    try {
      final response = await client.get('auth/me', authenticated: true);
      final identity = _identity(response['data']);
      _session = _Session(
        identity,
        _session!.accessToken,
        _session!.refreshToken,
      );
      await store.write(_session!.encode());
      return identity;
    } on ApiFailure catch (error) {
      if (error.status == 401) {
        await _clear();
        return null;
      }
      // 断网不代表令牌被撤销，保留安全存储以便下次连接恢复。
      _session = null;
      rethrow;
    }
  }

  Future<bool> _refreshAfterUnauthorized(String? previousAuthorization) async {
    if (_session == null) return false;
    if (previousAuthorization != 'Bearer ${_session!.accessToken}') return true;
    // 所有并发 401 共用一次刷新，避免后端将重复刷新判定为重放。
    final pending = _refreshing;
    if (pending != null) return pending;
    final future = _refresh();
    _refreshing = future;
    try {
      return await future;
    } finally {
      _refreshing = null;
    }
  }

  Future<bool> _refresh() async {
    final current = _session;
    if (current == null) return false;
    try {
      await _save(
        await client.post(
          'auth/refresh',
          data: {'refresh_token': current.refreshToken},
        ),
      );
      return true;
    } on ApiFailure catch (error) {
      if (error.status == 401) {
        await _clear();
        onSessionExpired?.call();
        return false;
      }
      rethrow;
    }
  }

  @override
  Future<void> logout() async {
    if (_refreshing != null) await _refreshing;
    if (_session != null) {
      try {
        await client.post('auth/logout', authenticated: true);
      } on ApiFailure catch (error) {
        if (error.status != 401) rethrow;
      }
    }
    await _clear();
  }

  Future<void> _security(String path, Map<String, dynamic> data) async {
    if (_refreshing != null) await _refreshing;
    final owner = accountId;
    if (owner == null) throw const ApiFailure('登录已失效，请重新登录');
    await client.post(path, data: data, authenticated: true, accountId: owner);
    // 请求期间其他接口可能触发刷新；等其收尾再清除，防止迟到响应恢复旧令牌。
    final refreshing = _refreshing;
    if (refreshing != null) {
      try {
        await refreshing;
      } catch (_) {
        /* 服务端已完成敏感操作，仍须清理本机。 */
      }
    }
    await _clear();
  }

  @override
  Future<void> changePassword(String currentPassword, String newPassword) =>
      _security('auth/password', {
        'current_password': currentPassword,
        'new_password': newPassword,
      });

  @override
  Future<void> deleteAccount(String currentPassword) => _security(
    'auth/delete-account',
    {'current_password': currentPassword, 'confirmation': 'DELETE'},
  );

  @override
  Future<RecoveryAccount> lookupRegisteredEmail(String email) async {
    final envelope = await client.post(
      'auth/recovery/lookup',
      data: {'email': email.trim().toLowerCase()},
    );
    final value = envelope['data'];
    if (value is! Map ||
        value['found'] is! bool ||
        (value['found'] == true &&
            (value['reset_token'] is! String ||
                (value['reset_token'] as String).isEmpty))) {
      throw const ApiFailure('账户服务返回的数据无法读取');
    }
    return RecoveryAccount(
      found: value['found'],
      resetToken: value['reset_token'] as String?,
    );
  }

  @override
  Future<void> resetDemoPassword(
    String email,
    String resetToken,
    String newPassword,
  ) => client
      .post(
        'auth/recovery/reset',
        data: {
          'email': email.trim().toLowerCase(),
          'reset_token': resetToken,
          'new_password': newPassword,
        },
      )
      .then((_) {});

  Future<void> _clear() async {
    _session = null;
    await store.clear();
  }
}

class _Session {
  const _Session(this.identity, this.accessToken, this.refreshToken);
  final AuthIdentity identity;
  final String accessToken, refreshToken;
  String encode() => jsonEncode({
    'user': {'id': identity.id, 'name': identity.name, 'email': identity.email},
    'access_token': accessToken,
    'refresh_token': refreshToken,
  });
}
