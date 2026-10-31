import 'dart:convert';
import 'dart:io';
import 'package:integration_test/integration_test_driver_extended.dart';

Future<void> main() => integrationDriver(
  writeResponseOnFailure: true,
  onScreenshot: (name, bytes, [args]) async {
    await Directory('build/minutes-qa').create(recursive: true);
    await File('build/minutes-qa/phone-$name.png').writeAsBytes(bytes);
    return true;
  },
  responseDataCallback: (data) async {
    if (data != null) {
      await File('build/minutes-phone-report.json').writeAsString(
        const JsonEncoder.withIndent(
          '  ',
        ).convert(Map<String, dynamic>.from(data)..remove('screenshots')),
      );
    }
  },
);
