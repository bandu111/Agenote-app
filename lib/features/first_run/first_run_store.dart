import 'package:flutter_secure_storage/flutter_secure_storage.dart';

abstract interface class FirstRunStore {
  Future<bool> completed();
  Future<void> complete();
}

/// App-level introduction, independent of login/logout and profile preferences.
class SecureFirstRunStore implements FirstRunStore {
  const SecureFirstRunStore({this.storage = const FlutterSecureStorage()});
  final FlutterSecureStorage storage;
  static const key = 'agenote.onboarding.v1.completed';
  @override
  Future<bool> completed() async => await storage.read(key: key) == 'true';
  @override
  Future<void> complete() => storage.write(key: key, value: 'true');
}
