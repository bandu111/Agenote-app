import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../../../core/network/api_config.dart';
import '../../first_run/brand_splash.dart';
import '../../first_run/brand_tokens.dart';
import '../repositories/auth_repository.dart';
import '../viewmodels/auth_view_model.dart';
import 'auth_brand_widgets.dart';

class ForgotPasswordPage extends StatefulWidget {
  const ForgotPasswordPage({super.key, this.initialEmail = ''});
  final String initialEmail;
  @override
  State<ForgotPasswordPage> createState() => _ForgotPasswordPageState();
}

class _ForgotPasswordPageState extends State<ForgotPasswordPage> {
  final _form = GlobalKey<FormState>();
  late final _email = TextEditingController(text: widget.initialEmail);
  final _password = TextEditingController(), _confirm = TextEditingController();
  int _step = 0;
  bool _busy = false, _hidden = true, _hiddenConfirmation = true, _done = false;
  String? _token, _error;
  static const _meta = [
    ('找回你的账号。', '输入注册时使用的邮箱，我们会先确认这个账号是否存在。'),
    ('账号已找到。', '确认是你要找回的邮箱，就可以为它设置一个新密码。'),
    ('设置新密码。', '新密码至少 8 位，并包含至少 1 个数字。'),
  ];
  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  void _back() {
    if (_busy) return;
    if (_done) {
      _login();
      return;
    }
    if (_step > 0) {
      setState(() {
        _step--;
        _error = null;
        if (_step == 0) _token = null;
      });
    } else if (context.canPop()) {
      context.pop();
    } else {
      context.go('/login');
    }
  }

  PasswordRecoveryRepository get _repository {
    final r = context.read<AuthViewModel>().repository;
    if (r is! PasswordRecoveryRepository) {
      throw const ApiFailure('账户服务暂不可用，请稍后重试');
    }
    return r as PasswordRecoveryRepository;
  }

