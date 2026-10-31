import 'dart:convert';
import 'dart:io';
import 'package:integration_test/integration_test_driver_extended.dart';

Future<void> main() => integrationDriver(
  writeResponseOnFailure: true,
  onScreenshot: (name, bytes, [args]) async {
    await File('build/task-checklist-$name.png').writeAsBytes(bytes);
    return true;
  },
  responseDataCallback: (data) async {
    if (data == null) return;
    await File('build/task_checklist_phone_report.json').writeAsString(
      const JsonEncoder.withIndent(
        '  ',
      ).convert(Map<String, dynamic>.from(data)..remove('screenshots')),
    );
  },
);
