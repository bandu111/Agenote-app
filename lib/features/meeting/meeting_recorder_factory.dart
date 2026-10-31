import 'dart:io';
import '../../core/network/api_client.dart';
import '../../core/network/api_config.dart';
import 'meeting_services.dart';
import 'tencent_speech.dart';

/// 正式入口和页面备用入口共用同一选择，不能由录音目录注入绕过供应商配置。
DeviceMeetingRecorder createDeviceMeetingRecorder({
  Directory? directory,
  ApiClient? apiClient,
  String? provider,
}) {
  // 无网络客户端的独立组件保留离线能力；main.dart 始终注入认证客户端。
  final selected =
      provider ?? (apiClient == null ? 'local' : ApiConfig.speechProvider);
  if (selected != 'local' && selected != 'tencent') {
    throw StateError('未支持的实时转写服务');
  }
  if (selected == 'tencent' && apiClient == null) {
    throw StateError('腾讯云转写需要账户网络客户端');
  }
  return DeviceMeetingRecorder(
    directory: directory,
    recoverNetwork: selected == 'tencent',
    recognizerFactory: selected == 'tencent'
        ? (id) => TencentSpeechWorker(apiClient!, id)
        : null,
  );
}
