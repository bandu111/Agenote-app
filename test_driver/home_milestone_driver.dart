import 'dart:convert';
import 'dart:io';
import 'package:integration_test/integration_test_driver_extended.dart';

Future<void> main() => integrationDriver(
  writeResponseOnFailure: true,
  onScreenshot: (name, bytes, [args]) async {
    await File('build/device-goal-$name.png').writeAsBytes(bytes);
    return true; // 这里只保存图像，视觉核对由实际截图完成。
  },
  responseDataCallback: (data) async {
    if (data == null) return;
    final report = Map<String, dynamic>.from(data)..remove('screenshots');
    await File(
      'build/home_milestone_phone_20261025.json',
    ).writeAsString(const JsonEncoder.withIndent('  ').convert(report));
  },
);
