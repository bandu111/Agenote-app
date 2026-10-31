import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:path_provider/path_provider.dart';
import 'package:open_filex/open_filex.dart';
import '../../core/network/api_client.dart';
import '../profile/viewmodels/profile_view_model.dart';

class OutcomePdfButton extends StatefulWidget {
  const OutcomePdfButton({
    super.key,
    required this.client,
    required this.owner,
    required this.runId,
  });
  final ApiClient client;
  final String owner, runId;
  @override
  State<OutcomePdfButton> createState() => _OutcomePdfButtonState();
}

class _OutcomePdfButtonState extends State<OutcomePdfButton> {
  bool busy = false;
  String? error;
  bool get current =>
      mounted && widget.client.accountId?.call() == widget.owner;
  Future<void> open() async {
    if (!current || busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final result = await widget.client.dio.get<List<int>>(
        'assistant/outcomes/${Uri.encodeComponent(widget.runId)}/pdf',
        options: Options(
          responseType: ResponseType.bytes,
          extra: {'authenticated': true, 'accountId': widget.owner},
        ),
      );
      if (!current) return;
      final bytes = result.data;
      if (bytes == null ||
          bytes.length < 5 ||
          String.fromCharCodes(bytes.take(5)) != '%PDF-') {
        throw const FormatException('invalid_pdf');
      }
      final dir = await getTemporaryDirectory();
      if (!current) return;
      final safeId = widget.runId.replaceAll(RegExp('[^a-zA-Z0-9_-]'), '');
      final safeOwner = widget.owner.replaceAll(RegExp('[^a-zA-Z0-9_-]'), '');
      final cache = Directory('${dir.path}/agenote-report-cache');
      await cache.create(recursive: true);
      final cutoff = DateTime.now().subtract(const Duration(days: 1));
      await for (final entry in cache.list(followLinks: false)) {
        if (entry is File && entry.path.endsWith('.pdf')) {
          final stat = await entry.stat();
          if (stat.modified.isBefore(cutoff)) await entry.delete();
        }
      }
      final file = File('${cache.path}/Agenote-$safeOwner-$safeId.pdf');
      await file.writeAsBytes(bytes, flush: true);
      if (!current) {
        await file.delete();
        return;
      }
      final opened = await OpenFilex.open(file.path, type: 'application/pdf');
      if (opened.type != ResultType.done && current) {
        setState(() => error = '系统未能打开 PDF，请安装支持 PDF 的阅读器后重试');
      }
    } catch (_) {
      if (current) setState(() => error = 'PDF 暂时无法加载，请重试');
    } finally {
      busy = false;
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    if (context.watch<ProfileViewModel>().data.accountId != widget.owner) {
      return const SizedBox.shrink();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextButton.icon(
          onPressed: busy ? null : open,
          icon: const Icon(Icons.picture_as_pdf_outlined),
          label: Text(busy ? '正在加载 PDF…' : '查看 PDF 报告'),
        ),
        if (error != null)
          Text(
            error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
      ],
    );
  }
}
