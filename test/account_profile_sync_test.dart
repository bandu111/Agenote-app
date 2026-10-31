import 'dart:async';
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yanshu/core/network/api_client.dart';
import 'package:yanshu/core/network/api_config.dart';
import 'package:yanshu/features/profile/models/profile_data.dart';
import 'package:yanshu/features/profile/repositories/profile_repository.dart';
import 'package:yanshu/features/profile/viewmodels/profile_view_model.dart';
import 'dio_auth_repository_test.dart'
    show TestAdapter, MemorySessionStore, envelope, tokens;
import 'package:yanshu/features/auth/repositories/dio_auth_repository.dart';

void main() {
  test('岗位通过编辑资料接口保存并回读，不需要微信助手重复填写', () async {
    final paths = <String>[];
    var cloud = <String, dynamic>{
      'id': 'owner',
      'version': 1,
      'name': '测试用户',
      'job': '',
    };
    final api = ApiClient(baseUrl: 'https://test/api/v1/', dio: Dio())
      ..accountId = () => 'owner';
    api.dio.httpClientAdapter = TestAdapter((request) async {
      paths.add(request.path);
      if (request.method == 'POST') {
        expect((request.data as Map)['job'], 'Flutter 开发工程师');
        cloud = {
          ...cloud,
          ...request.data as Map<String, dynamic>,
          'version': 2,
        };
      }
      return (200, envelope(cloud));
    });
    final repository = ProfileRepository(MemoryProfileStore(), client: api);
    await repository.save(
      const ProfileData(accountId: 'owner', name: '测试用户', cloudVersion: 1),
    );
    final profile = ProfileViewModel(repository: repository);
    await profile.load();
    expect(
      await profile.updatePersonal(
        name: '测试用户',
        job: 'Flutter 开发工程师',
        company: '',
        email: '',
        phone: '',
      ),
      isTrue,
    );
    expect(profile.data.job, 'Flutter 开发工程师');
    await profile.load();
    expect(profile.data.job, 'Flutter 开发工程师');
    expect(paths.every((path) => path.endsWith('auth/profile')), isTrue);
    profile.dispose();
  });
  test('同账号旧本机资料迁入空白云档案，已有云档案不被覆盖', () async {
    var writes = 0;
    var cloud = <String, dynamic>{
      'id': 'owner',
      'version': 1,
      'name': '注册昵称',
      'email': 'login@example.com',
      'job': '',
      'company': '',
      'phone': '',
      'avatar': null,
    };
    final api = ApiClient(
      baseUrl: 'https://test/api/v1/',
      dio: Dio()
        ..httpClientAdapter = TestAdapter((r) async {
          if (r.method == 'POST') {
            writes++;
            cloud = {
              ...r.data as Map<String, dynamic>,
              'id': 'owner',
              'version': 2,
            };
          }
          return (200, envelope(cloud));
        }),
    )..accountId = () => 'owner';
    final repo = ProfileRepository(MemoryProfileStore(), client: api);
    final local = const ProfileData(
      accountId: 'owner',
      name: '本机昵称',
      company: '本机公司',
    );
    final migrated = await repo.fetchCloud(local);
    expect(migrated.name, '本机昵称');
    expect(migrated.company, '本机公司');
    expect(migrated.cloudVersion, 2);
    cloud = {...cloud, 'name': '另一设备更新'};
    final fresh = await repo.fetchCloud(local);
    expect(fresh.name, '另一设备更新');
    expect(writes, 1);
  });

  test('登录失效发生在保存中，收尾后仍必须锁定账户', () async {
    final requested = Completer<void>();
    final result = Completer<(int, Object?)>();
    final api = ApiClient(
      baseUrl: 'https://test/api/v1/',
      dio: Dio()
        ..httpClientAdapter = TestAdapter((r) async {
          requested.complete();
          return result.future;
        }),
    );
    final repo = ProfileRepository(MemoryProfileStore(), client: api);
    await repo.save(
      const ProfileData(accountId: 'owner', name: '旧名', cloudVersion: 1),
    );
    final vm = ProfileViewModel(repository: repo);
    await vm.load();
    api.accountId = () => 'owner';
    final saving = vm.updatePersonal(
      name: '新名',
      job: '',
      company: '',
      email: '',
      phone: '',
    );
    await requested.future;
    final locking = vm.signOut();
    api.accountId = () => null;
    result.complete((
      401,
      envelope(null, status: 401, message: 'invalid_or_expired_token'),
    ));
    expect(await saving, isFalse);
    await locking;
    expect(vm.data.sessionActive, isFalse);
    expect((await repo.load()).sessionActive, isFalse);
    vm.dispose();
  });

  test('资料云端成功后落盘，冲突不冒充成功，设备偏好保持本机', () async {
    var version = 1;
    var calls = 0;
    final api = ApiClient(
      baseUrl: 'https://test/api/v1/',
      dio: Dio()
        ..httpClientAdapter = TestAdapter((request) async {
          calls++;
          final payload = request.data as Map;
          if (payload['version'] != version) {
            return (
              409,
              envelope(null, status: 409, message: 'profile_version_conflict'),
            );
          }
          version++;
          return (
            200,
            envelope({...payload, 'id': 'owner', 'version': version}),
          );
        }),
    )..accountId = () => 'owner';
    final store = MemoryProfileStore(
      value: jsonEncode(
        const ProfileData(
          accountId: 'owner',
          cloudVersion: 1,
          name: '旧名',
          appearance: 'dark',
        ).toJson(),
      ),
    );
    final repo = ProfileRepository(store, client: api);
    final vm = ProfileViewModel(repository: repo);
    // 从缓存装载，随后启用远程认证以隔离本测试的保存链路。
    api.accountId = () => null;
    await vm.load();
    api.accountId = () => 'owner';
    expect(
      await vm.updatePersonal(
        name: '云昵称',
        job: '',
        company: '',
        email: '',
        phone: '',
      ),
      isTrue,
    );
    expect((await repo.load()).cloudVersion, 2);
    expect(await vm.setLanguage('en'), isTrue);
    expect(calls, 1);
    version = 3;
    expect(
      await vm.updatePersonal(
        name: '不能覆盖',
        job: '',
        company: '',
        email: '',
        phone: '',
      ),
      isFalse,
    );
    expect((await repo.load()).name, '云昵称');
    expect((await repo.load()).appearance, 'dark');
    vm.dispose();
  });

  test('延迟云响应不能把 A 的资料写入 B', () async {
    String owner = 'A';
    final result = Completer<(int, Object?)>();
    final requested = Completer<void>();
    final api = ApiClient(
      baseUrl: 'https://test/api/v1/',
      dio: Dio()
        ..httpClientAdapter = TestAdapter((_) async {
          requested.complete();
          return result.future;
        }),
    )..accountId = () => owner;
    final store = MemoryProfileStore();
    final repo = ProfileRepository(store, client: api);
    final request = repo.fetchCloud(const ProfileData(accountId: 'A'));
    await requested.future;
    owner = 'B';
    final b = const ProfileData(accountId: 'B', name: 'B昵称');
    await repo.save(b);
    final expectation = expectLater(request, throwsA(isA<ApiFailure>()));
    result.complete((200, envelope({'id': 'A', 'name': 'A昵称', 'version': 2})));
    await expectation;
    expect((await repo.load()).accountId, 'B');
    expect((await repo.load()).name, 'B昵称');
  });

  test('改密错误保留登录，成功清安全存储，密码从不落盘', () async {
    final store = MemorySessionStore();
    var valid = false;
    final repo = DioAuthRepository(
      ApiClient(
        baseUrl: 'https://test/api/v1/',
        dio: Dio()
          ..httpClientAdapter = TestAdapter((r) async {
            if (r.path == 'auth/login') {
              return (200, envelope(tokens('access', 'refresh')));
            }
            expect(r.path, 'auth/password');
            if (!valid) {
              return (
                403,
                envelope(
                  null,
                  status: 403,
                  message: 'current_password_incorrect',
                ),
              );
            }
            return (200, envelope(null));
          }),
      ),
      store,
    );
    await repo.login('yan@example.com', 'not-stored');
    await expectLater(
      repo.changePassword('wrong', 'new-password'),
      throwsA(isA<ApiFailure>()),
    );
    expect(repo.authenticated, isTrue);
    expect(store.value, isNot(contains('password')));
    valid = true;
    await repo.changePassword('current-password', 'new-password');
    expect(repo.authenticated, isFalse);
    expect(store.value, isNull);
  });
}
