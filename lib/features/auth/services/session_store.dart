import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

abstract interface class SessionStore {
  Future<String?> read();
  Future<void> write(String value);
  Future<void> clear();
}

/// 单条加密记录保存整组令牌；按服务地址隔离，禁止写入普通资料文件。
class SecureSessionStore implements SessionStore {
  SecureSessionStore(String baseUrl, {FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage(),
      _key = 'yanshu.auth.v1.${sha256.convert(utf8.encode(baseUrl))}';
  final FlutterSecureStorage _storage;
  final String _key;
  @override
  Future<String?> read() => _storage.read(key: _key);
  @override
  Future<void> write(String value) => _storage.write(key: _key, value: value);
  @override
  Future<void> clear() => _storage.delete(key: _key);
}
