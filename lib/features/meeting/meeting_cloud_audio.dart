import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import '../../core/network/api_client.dart';
import '../../core/network/api_config.dart';
import 'meeting_models.dart';

/// 录音停止后分块上传；服务端回报 offset，因此弱网重试不重传整场。
Future<void> uploadMeetingAudio(
  ApiClient client,
  MeetingRecord record, {
  bool Function()? isCurrent,
}) async {
  final owner = record.ownerId;
  if (owner == null ||
      record.demo ||
      !record.ended ||
      !record.cloudAudioEnabled) {
    return;
  }
  void check() {
    if (isCurrent != null && !isCurrent()) throw const ApiFailure('同步已暂停');
    if (client.accountId?.call() != owner) throw const ApiFailure('账户已切换');
  }

  for (final path in record.audioPaths.toSet()) {
    check();
    final file = File(path);
    if (!await file.exists()) throw const ApiFailure('原始录音文件不可用，云端上传未完成');
    final hash = await sha256.bind(file.openRead()).first;
    final size = await file.length();
    final initialized = await client.post(
      'meetings/${Uri.encodeComponent(record.id)}/audio',
      authenticated: true,
      accountId: owner,
      data: {
        'sha256': hash.toString(),
        'size': size,
        'sources': [
          for (final u in record.utterances)
            if (u.audioPath == path && u.hasAudio)
              {
                'id': u.id,
                'hash': sha256.convert(utf8.encode(u.raw)).toString(),
                'start': u.audioStart!.inMilliseconds,
                'end': u.audioEnd!.inMilliseconds,
              },
        ],
      },
    );
    check();
    final data = initialized['data'] as Map;
    final id = data['id'] as String;
    if (data['state'] == 'complete') {
      // 同一录音的来源可能已有新版本，重新完成以刷新已校验映射。
      await client.post(
        'meetings/audio/$id/complete',
        authenticated: true,
        accountId: owner,
      );
      continue;
    }
    var offset = data['offset'] as int;
    final input = await file.open();
    try {
      await input.setPosition(offset);
      while (offset < size) {
        check();
        final bytes = await input.read(1024 * 1024);
        if (bytes.isEmpty) throw const ApiFailure('录音文件不完整');
        final result = await client.post(
          'meetings/audio/$id/chunk',
          authenticated: true,
          accountId: owner,
          receiveTimeout: const Duration(seconds: 60),
          data: {'offset': offset, 'data': base64Encode(bytes)},
        );
        offset += bytes.length;
        if ((result['data'] as Map)['offset'] != offset) {
          throw const ApiFailure('录音上传位置不一致');
        }
      }
    } finally {
      await input.close();
    }
    check();
    await client.post(
      'meetings/audio/$id/complete',
      authenticated: true,
      accountId: owner,
      receiveTimeout: const Duration(seconds: 120),
    );
  }
}
