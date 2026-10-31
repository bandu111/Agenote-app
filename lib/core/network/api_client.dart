import 'dart:async';
import 'dart:convert';
import 'package:dio/dio.dart';
import 'api_config.dart';

/// 统一超时、凭据注入和一次性重试；登录注册不会自动重放。
class ApiClient {
  ApiClient({required String baseUrl, Dio? dio}) : dio = dio ?? Dio() {
    this.dio.options = BaseOptions(
      baseUrl: baseUrl,
      connectTimeout: const Duration(seconds: 10),
      sendTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 15),
      headers: {'Accept': 'application/json'},
      followRedirects: false,
    );
    this.dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          try {
            if (options.extra['authenticated'] == true) {
              final token = await accessToken?.call();
              final expected = options.extra['accountId'];
              if (expected != null && expected != accountId?.call()) {
                throw const ApiFailure('账户已切换，已停止原账户的同步');
              }
              if (token != null) {
                options.headers['Authorization'] = 'Bearer $token';
              }
            }
            handler.next(options);
          } catch (error) {
            handler.reject(DioException(requestOptions: options, error: error));
          }
        },
        onError: (error, handler) async {
          final request = error.requestOptions;
          if (error.response?.statusCode != 401 ||
              request.extra['authenticated'] != true ||
              request.extra['retried'] == true) {
            handler.next(error);
            return;
          }
          try {
            final previous = request.headers['Authorization'] as String?;
            if (await refreshSession?.call(previous) != true) {
              handler.next(error);
              return;
            }
            request.extra['retried'] = true;
            handler.resolve(await this.dio.fetch<Object?>(request));
          } catch (failure) {
            handler.reject(
              DioException(requestOptions: request, error: failure),
            );
          }
        },
      ),
    );
  }

  final Dio dio;
  Future<void> downloadAudio(
    String id,
    String target, {
    required String owner,
    required Duration start,
    required Duration end,
  }) async {
    if (accountId?.call() != owner) throw const ApiFailure('账户已切换');
    await dio.download(
      'meetings/audio/${Uri.encodeComponent(id)}/content',
      target,
      queryParameters: {
        'start': start.inMilliseconds,
        'end': end.inMilliseconds,
      },
      options: _options(true, owner)
        ..receiveTimeout = const Duration(minutes: 5),
    );
    if (accountId?.call() != owner) throw const ApiFailure('账户已切换');
  }

  Future<String?> Function()? accessToken;
  String? Function()? accountId;
  Future<bool> Function(String? previousAuthorization)? refreshSession;

  Future<Map<String, dynamic>> get(
    String path, {
    bool authenticated = false,
    String? accountId,
  }) => _request(
    () => dio.get<Object?>(path, options: _options(authenticated, accountId)),
  );

  Future<Map<String, dynamic>> post(
    String path, {
    Map<String, dynamic>? data,
    bool authenticated = false,
    String? accountId,
    Duration? receiveTimeout,
  }) => _request(
    () => dio.post<Object?>(
      path,
      data: data,
      options: _options(authenticated, accountId)
        ..receiveTimeout = receiveTimeout,
    ),
  );

  Future<Map<String, dynamic>> delete(
    String path, {
    required String accountId,
    Map<String, dynamic>? data,
  }) => _request(
    () => dio.delete<Object?>(
      path,
      data: data,
      options: _options(true, accountId),
    ),
  );

  /// 与普通请求共用认证和令牌刷新；离开流时取消底层连接，不缓存整段模型响应。
  Stream<Map<String, dynamic>> postEvents(
    String path, {
    required Map<String, dynamic> data,
    required String accountId,
  }) async* {
    final cancel = CancelToken();
    try {
      final response = await dio.post<ResponseBody>(
        path,
        data: data,
        cancelToken: cancel,
        options: _options(true, accountId)
          ..responseType = ResponseType.stream
          ..headers = {'Accept': 'text/event-stream'}
          ..receiveTimeout = const Duration(seconds: 35),
      );
      if (response.data == null ||
          !(response.headers.value('content-type') ?? '').contains(
            'text/event-stream',
          )) {
        throw const ApiFailure('会议提示服务尚未支持流式响应');
      }
      final lines = response.data!.stream
          .cast<List<int>>()
          .transform(utf8.decoder)
          .transform(const LineSplitter());
      final parts = <String>[];
      await for (final line in lines) {
        if (this.accountId?.call() != accountId) {
          throw const ApiFailure('账户已切换');
        }
        if (line.startsWith('data:')) {
          parts.add(line.substring(5).trimLeft());
        } else if (line.isEmpty && parts.isNotEmpty) {
          final value = jsonDecode(parts.join('\n'));
          parts.clear();
          if (value is! Map) throw const ApiFailure('会议提示流格式无法读取');
          yield Map<String, dynamic>.from(value);
        }
      }
    } on DioException catch (error) {
      if (error.error is ApiFailure) throw error.error! as ApiFailure;
      throw ApiFailure('会议提示连接中断，原始记录已保留', status: error.response?.statusCode);
    } on FormatException {
      throw const ApiFailure('会议提示流格式无法读取');
    } finally {
      if (!cancel.isCancelled) cancel.cancel();
    }
  }

  Options _options(bool authenticated, String? accountId) =>
      Options(extra: {'authenticated': authenticated, 'accountId': accountId});

  Future<Map<String, dynamic>> _request(
    Future<Response<Object?>> Function() send,
  ) async {
    try {
      final response = await send();
      final body = response.data;
      if (body is! Map || body['code'] != response.statusCode) {
        throw const ApiFailure('账户服务返回的数据无法读取');
      }
      return Map<String, dynamic>.from(body);
    } on DioException catch (error) {
      if (error.error is ApiFailure) throw error.error! as ApiFailure;
      final status = error.response?.statusCode;
      final body = error.response?.data;
      final code = body is Map ? body['message'] : null;
      final message = switch (code) {
        'voiceprint_session_expired' => '声纹注册已过期，请重新开始',
        'voiceprint_configuration_changed' => '声纹模型或密钥已更新，请取消后重新注册',
        'voiceprint_consent_required' => '请阅读最新声纹说明并单独同意',
        'voiceprint_unavailable' => '本机声纹服务尚未准备就绪',
        'voiceprint_busy' => '声纹处理繁忙，请稍后重试',
        'voiceprint_not_ready' => '请完成录音检查，或取消本次注册后重新开始',
        'voiceprint_samples_inconsistent' => '三段声音不一致，无法判断哪段正确，请独自重新录制三段',
        'wechat_binding_key_unconfigured' => '微信绑定服务尚未配置，请稍后重试',
        'wechat_channel_unavailable' => '微信授权服务暂时不可用，请重新获取二维码',
        'wechat_already_bound' => '当前账号已连接微信，请先解除原连接',
        'wechat_not_bound' => '请先完成微信授权',
        'wechat_binding_changed' => '微信连接状态已更新，请刷新后重试',
        'outcome_not_ready_or_quota_exceeded' => '纪要尚未就绪或已达到今天的分析限额',
        'personalization_closed' => '个性化设置已完成，请重新加载资料',
        'personalization_step_conflict' => '请先完成第一步',
        'demo_reset_token_invalid' => '查询结果已过期，请重新查找账号',
        'profile_version_conflict' => '资料已在其他设备更新，请返回刷新后重试',
        'invalid_avatar' => '头像格式无效，请重新选择',
        'current_password_incorrect' => '当前密码不正确',
        'password_unchanged' => '新密码不能与当前密码相同',
        'invalid_credentials' => '邮箱或密码不正确',
        'email_already_registered' => '该邮箱已注册，请直接登录',
        'too_many_requests' => '操作过于频繁，请稍后再试',
        'invalid_request' => '请检查填写的信息',
        'database_unavailable' => '账户服务暂时不可用，请稍后重试',
        'meeting_revision_conflict' => '会议记录已更新，请重新同步',
        'meeting_not_found' => '会议云端记录不存在',
        'meeting_deleted' => '这场会议已删除',
        'meeting_still_recording' => '会议仍在录音，请先结束会议',
        'meeting_analysis_busy' => '会议分析繁忙，稍后重试，本地记录已保留',
        'meeting_analysis_unavailable' => '会议分析暂不可用，本地记录已保留',
        'action_source_changed' ||
        'tool_source_changed' => '相关依据已变更，等待重新核对后再确认',
        'action_changed' || 'task_version_changed' => '事项已更新，请刷新通知后再确认',
        'action_expired' => '该日程时间已过，请重新确认时间',
        'action_device_mismatch' => '该日程已由另一台设备接手，请在原设备继续',
        'tool_execution_incomplete' => '执行暂未完成，已保存进度，可稍后重试',
        _ when status == 401 => '登录已失效，请重新登录',
        _ when status != null && status >= 500 => '账户服务暂时不可用，请稍后重试',
        _ => '暂时无法连接账户服务，请稍后重试',
      };
      throw ApiFailure(
        message,
        status: status,
        code: code is String ? code : null,
      );
    }
  }
}
