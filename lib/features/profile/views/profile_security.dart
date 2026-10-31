import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../app/l10n/app_strings.dart';
import '../../auth/viewmodels/auth_view_model.dart';
import '../../progress/viewmodels/voice_evidence_controller.dart';
import 'profile_components.dart';

/// 沿用个人资料的卡片、输入框与确认弹窗样式。
class ProfileSecurityPage extends StatefulWidget {
  const ProfileSecurityPage({super.key});
  @override
  State<ProfileSecurityPage> createState() => _ProfileSecurityPageState();
}

class _ProfileSecurityPageState extends State<ProfileSecurityPage> {
  final _form = GlobalKey<FormState>();
  final _current = TextEditingController(),
      _next = TextEditingController(),
      _repeat = TextEditingController();
  String? _error;
  @override
  void dispose() {
    _current.dispose();
    _next.dispose();
    _repeat.dispose();
    super.dispose();
  }

  Future<void> _change() async {
    if (!_form.currentState!.validate()) return;
    await context.read<VoiceEvidenceController>().suspend();
    if (!mounted) return;
    final auth = context.read<AuthViewModel>();
    final ok = await auth.secureAccount(
      currentPassword: _current.text,
      newPassword: _next.text,
    );
    if (!mounted) return;
    if (ok) {
      Navigator.pop(context);
    } else {
      setState(() => _error = auth.error);
    }
  }

  Future<void> _delete() async {
    if (_current.text.isEmpty) {
      setState(() => _error = '请输入当前密码');
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        final colors = Theme.of(dialogContext).colorScheme;
        return Dialog(
          backgroundColor: colors.surfaceContainerLowest,
          surfaceTintColor: Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          insetPadding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 380),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(22),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    '是否注销账户？'.tr(context),
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 14),
                  Text('云端账户、会议与资料将永久删除。本机原始录音仍保留。'.tr(context)),
                  const SizedBox(height: 24),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton(
                          style: FilledButton.styleFrom(
                            backgroundColor: colors.primary.withValues(
                              alpha: .10,
                            ),
                            foregroundColor: colors.onSurface,
                          ),
                          onPressed: () => Navigator.pop(dialogContext, false),
                          child: Text('取消'.tr(context)),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: FilledButton(
                          style: FilledButton.styleFrom(
                            backgroundColor: colors.error,
                            foregroundColor: colors.onError,
                          ),
                          onPressed: () => Navigator.pop(dialogContext, true),
                          child: Text('注销'.tr(context)),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
    if (confirmed != true || !mounted) return;
    await context.read<VoiceEvidenceController>().suspend();
    if (!mounted) return;
    final auth = context.read<AuthViewModel>();
    final ok = await auth.secureAccount(
      currentPassword: _current.text,
      delete: true,
    );
    if (!mounted) return;
    if (ok) {
      Navigator.pop(context);
    } else {
      setState(() => _error = auth.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthViewModel>();
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text('账户安全'.tr(context))),
      body: SafeArea(
        top: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: Form(
              key: _form,
              child: ListView(
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
                children: [
                  if (auth.submitting) const LinearProgressIndicator(),
                  ProfileSurface(
                    child: Padding(
                      padding: const EdgeInsets.all(18),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            '修改密码'.tr(context),
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            '修改后所有设备均需重新登录。'.tr(context),
                            style: TextStyle(
                              color: colors.onSurfaceVariant,
                              fontSize: 12,
                            ),
                          ),
                          const SizedBox(height: 18),
                          for (final field in [
                            ('当前密码', _current),
                            ('新密码', _next),
                            ('确认新密码', _repeat),
                          ]) ...[
                            TextFormField(
                              controller: field.$2,
                              obscureText: true,
                              enableSuggestions: false,
                              autocorrect: false,
                              enabled: !auth.submitting,
                              maxLength: 128,
                              decoration: InputDecoration(
                                labelText: field.$1.tr(context),
                                counterText: '',
                                filled: true,
                                fillColor: colors.primary.withValues(
                                  alpha: .045,
                                ),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                  borderSide: BorderSide.none,
                                ),
                              ),
                              validator: (value) {
                                if (value == null || value.isEmpty) {
                                  return '请输入密码'.tr(context);
                                }
                                if (field.$2 != _current &&
                                    (value.length < 8 ||
                                        value.trim().isEmpty)) {
                                  return '密码至少 8 位'.tr(context);
                                }
                                if (field.$2 == _repeat &&
                                    value != _next.text) {
                                  return '两次密码不一致'.tr(context);
                                }
                                return null;
                              },
                            ),
                            const SizedBox(height: 16),
                          ],
                          FilledButton(
                            onPressed: auth.submitting ? null : _change,
                            child: Text('修改密码'.tr(context)),
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      child: Text(
                        _error!.tr(context),
                        style: TextStyle(color: colors.error),
                      ),
                    ),
                  const SizedBox(height: 26),
                  ProfileSurface(
                    child: Padding(
                      padding: const EdgeInsets.all(18),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            '注销账户'.tr(context),
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            '注销需验证上方当前密码，操作不可恢复。'.tr(context),
                            style: TextStyle(
                              color: colors.onSurfaceVariant,
                              fontSize: 12,
                            ),
                          ),
                          const SizedBox(height: 16),
                          OutlinedButton(
                            onPressed: auth.submitting ? null : _delete,
                            style: OutlinedButton.styleFrom(
                              foregroundColor: colors.error,
                            ),
                            child: Text('注销账户'.tr(context)),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
