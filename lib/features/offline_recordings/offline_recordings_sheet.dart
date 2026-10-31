import 'package:flutter/material.dart';
import 'transfer_space_page.dart';

Future<void> showOfflineRecordings(BuildContext context) => Navigator.of(
  context,
).push<void>(MaterialPageRoute(builder: (_) => const TransferSpacePage()));
