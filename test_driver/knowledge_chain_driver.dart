import 'dart:convert';
import 'dart:io';
import 'package:integration_test/integration_test_driver.dart';

Future<void> main() => integrationDriver(
  writeResponseOnFailure: true,
  responseDataCallback: (data) async {
    if (data != null) {
      await File(
        'docs/knowledge_chain_device_result.json',
      ).writeAsString(const JsonEncoder.withIndent('  ').convert(data));
    }
  },
);
