import 'package:flutter/foundation.dart';
import 'dart:convert';
import 'package:crypto/crypto.dart';

enum AppEnvironment { local, cloud }

/// 构建时选择环境，禁止云端包误用本地地址或混用应用标识。
class ApiEnvironment {
  const ApiEnvironment._(this.environment, this.baseUrl);
  static const localUrl = 'http://127.0.0.1:8001/api/v1/';
  static const cloudUrl = 'https://124.220.169.122/api/v1/';
  final AppEnvironment environment;
  final String baseUrl;

  static ApiEnvironment resolve({
    String name = '',
    String flavor = '',
    String overrideUrl = '',
    bool debug = true,
  }) {
    final selected = name.isNotEmpty
        ? name
        : (flavor.isNotEmpty ? flavor : 'cloud');
    if (!['local', 'cloud'].contains(selected) ||
        (flavor.isNotEmpty && flavor != selected)) {
      throw const ApiFailure('应用包与服务环境不一致，请检查启动配置');
    }
    final environment = AppEnvironment.values.byName(selected);
    final value = overrideUrl.isNotEmpty
        ? overrideUrl
        : environment == AppEnvironment.cloud
        ? cloudUrl
        : localUrl;
    final uri = Uri.tryParse(value);
    if (uri == null ||
        !uri.hasAuthority ||
        uri.userInfo.isNotEmpty ||
        uri.query.isNotEmpty ||
        uri.fragment.isNotEmpty ||
        !['http', 'https'].contains(uri.scheme) ||
        (!debug && uri.scheme != 'https') ||
        (environment == AppEnvironment.cloud &&
            (uri.scheme != 'https' ||
                ['localhost', '127.0.0.1', '::1'].contains(uri.host))) ||
        (environment == AppEnvironment.local &&
            ['150.109.236.254', '124.220.169.122'].contains(uri.host))) {
      throw const ApiFailure('请配置与当前环境一致的有效服务地址');
    }
    return ApiEnvironment._(
      environment,
      value.endsWith('/') ? value : '$value/',
    );
  }

  /// 本地默认地址沿用旧目录，保留已经保存的本地资料；其他环境独立保存。
  String get dataSubdirectory =>
      environment == AppEnvironment.local && baseUrl == localUrl
      ? ''
      : 'environments/${environment.name}-${sha256.convert(utf8.encode(baseUrl)).toString().substring(0, 16)}';
}

/// 普通启动默认云端；本地调试必须显式选择 local，数据与令牌仍隔离。
abstract final class ApiConfig {
  static ApiEnvironment get current => ApiEnvironment.resolve(
    name: const String.fromEnvironment('YANSHU_ENV'),
    flavor: const String.fromEnvironment('FLUTTER_APP_FLAVOR'),
    overrideUrl: const String.fromEnvironment('YANSHU_API_BASE_URL'),
    debug: kDebugMode,
  );
  static String get baseUrl => current.baseUrl;
  static String get speechProvider {
    const configured = String.fromEnvironment('ASR_PROVIDER');
    if (configured.isNotEmpty) return configured;
    // 后端部署位置与转写引擎独立：本机后端也通过腾讯云进行实时转写。
    return 'tencent';
  }
}

/// 仅携带可向用户展示的文案，不保存密码、令牌和服务端异常原文。
class ApiFailure implements Exception {
  const ApiFailure(this.message, {this.status, this.code});
  final String message;
  final int? status;
  final String? code;
}
