import '../../../core/network/api_config.dart';
import '../../profile/repositories/profile_repository.dart';
import '../repositories/auth_repository.dart';

/// 启动时以服务端会话为准，普通资料文件里的登录标记不能作为认证依据。
Future<String?> restoreAccountSession(
  SessionAuthRepository auth,
  ProfileRepository profiles,
) async {
  try {
    final current = await profiles.load();
    await profiles.save(current.copyWith(sessionActive: false));
    final identity = await auth.restore();
    if (identity != null) {
      final different = identity.id != current.accountId;
      await profiles.save(
        current.copyWith(
          clearPersonalization: different,
          accountId: identity.id,
          name:
              !different && current.cloudVersion == 0 && current.name.isNotEmpty
              ? current.name
              : identity.name,
          email: !different && current.email.isNotEmpty
              ? current.email
              : identity.email,
          job: different ? '' : null,
          company: different ? '' : null,
          phone: different ? '' : null,
          clearAvatar: different,
          cloudVersion: different ? 0 : null,
          sessionActive: true,
        ),
      );
    }
    return null;
  } on ApiFailure catch (failure) {
    return failure.message;
  } catch (_) {
    return '账户状态读取失败，请重新登录';
  }
}
