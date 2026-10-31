import '../models/personalization_data.dart';
import 'dart:convert';
import '../../../core/network/api_client.dart';
import '../../../core/network/api_config.dart';
import 'dart:io';
import 'dart:math';
import 'package:path_provider/path_provider.dart';
import '../models/profile_data.dart';

abstract interface class ProfileStore {
  Future<String?> read();
  Future<void> write(String value);
}

class MemoryProfileStore implements ProfileStore {
  MemoryProfileStore({this.value});
  String? value;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String value) async {
    this.value = value;
  }
}

class LocalProfileStore implements ProfileStore {
  LocalProfileStore({this.directory});
  final Directory? directory;
  Future<File> _file() async {
    final dir = directory ?? await getApplicationSupportDirectory();
    await dir.create(recursive: true);
    return File('${dir.path}${Platform.pathSeparator}yanshu-profile-v1.json');
  }

  @override
  Future<String?> read() async {
    final file = await _file();
    final backup = File('${file.path}.backup');
    if (!await file.exists() && await backup.exists()) {
      await backup.rename(file.path);
    }
    return await file.exists() ? file.readAsString() : null;
  }

  @override
  Future<void> write(String value) async {
    final file = await _file();
    final temp = File('${file.path}.tmp'), backup = File('${file.path}.backup');
    await temp.writeAsString(value, flush: true);
    var moved = false;
    try {
      if (await backup.exists()) await backup.delete();
      if (await file.exists()) {
        await file.rename(backup.path);
        moved = true;
      }
      await temp.rename(file.path);
    } catch (_) {
      if (moved && !await file.exists() && await backup.exists()) {
        await backup.rename(file.path);
      }
      rethrow;
    } finally {
      if (await temp.exists()) await temp.delete();
    }
    if (await backup.exists()) await backup.delete();
  }
}

class ProfileRepository {
  ProfileRepository(
    this.store, {
    this.initialSessionActive = true,
    this.sessionActiveOverride,
    this.client,
  });
  final ProfileStore store;
  final ApiClient? client;
  final bool initialSessionActive;
  bool? sessionActiveOverride;
  Future<ProfileData> load() async {
    final raw = await store.read();
    if (raw != null) {
      return ProfileData.fromJson(
        Map<String, dynamic>.from(jsonDecode(raw)),
      ).copyWith(sessionActive: sessionActiveOverride);
    }
    final data = ProfileData(
      sessionActive: initialSessionActive,
      accountId:
          '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}'
          '-${Random.secure().nextInt(1 << 32).toRadixString(36)}',
    );
    await save(data);
    return data;
  }

  bool get remoteActive => client?.accountId?.call() != null;

  ProfileData _merge(ProfileData local, Object? raw, String owner) {
    if (client?.accountId?.call() != owner ||
        raw is! Map ||
        raw['id'] != owner ||
        raw['version'] is! int ||
        raw['name'] is! String) {
      throw const ApiFailure('账户已切换，已停止原账户的同步');
    }
    return local.copyWith(
      personalization: raw['personalization'] is Map
          ? PersonalizationData.fromJson(raw['personalization'])
          : null,
      clearPersonalization: raw['personalization'] is! Map,
      accountId: owner,
      cloudVersion: raw['version'],
      name: raw['name'],
      job: raw['job'] as String?,
      company: raw['company'] as String?,
      email: raw['email'] as String?,
      phone: raw['phone'] as String?,
      avatar: raw['avatar'] as String?,
      clearAvatar: raw['avatar'] == null,
    );
  }

  Future<ProfileData> fetchCloud(ProfileData local) async {
    final owner = client?.accountId?.call();
    if (owner == null || owner != local.accountId) return local;
    final response = await client!.get(
      'auth/profile',
      authenticated: true,
      accountId: owner,
    );
    final remote = _merge(local, response['data'], owner);
    // 升级时只把同账号未同步的本机资料迁入空白云档案，不覆盖已有云档案。
    final blank =
        remote.cloudVersion == 1 &&
        remote.avatar == null &&
        remote.job.isEmpty &&
        remote.company.isEmpty &&
        remote.phone.isEmpty;
    final hasLocalEdits =
        local.avatar != null ||
        local.job.isNotEmpty ||
        local.company.isNotEmpty ||
        local.phone.isNotEmpty ||
        (local.name.isNotEmpty && local.name != remote.name) ||
        (local.email.isNotEmpty && local.email != remote.email);
    if (local.cloudVersion == 0 && blank && hasLocalEdits) {
      await savePersonal(local.copyWith(cloudVersion: remote.cloudVersion));
      return load();
    }
    final merged = remote;
    await save(merged);
    return merged;
  }

  Future<void> savePersonal(ProfileData next) async {
    final owner = client?.accountId?.call();
    if (owner == null) {
      if (client != null && next.cloudVersion > 0) {
        throw const ApiFailure('登录已失效，请重新登录');
      }
      await save(next);
      return;
    }
    if (owner != next.accountId) throw const ApiFailure('账户已切换，已停止原账户的同步');
    var version = next.cloudVersion;
    if (version == 0) {
      final current = await client!.get(
        'auth/profile',
        authenticated: true,
        accountId: owner,
      );
      version = _merge(next, current['data'], owner).cloudVersion;
    }
    final response = await client!.post(
      'auth/profile',
      authenticated: true,
      accountId: owner,
      data: {
        'version': version,
        'name': next.name,
        'job': next.job,
        'company': next.company,
        'email': next.email,
        'phone': next.phone,
        'avatar': next.avatar,
      },
    );
    // 云端确认后才更新本机；断网或版本冲突不伪装成保存成功。
    await save(_merge(next, response['data'], owner));
  }

  Future<void> savePersonalization(
    ProfileData current,
    Map<String, dynamic> payload,
  ) async {
    final owner = client?.accountId?.call();
    if (owner == null || owner != current.accountId) {
      throw const ApiFailure('登录已失效，请重新登录');
    }
    var version = current.cloudVersion;
    if (version == 0) {
      final fetched = await client!.get(
        'auth/profile',
        authenticated: true,
        accountId: owner,
      );
      version = _merge(current, fetched['data'], owner).cloudVersion;
    }
    try {
      final response = await client!.post(
        'auth/personalization',
        authenticated: true,
        accountId: owner,
        data: {...payload, 'version': version},
      );
      await save(_merge(current, response['data'], owner));
    } on ApiFailure catch (failure) {
      if (failure.status == 409) {
        // Fetch current version, but never silently replay edits over another device.
        await fetchCloud(current);
      }
      rethrow;
    }
  }

  Future<void> clearPersonal() async {
    final previous = await load();
    await save(
      ProfileData(
        language: previous.language,
        appearance: previous.appearance,
        hapticFeedback: previous.hapticFeedback,
        backgroundNotifications: previous.backgroundNotifications,
        sessionActive: false,
      ),
    );
  }

  Future<void> save(ProfileData data) async {
    await store.write(jsonEncode(data.toJson()));
    if (sessionActiveOverride != null) {
      sessionActiveOverride = data.sessionActive;
    }
  }
}
