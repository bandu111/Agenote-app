import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'recorder_models.dart';

abstract interface class RecorderDeviceRepository {
  Future<List<SavedRecorderDevice>> load();
  Future<void> save(List<SavedRecorderDevice> devices);
}

/// Installation-local records, never cloud binding or an assertion of online state.
class SecureRecorderDeviceRepository implements RecorderDeviceRepository {
  SecureRecorderDeviceRepository({FlutterSecureStorage? storage})
    : storage = storage ?? const FlutterSecureStorage();
  final FlutterSecureStorage storage;
  static const key = 'yanshu.recording_devices.v2';
  @override
  Future<List<SavedRecorderDevice>> load() async {
    final raw = await storage.read(key: key);
    if (raw == null) return [];
    final root = jsonDecode(raw) as Map<String, dynamic>;
    if (root['version'] != 1) throw const FormatException('device schema');
    return (root['devices'] as List)
        .map(
          (value) => SavedRecorderDevice.fromJson(
            Map<String, dynamic>.from(value as Map),
          ),
        )
        .toList();
  }

  @override
  Future<void> save(List<SavedRecorderDevice> devices) => storage.write(
    key: key,
    value: jsonEncode({
      'version': 1,
      'devices': devices.map((record) => record.toJson()).toList(),
    }),
  );
}
