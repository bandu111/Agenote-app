import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:yanshu/core/network/api_config.dart';
import 'package:yanshu/features/auth/services/session_store.dart';
import 'package:yanshu/features/profile/repositories/profile_repository.dart';
import 'package:yanshu/features/meeting/meeting_store.dart';
import 'package:yanshu/features/meeting/meeting_models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('普通启动默认云端，显式本地仍保留旧缓存目录', () {
    final cloud = ApiEnvironment.resolve();
    expect(cloud.environment, AppEnvironment.cloud);
    expect(cloud.baseUrl, ApiEnvironment.cloudUrl);
    expect(cloud.dataSubdirectory, isNotEmpty);
    expect(ApiConfig.speechProvider, 'tencent');
    expect(
      ApiEnvironment.resolve(debug: false).baseUrl,
      ApiEnvironment.cloudUrl,
    );
    final local = ApiEnvironment.resolve(flavor: 'local');
    expect(local.baseUrl, ApiEnvironment.localUrl);
    expect(local.dataSubdirectory, isEmpty);
    expect(
      ApiEnvironment.resolve(flavor: 'cloud').baseUrl,
      ApiEnvironment.cloudUrl,
    );
  });
  test('包标识、环境及云端 HTTPS 必须一致', () {
    for (final make in <ApiEnvironment Function()>[
      () => ApiEnvironment.resolve(flavor: 'local', name: 'cloud'),
      () => ApiEnvironment.resolve(name: 'unknown'),
      () => ApiEnvironment.resolve(
        name: 'cloud',
        overrideUrl: ApiEnvironment.localUrl,
      ),
      () => ApiEnvironment.resolve(
        name: 'cloud',
        overrideUrl: 'https://localhost/api/v1/',
      ),
      () => ApiEnvironment.resolve(
        name: 'local',
        overrideUrl: ApiEnvironment.cloudUrl,
      ),
    ]) {
      expect(make, throwsA(isA<ApiFailure>()));
    }
    expect(
      ApiEnvironment.resolve(name: 'cloud', debug: false).baseUrl,
      ApiEnvironment.cloudUrl,
    );
  });
  test('云端与本地令牌互不覆盖，退出云端不清除本地令牌', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final local = SecureSessionStore(ApiEnvironment.localUrl);
    final cloud = SecureSessionStore(ApiEnvironment.cloudUrl);
    final oldCloud = SecureSessionStore('https://150.109.236.254/api/v1/');
    await local.write('local-token');
    await oldCloud.write('old-cloud-token');
    await cloud.write('cloud-token');
    expect(await local.read(), 'local-token');
    expect(await cloud.read(), 'cloud-token');
    expect(await oldCloud.read(), 'old-cloud-token');
    await cloud.clear();
    expect(await local.read(), 'local-token');
    expect(await cloud.read(), isNull);
    expect(await oldCloud.read(), 'old-cloud-token');
  });
  test('同一应用容器内的资料与会议按环境隔离，原本地文件保留', () async {
    final root = await Directory.systemTemp.createTemp('yanshu-env-test-');
    try {
      final cloudDir = Directory(
        '${root.path}/${ApiEnvironment.resolve(name: 'cloud').dataSubdirectory}',
      );
      final localProfiles = LocalProfileStore(directory: root);
      final cloudProfiles = LocalProfileStore(directory: cloudDir);
      await localProfiles.write('local-profile');
      await cloudProfiles.write('cloud-profile');
      expect(await localProfiles.read(), 'local-profile');
      expect(await cloudProfiles.read(), 'cloud-profile');
      final local = LocalMeetingStore(directory: root);
      final cloud = LocalMeetingStore(directory: cloudDir);
      await local.save(
        MeetingRecord(
          id: 'same-id',
          demo: false,
          title: '本地会议',
          startedAt: DateTime.utc(2026),
        ),
      );
      await cloud.save(
        MeetingRecord(
          id: 'same-id',
          demo: false,
          title: '云端会议',
          startedAt: DateTime.utc(2026),
        ),
      );
      expect((await local.read()).single.title, '本地会议');
      expect((await cloud.read()).single.title, '云端会议');
    } finally {
      await root.delete(recursive: true);
    }
  });
}