  Future<void> _lookup() async {
    if (_busy || !_form.currentState!.validate()) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
      _token = null;
    });
    try {
      final result = await _repository.lookupRegisteredEmail(_email.text);
      if (!mounted) return;
      setState(() {
        if (!result.found) {
          _error = '这个邮箱还没有 Agenote 账号';
        } else if (result.resetToken == null) {
          _error = '账户服务返回的数据无法读取';
        } else {
          _token = result.resetToken;
          _step = 1;
        }
      });
    } on ApiFailure catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) setState(() => _error = '网络连接不稳定，暂时无法查询账号。请稍后重试。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _reset() async {
    if (_busy || _token == null || !_form.currentState!.validate()) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _repository.resetDemoPassword(_email.text, _token!, _password.text);
      if (!mounted) return;
      _password.clear();
      _confirm.clear();
      _token = null;
      setState(() => _done = true);
    } on ApiFailure catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) setState(() => _error = '重置没有完成，网络连接中断。请重试。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String get _masked {
    final parts = _email.text.trim().split('@');
    if (parts.length != 2) return _email.text;
    final name = parts.first;
    return '${name[0]}***${name.length > 2 ? name[name.length - 1] : ''}@${parts.last}';
  }

  void _login() {
    if (context.canPop()) {
      context.pop(true);
    } else {
      context.go('/login');
    }
  }

  @override
  Widget build(BuildContext context) => AuthAppearance(
    child: Builder(
      builder: (context) {
        final colors = Theme.of(context).colorScheme;
        final meta = _meta[_step];
        return PopScope(
          canPop: _step == 0 && !_busy,
          onPopInvokedWithResult: (didPop, result) {
            if (!didPop) _back();
          },
          child: Scaffold(
            body: SafeArea(
              child: LayoutBuilder(
                builder: (context, box) {
                  final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
                  return SingleChildScrollView(
                    key: const ValueKey('recovery-scroll'),
                    keyboardDismissBehavior:
                        ScrollViewKeyboardDismissBehavior.onDrag,
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        minHeight: math.max(box.maxHeight, 550 * scale),
                      ),
                      child: IntrinsicHeight(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
                          child: Column(
                            children: [
                              Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  IconButton(
                                    onPressed: _busy ? null : _back,
                                    tooltip: _step == 0 ? '返回登录' : '返回上一步',
                                    icon: const Icon(
                                      Icons.arrow_back_ios_new_rounded,
                                      size: 18,
                                    ),
                                  ),
                                  Text(
                                    '03 / 找回密码',
                                    style: BrandTypography.text(
                                      11,
                                      color: colors.onSurfaceVariant,
                                      spacing: 1.4,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 12),
                              const BrandMark(size: 30),
                              const SizedBox(height: 16),
                              Text(
                                _done ? '密码已重置。' : meta.$1,
                                textAlign: TextAlign.center,
                                style: BrandTypography.text(
                                  24,
                                  color: colors.onSurface,
                                  weight: FontWeight.w500,
                                  height: 1.28,
                                ),
                              ),
                              const SizedBox(height: 8),
                              ConstrainedBox(
                                constraints: const BoxConstraints(
                                  maxWidth: 280,
                                ),
                                child: Text(
                                  _done ? '请用新密码重新登录 Agenote。' : meta.$2,
                                  textAlign: TextAlign.center,
                                  style: BrandTypography.text(
                                    13,
                                    color: colors.onSurfaceVariant,
                                    height: 1.65,
                                  ),
                                ),
                              ),
                              const SizedBox(height: 16),
                              Container(
                                width: 40,
                                height: 1,
                                color: colors.primary.withValues(alpha: .35),
                              ),
                              const Spacer(),
                              const SizedBox(height: 28),
                              AuthFormSurface(
                                child: Padding(
                                  padding: const EdgeInsets.all(20),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                      if (!_done) ...[
                                        Semantics(
                                          label: '找回密码，第 ${_step + 1} 步，共三步',
                                          child: Row(
                                            children: [
                                              for (var i = 0; i < 3; i++)
                                                Expanded(
                                                  child: Container(
                                                    height: 3,
                                                    margin:
                                                        const EdgeInsets.only(
                                                          right: 6,
                                                        ),
                                                    decoration: BoxDecoration(
                                                      color: i <= _step
                                                          ? colors.primary
                                                          : colors.onSurface
                                                                .withValues(
                                                                  alpha: .1,
                                                                ),
                                                      borderRadius:
                                                          BorderRadius.circular(
                                                            9,
                                                          ),
                                                    ),
                                                  ),
                                                ),
                                            ],
                                          ),
                                        ),
                                        const SizedBox(height: 20),
                                      ],
                                      if (_done) ...[
                                        Icon(
                                          Icons.check_circle_rounded,
                                          size: 48,
                                          color: colors.primary,
                                        ),
                                        const SizedBox(height: 16),
                                        Text(
                                          '新密码已保存',
                                          textAlign: TextAlign.center,
                                          style: TextStyle(
                                            color: colors.onSurface,
                                            fontSize: 16,
                                          ),
                                        ),
                                        const SizedBox(height: 24),
                                        _primary('返回登录', _login),
                                      ] else if (_step == 1) ...[
                                        Container(
                                          padding: const EdgeInsets.all(14),
                                          decoration: BoxDecoration(
                                            color: colors.primary.withValues(
                                              alpha: .06,
                                            ),
                                            borderRadius: BorderRadius.circular(
                                              16,
                                            ),
                                            border: Border.all(
                                              color: colors.primary.withValues(
                                                alpha: .15,
                                              ),
                                            ),
                                          ),
                                          child: Row(
                                            children: [
                                              CircleAvatar(
                                                backgroundColor: colors.primary,
                                                foregroundColor: Colors.white,
                                                child: Text(
                                                  _email.text
                                                      .trim()[0]
                                                      .toUpperCase(),
                                                ),
                                              ),
                                              const SizedBox(width: 12),
                                              Expanded(
                                                child: Column(
                                                  crossAxisAlignment:
                                                      CrossAxisAlignment.start,
                                                  children: [
                                                    Text(
                                                      _masked,
                                                      style: TextStyle(
                                                        fontSize: 14,
                                                        color: colors.onSurface,
                                                      ),
                                                    ),
                                                    const SizedBox(height: 4),
                                                    Text(
                                                      '这个账号可以重置密码',
                                                      style: TextStyle(
                                                        fontSize: 12,
                                                        color: colors.primary,
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                        const SizedBox(height: 24),
                                        _primary(
                                          '重置密码',
                                          () => setState(() => _step = 2),
                                        ),
                                        TextButton(
                                          onPressed: _back,
                                          child: const Text('不是这个邮箱？重新查找'),
                                        ),
                                      ] else ...[
                                        Form(
                                          key: _form,
                                          child: Column(
                                            children: [
                                              if (_step == 0)
                                                _field(
                                                  context,
                                                  '注册邮箱',
                                                  _email,
                                                  key: 'recovery-email',
                                                  validator: (v) =>
                                                      v == null ||
                                                          !RegExp(
                                                            r'^[^\s@]+@[^\s@]+\.[^\s@]+$',
                                                          ).hasMatch(v.trim())
                                                      ? '请输入有效邮箱'
                                                      : null,
                                                ),
                                              if (_step == 2) ...[
                                                _field(
                                                  context,
                                                  '新密码',
                                                  _password,
                                                  key: 'recovery-password',
                                                  hidden: _hidden,
                                                  toggle: () => setState(
                                                    () => _hidden = !_hidden,
                                                  ),
                                                  validator: (v) =>
                                                      v == null ||
                                                          v.length < 8 ||
                                                          v.length > 128
                                                      ? '密码长度为8至128位'
                                                      : !RegExp(
                                                          r'[0-9]',
                                                        ).hasMatch(v)
                                                      ? '密码需要包含至少1个数字'
                                                      : null,
                                                ),
                                                const SizedBox(height: 16),
                                                _field(
                                                  context,
                                                  '确认新密码',
                                                  _confirm,
                                                  key: 'recovery-confirmation',
                                                  hidden: _hiddenConfirmation,
                                                  toggle: () => setState(
                                                    () => _hiddenConfirmation =
                                                        !_hiddenConfirmation,
                                                  ),
                                                  validator: (v) =>
                                                      v != _password.text
                                                      ? '两次输入的密码不一致'
                                                      : null,
                                                ),
                                              ],
                                            ],
                                          ),
                                        ),
                                        if (_error != null)
                                          Padding(
                                            padding: const EdgeInsets.only(
                                              top: 12,
                                            ),
                                            child: Semantics(
                                              liveRegion: true,
                                              child: Text(
                                                _error!,
                                                key: const ValueKey(
                                                  'recovery-error',
                                                ),
                                                style: TextStyle(
                                                  fontSize: 12,
                                                  height: 1.6,
                                                  color: colors.error,
                                                ),
                                              ),
                                            ),
                                          ),
                                        const SizedBox(height: 20),
                                        _primary(
                                          _busy
                                              ? (_step == 0
                                                    ? '正在查询账号…'
                                                    : '正在重置…')
                                              : _step == 0
                                              ? '查找账号'
                                              : '保存新密码',
                                          _step == 0 ? _lookup : _reset,
                                        ),
                                        if (_step == 0)
                                          TextButton(
                                            onPressed: _busy
                                                ? null
                                                : () => context.go('/register'),
                                            child: const Text('还没有账号？创建一个'),
                                          ),
                                      ],
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        );
      },
    ),
  );
  Widget _primary(String label, VoidCallback action) => AuthButtonSurface(
    disabled: _busy,
    child: FilledButton(
      key: const ValueKey('recovery-submit'),
      onPressed: _busy ? null : action,
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(54),
        shape: const StadiumBorder(),
        backgroundColor: Colors.transparent,
        disabledBackgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
      ),
      child: Text(label),
    ),
  );
  Widget _field(
    BuildContext context,
    String label,
    TextEditingController controller, {
    required String key,
    required FormFieldValidator<String> validator,
    bool? hidden,
    VoidCallback? toggle,
  }) {
    final colors = Theme.of(context).colorScheme;
    return TextFormField(
      key: ValueKey(key),
      controller: controller,
      enabled: !_busy,
      validator: validator,
      obscureText: hidden ?? false,
      keyboardType: hidden == null
          ? TextInputType.emailAddress
          : TextInputType.visiblePassword,
      autofillHints: hidden == null
          ? const [AutofillHints.email]
          : const [AutofillHints.newPassword],
      autocorrect: false,
      textInputAction: hidden == null
          ? TextInputAction.done
          : TextInputAction.next,
      onFieldSubmitted: hidden == null ? (_) => _lookup() : null,
      decoration: InputDecoration(
        labelText: label,
        floatingLabelBehavior: FloatingLabelBehavior.always,
        filled: true,
        fillColor: colors.surface,
        errorMaxLines: 3,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 16,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: colors.outlineVariant),
        ),
        suffixIcon: toggle == null
            ? null
            : IconButton(
                onPressed: _busy ? null : toggle,
                tooltip: hidden == true ? '显示密码' : '隐藏密码',
                icon: Icon(
                  hidden == true
                      ? Icons.visibility_off_outlined
                      : Icons.visibility_outlined,
                  size: 19,
                ),
              ),
      ),
    );
  }
}
