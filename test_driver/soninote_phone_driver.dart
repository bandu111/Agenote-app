import 'dart:convert';
import 'dart:io';
import 'package:integration_test/integration_test_driver_extended.dart';

Future<void> main() => integrationDriver(
  writeResponseOnFailure: true,
  onScreenshot: (name, bytes, [args]) async {
    await File('build/soninote-phone-$name.png').writeAsBytes(bytes);
    return true; // 保存后由实际图像检查完成视觉核对。
  },
  responseDataCallback: (data) async {
    if (data == null) return;
    final report = Map<String, dynamic>.from(data)..remove('screenshots');
    await File(
      'build/soninote_phone_report.json',
    ).writeAsString(const JsonEncoder.withIndent('  ').convert(report));
  },
);
