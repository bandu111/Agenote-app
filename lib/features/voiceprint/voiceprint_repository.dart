import 'dart:typed_data';
import 'package:dio/dio.dart';
import '../../core/network/api_client.dart';
import '../../core/network/api_config.dart';

class VoiceprintRepository {
  VoiceprintRepository(this.client, this.owner);
  final ApiClient client;
  final String owner;

  void checkAccount() {
    if (client.accountId?.call() != owner) {
      throw const ApiFailure('账户已切换，请重新进入我的声纹');
    }
  }

  Future<Map<String, dynamic>> status() async {
    checkAccount();
    final result = await client.get(
      'me/voiceprint',
      authenticated: true,
      accountId: owner,
    );
    checkAccount();
    return Map<String, dynamic>.from(result['data'] as Map);
  }

  Future<void> post(String suffix, [Map<String, dynamic>? data]) async {
    checkAccount();
    await client.post(
      'me/voiceprint$suffix',
      data: data,
      authenticated: true,
      accountId: owner,
    );
    checkAccount();
  }

  Future<void> delete(String suffix) async {
    checkAccount();
    await client.delete('me/voiceprint$suffix', accountId: owner);
    checkAccount();
  }

  Future<void> upload(String enrollment, String slot, Uint8List wav) async {
    checkAccount();
    try {
      final response = await client.dio.post<Object?>(
        'me/voiceprint/enrollments/$enrollment/samples/$slot',
        data: wav,
        options: Options(
          contentType: 'audio/wav',
          headers: {
            'X-Audio-Device-Type': 'builtInMic',
            'X-Audio-Device-Name': 'phone',
          },
          extra: {'authenticated': true, 'accountId': owner},
          receiveTimeout: const Duration(seconds: 30),
        ),
      );
      final body = response.data;
      if (body is! Map ||
          body['code'] != 200 ||
          body['data'] is! Map ||
          (body['data']['samples'] as Map?)?[slot]?['status'] != 'processing') {
        throw const ApiFailure('未收到这段录音的保存确认，本地录音已保留，请重试');
      }
    } on DioException {
      throw const ApiFailure('录音上传未完成，请刷新检查进度后重试');
    }
    checkAccount();
  }
}
