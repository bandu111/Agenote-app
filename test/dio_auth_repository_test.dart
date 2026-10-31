import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yanshu/core/network/api_client.dart';
import 'package:yanshu/core/network/api_config.dart';
import 'package:yanshu/features/auth/repositories/dio_auth_repository.dart';
import 'package:yanshu/features/auth/services/auth_bootstrap.dart';
import 'package:yanshu/features/auth/services/session_store.dart';
import 'package:yanshu/features/profile/repositories/profile_repository.dart';

class MemorySessionStore implements SessionStore {
  String? value;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String value) async => this.value = value;
  @override
  Future<void> clear() async => value = null;
}

class TestAdapter implements HttpClientAdapter {
  TestAdapter(this.handle);
  final Future<(int, Object?)> Function(RequestOptions) handle;
  @override
  void close({bool force = false}) {}
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final (status, body) = await handle(options);
    return ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }
}

Map<String, dynamic> envelope(
  Object? data, {
  int status = 200,
  String message = 'success',
}) => {'code': status, 'message': message, 'data': data};
const user = {'id': 'test-user-id', 'name': '言言', 'email': 'yan@example.com'};
Map<String, dynamic> tokens(String access, String refresh) => {
  'user': user,
  'access_token': access,
  'refresh_token': refresh,
  'token_type': 'bearer',
  'expires_in': 900,
};
DioAuthRepository repository(MemorySessionStore store, TestAdapter adapter) {
  final dio = Dio()..httpClientAdapter = adapter;
  return DioAuthRepository(
    ApiClient(baseUrl: 'https://test.example/api/v1/', dio: dio),
    store,
  );
}

void main() {
  test('注册使用真实契约，密码不进入令牌记录', () async {
    final store = MemorySessionStore();
    final repo = repository(
      store,
      TestAdapter((request) async {
        expect(request.path, 'auth/register');
        expect(request.data, {
          'name': '言言',
          'email': 'yan@example.com',
          'password': 'password-only',
        });
        expect(request.headers.containsKey('Authorization'), isFalse);
        return (201, envelope(tokens('a1', 'r1'), status: 201));
      }),
    );
    final identity = await repo.register(
      ' 言言 ',
      ' yan@example.com ',
      'password-only',
    );
    expect(identity.id, 'test-user-id');
    expect(store.value, isNot(contains('password-only')));
    expect(repo.authenticated, isTrue);
  });

  test('错误密码和重复邮箱保留中文业务错误', () async {
    final repo = repository(
      MemorySessionStore(),
      TestAdapter((request) async {
        final login = request.path == 'auth/login';
        return (
          login ? 401 : 409,
          envelope(
            null,
            status: login ? 401 : 409,
            message: login ? 'invalid_credentials' : 'email_already_registered',
          ),
        );
      }),
    );
    await expectLater(
      repo.login('a@example.com', 'wrong'),
      throwsA(
        isA<ApiFailure>().having((e) => e.message, 'message', '邮箱或密码不正确'),
      ),
    );
    await expectLater(
      repo.register('a', 'a@example.com', 'wrong'),
      throwsA(isA<ApiFailure>().having((e) => e.status, 'status', 409)),
    );
  });

  test('并发过期请求只刷新一次并使用新令牌重试', () async {
    final store = MemorySessionStore();
    var refreshes = 0;
    final repo = repository(
      store,
      TestAdapter((request) async {
        if (request.path == 'auth/login') {
          return (200, envelope(tokens('old', 'r1')));
        }
        if (request.path == 'auth/refresh') {
          refreshes++;
          await Future<void>.delayed(const Duration(milliseconds: 20));
          expect(request.data, {'refresh_token': 'r1'});
          return (200, envelope(tokens('new', 'r2')));
        }
        if (request.headers['Authorization'] == 'Bearer new') {
          return (200, envelope(user));
        }
        return (
          401,
          envelope(null, status: 401, message: 'invalid_or_expired_token'),
        );
      }),
    );
    await repo.login('yan@example.com', 'password');
    final results = await Future.wait(
      List.generate(3, (_) => repo.client.get('auth/me', authenticated: true)),
    );
    expect(results.length, 3);
    expect(refreshes, 1);
    expect(store.value, contains('r2'));
    expect(store.value, isNot(contains('r1')));
  });

  test('重新创建仓储从存储恢复且向后端验证用户', () async {
    final store = MemorySessionStore();
    final adapter = TestAdapter(
      (request) async => request.path == 'auth/login'
          ? (200, envelope(tokens('a1', 'r1')))
          : (200, envelope(user)),
    );
    await repository(store, adapter).login('yan@example.com', 'password');
    final restored = await repository(store, adapter).restore();
    expect(restored?.id, 'test-user-id');
  });

  test('撤销会话清理安全记录，刷新请求不会循环重试', () async {
    final store = MemorySessionStore();
    var refreshes = 0;
    var expired = 0;
    final adapter = TestAdapter((request) async {
      if (request.path == 'auth/login') {
        return (200, envelope(tokens('a1', 'r1')));
      }
      if (request.path == 'auth/refresh') refreshes++;
      return (
        401,
        envelope(null, status: 401, message: 'invalid_refresh_token'),
      );
    });
    final repo = repository(store, adapter);
    repo.onSessionExpired = () => expired++;
    await repo.login('yan@example.com', 'password');
    await expectLater(
      repo.client.get('auth/me', authenticated: true),
      throwsA(isA<ApiFailure>()),
    );
    expect(refreshes, 1);
    expect(expired, 1);
    expect(store.value, isNull);
  });

  test('断网保留安全存储但不恢复未经验证的登录状态', () async {
    final store = MemorySessionStore();
    await repository(
      store,
      TestAdapter((_) async => (200, envelope(tokens('a1', 'r1')))),
    ).login('a', 'b');
    final previous = store.value;
    final repo = repository(
      store,
      TestAdapter(
        (request) async => throw DioException(
          requestOptions: request,
          type: DioExceptionType.connectionError,
        ),
      ),
    );
    await expectLater(repo.restore(), throwsA(isA<ApiFailure>()));
    expect(store.value, previous);
    expect(repo.authenticated, isFalse);
  });

  test('退出调用服务端撤销后清空令牌', () async {
    final store = MemorySessionStore();
    var revoked = false;
    final repo = repository(
      store,
      TestAdapter((request) async {
        if (request.path == 'auth/login') {
          return (200, envelope(tokens('a1', 'r1')));
        }
        expect(request.path, 'auth/logout');
        expect(request.headers['Authorization'], 'Bearer a1');
        revoked = true;
        return (200, envelope(null));
      }),
    );
    await repo.login('yan@example.com', 'password');
    await repo.logout();
    expect(revoked, isTrue);
    expect(store.value, isNull);
  });

  test('普通资料内的登录标记不能绕过服务端认证', () async {
    final profileStore = MemoryProfileStore();
    final original = ProfileRepository(profileStore);
    await original.load();
    final profiles = ProfileRepository(
      profileStore,
      sessionActiveOverride: false,
    );
    final repo = repository(
      MemorySessionStore(),
      TestAdapter((_) async => throw StateError('不应请求')),
    );
    expect(await restoreAccountSession(repo, profiles), isNull);
    expect((await profiles.load()).sessionActive, isFalse);
  });
}
