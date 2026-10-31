import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../../../app/l10n/app_strings.dart';
import 'auth_brand_widgets.dart';
import '../../first_run/brand_splash.dart';
import '../../profile/viewmodels/profile_view_model.dart';
import '../viewmodels/auth_view_model.dart';

class AuthPage extends StatefulWidget {
  const AuthPage({super.key, this.register = false});
  final bool register;

  @override
  State<AuthPage> createState() => _AuthPageState();
}

class _AuthPageState extends State<AuthPage> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController(), _email = TextEditingController();
  final _password = TextEditingController(),
      _confirmation = TextEditingController();
  bool _hidePassword = true, _hideConfirmation = true;

  @override
  void dispose() {
    for (final controller in [_name, _email, _password, _confirmation]) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    FocusScope.of(context).unfocus();
    final ok = await context.read<AuthViewModel>().submit(
      register: widget.register,
      name: _name.text,
      email: _email.text,
      password: _password.text,
    );
    if (ok && mounted) context.go('/home');
  }

  void _switch() {
    context.read<AuthViewModel>().clearError();
    context.replace(widget.register ? '/login' : '/register');
  }

  Future<void> _recovery() async {
    FocusScope.of(context).unfocus();
    _password.clear();
    final done = await context.push<bool>(
      '/forgot-password',
      extra: _email.text,
    );
    if (done == true && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('密码已重置，请用新密码登录')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthViewModel>();
    final profile = context.watch<ProfileViewModel>();
    final busy = auth.submitting || profile.saving;
    return AuthAppearance(
      child: Builder(
        builder: (context) {
          final colors = Theme.of(context).colorScheme;
          return Scaffold(
            key: ValueKey(widget.register ? 'register-page' : 'login-page'),
            body: SafeArea(
              child: LayoutBuilder(
                builder: (context, constraints) => SingleChildScrollView(
                  keyboardDismissBehavior:
                      ScrollViewKeyboardDismissBehavior.onDrag,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 24,
                  ),
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 420),
                      child: AutofillGroup(
                        child: Form(
                          key: _form,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              SizedBox(
                                height: constraints.maxHeight > 750 ? 36 : 8,
                              ),
                              Row(
                                children: [
                                  const BrandMark(size: 38),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Text(
                                      'Agenote',
                                      style: TextStyle(
                                        fontSize: 17,
                                        fontWeight: FontWeight.w600,
                                        color: colors.onSurface,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 30),
                              Text(
                                (widget.register ? '创建你的账户' : '欢迎回来').tr(
                                  context,
                                ),
                                style: TextStyle(
                                  fontSize: 28,
                                  fontWeight: FontWeight.w600,
                                  height: 1.3,
                                  color: colors.onSurface,
                                ),
                              ),
                              const SizedBox(height: 9),
                              Text(
                                '记录会议，推进工作'.tr(context),
                                style: TextStyle(
                                  fontSize: 14,
                                  height: 1.5,
                                  color: colors.onSurfaceVariant,
                                ),
                              ),
                              const SizedBox(height: 26),
                              AuthFormSurface(
                                child: Padding(
                                  padding: const EdgeInsets.all(20),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                      Text(
                                        (widget.register
                                                ? '注册 Agenote'
                                                : '邮箱登录')
                                            .tr(context),
                                        style: const TextStyle(
                                          fontSize: 18,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                      const SizedBox(height: 22),
                                      if (widget.register) ...[
                                        _field(
                                          context,
                                          'name',
                                          '昵称',
                                          _name,
                                          busy: busy,
                                          icon: Icons.person_outline,
                                          autofill: const [
                                            AutofillHints.nickname,
                                          ],
                                          validator: (value) =>
                                              value == null ||
                                                  value.trim().isEmpty
                                              ? '请输入昵称'.tr(context)
                                              : value.trim().length > 40
                                              ? '昵称请控制在40字以内'.tr(context)
                                              : null,
                                        ),
                                        const SizedBox(height: 18),
                                      ],
                                      _field(
                                        context,
                                        'email',
                                        '邮箱',
                                        _email,
                                        busy: busy,
                                        icon: Icons.mail_outline,
                                        autofill: const [AutofillHints.email],
                                        keyboard: TextInputType.emailAddress,
                                        validator: (value) =>
                                            value == null ||
                                                !RegExp(
                                                  r'^[^\s@]+@[^\s@]+\.[^\s@]+$',
                                                ).hasMatch(value.trim())
                                            ? '请输入有效邮箱'.tr(context)
                                            : null,
                                      ),
                                      const SizedBox(height: 18),
                                      _field(
                                        context,
                                        'password',
                                        '密码',
                                        _password,
                                        busy: busy,
                                        icon: Icons.lock_outline,
                                        hidden: _hidePassword,
                                        toggle: () => setState(
                                          () => _hidePassword = !_hidePassword,
                                        ),
                                        autofill: [
                                          widget.register
                                              ? AutofillHints.newPassword
                                              : AutofillHints.password,
                                        ],
                                        last: !widget.register,
                                        validator: (value) {
                                          if (value == null || value.isEmpty) {
                                            return '请输入密码'.tr(context);
                                          }
                                          if (widget.register &&
                                              (value.length < 8 ||
                                                  value.length > 128)) {
                                            return '密码长度为8至128位'.tr(context);
                                          }
                                          return null;
                                        },
                                      ),
                                      if (widget.register) ...[
                                        const SizedBox(height: 18),
                                        _field(
                                          context,
                                          'confirmation',
                                          '确认密码',
                                          _confirmation,
                                          busy: busy,
                                          icon: Icons.lock_outline,
                                          hidden: _hideConfirmation,
                                          toggle: () => setState(
                                            () => _hideConfirmation =
                                                !_hideConfirmation,
                                          ),
                                          autofill: const [
                                            AutofillHints.newPassword,
                                          ],
                                          last: true,
                                          validator: (value) =>
                                              value != _password.text
                                              ? '两次输入的密码不一致'.tr(context)
                                              : null,
                                        ),
                                      ] else
                                        Align(
                                          alignment: Alignment.centerRight,
                                          child: TextButton(
                                            onPressed: busy ? null : _recovery,
                                            child: Text(
                                              '忘记密码？'.tr(context),
                                              style: const TextStyle(
                                                fontSize: 12,
                                              ),
                                            ),
                                          ),
                                        ),
                                      if (auth.error != null) ...[
                                        const SizedBox(height: 12),
                                        Semantics(
                                          liveRegion: true,
                                          child: Text(
                                            auth.error!.tr(context),
                                            key: const ValueKey('auth-error'),
                                            style: TextStyle(
                                              color: colors.error,
                                              fontSize: 12,
                                              height: 1.5,
                                            ),
                                          ),
                                        ),
                                      ],
                                      const SizedBox(height: 20),
                                      AuthButtonSurface(
                                        disabled: busy,
                                        child: FilledButton(
                                          key: const ValueKey('auth-submit'),
                                          onPressed: busy ? null : _submit,
                                          style: FilledButton.styleFrom(
                                            minimumSize: const Size.fromHeight(
                                              54,
                                            ),
                                            backgroundColor: Colors.transparent,
                                            disabledBackgroundColor:
                                                Colors.transparent,
                                            foregroundColor: Colors.white,
                                            disabledForegroundColor:
                                                Colors.white,
                                            shape: RoundedRectangleBorder(
                                              borderRadius:
                                                  BorderRadius.circular(99),
                                            ),
                                          ),
                                          child: Padding(
                                            padding: const EdgeInsets.symmetric(
                                              vertical: 12,
                                            ),
                                            child: Text(
                                              (auth.submitting
                                                      ? '正在连接…'
                                                      : widget.register
                                                      ? '创建账户'
                                                      : '登录')
                                                  .tr(context),
                                            ),
                                          ),
                                        ),
                                      ),
                                      const SizedBox(height: 14),
                                      Wrap(
                                        alignment: WrapAlignment.center,
                                        crossAxisAlignment:
                                            WrapCrossAlignment.center,
                                        children: [
                                          Text(
                                            (widget.register
                                                    ? '已有账户？'
                                                    : '还没有账户？')
                                                .tr(context),
                                            style: TextStyle(
                                              fontSize: 12,
                                              color: colors.onSurfaceVariant,
                                            ),
                                          ),
                                          TextButton(
                                            key: const ValueKey('auth-switch'),
                                            onPressed: busy ? null : _switch,
                                            child: Text(
                                              (widget.register ? '去登录' : '立即注册')
                                                  .tr(context),
                                              style: const TextStyle(
                                                fontSize: 12,
                                                fontWeight: FontWeight.w600,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              const SizedBox(height: 16),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _field(
    BuildContext context,
    String id,
    String label,
    TextEditingController controller, {
    required bool busy,
    required IconData icon,
    required FormFieldValidator<String> validator,
    List<String>? autofill,
    TextInputType? keyboard,
    bool? hidden,
    VoidCallback? toggle,
    bool last = false,
  }) {
    final colors = Theme.of(context).colorScheme;
    final border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(16),
      borderSide: BorderSide(
        color: colors.outlineVariant.withValues(alpha: .55),
      ),
    );
    return TextFormField(
      key: ValueKey('auth-$id'),
      controller: controller,
      enabled: !busy,
      autofillHints: autofill,
      keyboardType: keyboard,
      obscureText: hidden ?? false,
      autocorrect: false,
      enableSuggestions: hidden == null,
      textCapitalization: TextCapitalization.none,
      textInputAction: last ? TextInputAction.done : TextInputAction.next,
      onFieldSubmitted: last ? (_) => _submit() : null,
      validator: validator,
      style: TextStyle(fontSize: 16, height: 1.5, color: colors.onSurface),
      decoration: InputDecoration(
        labelText: label.tr(context),
        floatingLabelBehavior: FloatingLabelBehavior.always,
        filled: true,
        fillColor: colors.surface,
        labelStyle: TextStyle(color: colors.onSurfaceVariant, fontSize: 12),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 16,
        ),
        border: border,
        enabledBorder: border,
        disabledBorder: border,
        focusedBorder: border.copyWith(
          borderSide: BorderSide(color: colors.primary, width: 1.2),
        ),
        errorBorder: border.copyWith(
          borderSide: BorderSide(color: colors.error),
        ),
        focusedErrorBorder: border.copyWith(
          borderSide: BorderSide(color: colors.error, width: 1.2),
        ),
        errorMaxLines: 3,
        prefixIcon: Icon(icon, size: 19, color: colors.onSurfaceVariant),
        suffixIcon: toggle == null
            ? null
            : IconButton(
                onPressed: busy ? null : toggle,
                tooltip: (hidden! ? '显示密码' : '隐藏密码').tr(context),
                icon: Icon(
                  hidden
                      ? Icons.visibility_off_outlined
                      : Icons.visibility_outlined,
                  size: 19,
                ),
              ),
      ),
    );
  }
}
