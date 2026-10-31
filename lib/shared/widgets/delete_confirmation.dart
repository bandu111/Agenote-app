import 'package:flutter/material.dart';
import 'confirmation_dialog.dart';

Future<bool> showDeleteConfirmation(
  BuildContext context, {
  required String title,
  required String message,
  String action = '确认删除',
}) => showAppConfirmation(
  context,
  title: title,
  message: message,
  action: action,
  cancel: '先留着',
  icon: Icons.delete_outline,
  actionColor: const Color(0xFFD82532),
);
