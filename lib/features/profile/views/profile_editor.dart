import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../app/l10n/app_strings.dart';
import '../services/profile_media.dart';
import '../viewmodels/profile_view_model.dart';
import 'profile_components.dart';

Future<void> showProfileEditor(BuildContext context) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useRootNavigator: true,
      useSafeArea: true,
      showDragHandle: false,
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      clipBehavior: Clip.antiAlias,
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
        child: DraggableScrollableSheet(
          expand: false,
          initialChildSize: .86,
          minChildSize: .55,
          maxChildSize: .96,
          builder: (_, controller) =>
              ProfileEditor(scrollController: controller),
        ),
      ),
    );

class ProfileEditor extends StatefulWidget {
  const ProfileEditor({super.key, this.scrollController});
  final ScrollController? scrollController;
  @override
  State<ProfileEditor> createState() => _ProfileEditorState();
}

class _ProfileEditorState extends State<ProfileEditor> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _name, _job, _company, _email, _phone;
  String? _avatar, _error;
  bool _picking = false;
  @override
  void initState() {
    super.initState();
    final d = context.read<ProfileViewModel>().data;
    _name = TextEditingController(text: d.name);
    _job = TextEditingController(text: d.job);
    _company = TextEditingController(text: d.company);
    _email = TextEditingController(text: d.email);
    _phone = TextEditingController(text: d.phone);
    _avatar = d.avatar;
  }

  @override
  void dispose() {
    for (final c in [_name, _job, _company, _email, _phone]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _pick() async {
    if (_picking) return;
    setState(() => _picking = true);
    try {
      final value = await context.read<ProfileMediaPicker>().chooseAvatar();
      if (mounted && value != null) setState(() => _avatar = value);
    } on FormatException catch (e) {
      if (mounted) profileFeedback(context, e.message);
    } catch (_) {
      if (mounted) profileFeedback(context, '无法读取图片，请选择 PNG、JPEG 或 WebP');
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    final vm = context.read<ProfileViewModel>();
    final ok = await vm.updatePersonal(
      name: _name.text,
      job: _job.text,
      company: _company.text,
      email: _email.text,
      phone: _phone.text,
      avatar: _avatar,
    );
    if (!mounted) return;
    if (ok) {
      Navigator.pop(context);
    } else {
      setState(() => _error = vm.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<ProfileViewModel>();
    final colors = Theme.of(context).colorScheme;
    final busy = vm.saving || _picking;
    return Material(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: SafeArea(
        top: false,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 12, 6),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '编辑资料'.tr(context),
                      style: TextStyle(
                        fontSize: 18,
                        height: 1.4,
                        fontWeight: FontWeight.w600,
                        color: colors.onSurface,
                      ),
                    ),
                  ),
                  IconButton(
                    key: const ValueKey('profile-editor-close'),
                    onPressed: busy ? null : () => Navigator.of(context).pop(),
                    tooltip: '关闭'.tr(context),
                    style: IconButton.styleFrom(
                      backgroundColor: colors.primary.withValues(alpha: .055),
                      minimumSize: const Size(44, 44),
                    ),
                    icon: const Icon(Icons.close_rounded, size: 18),
                  ),
                ],
              ),
            ),
            if (busy) const LinearProgressIndicator(minHeight: 2),
            Expanded(
              child: Form(
                key: _form,
                child: ListView(
                  controller: widget.scrollController,
                  keyboardDismissBehavior:
                      ScrollViewKeyboardDismissBehavior.onDrag,
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 22),
                  children: [
                    _field(
                      context,
                      vm,
                      'name',
                      '昵称',
                      _name,
                      40,
                      TextInputType.name,
                      '怎么称呼你？',
                    ),
                    Padding(
                      padding: const EdgeInsets.only(top: 2, bottom: 8),
                      child: Wrap(
                        crossAxisAlignment: WrapCrossAlignment.center,
                        spacing: 6,
                        children: [
                          if (_avatar != null)
                            ProfileAvatar(data: _avatar, size: 28),
                          Text(
                            '头像可单独编辑。'.tr(context),
                            style: TextStyle(
                              fontSize: 11,
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                          TextButton(
                            key: const ValueKey('profile-avatar-picker'),
                            onPressed: busy ? null : _pick,
                            style: TextButton.styleFrom(
                              minimumSize: const Size(48, 44),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 4,
                              ),
                            ),
                            child: Text(
                              '去选一个 ›'.tr(context),
                              style: const TextStyle(fontSize: 12),
                            ),
                          ),
                          if (_avatar != null)
                            TextButton(
                              onPressed: busy
                                  ? null
                                  : () => setState(() => _avatar = null),
                              child: Text(
                                '移除头像'.tr(context),
                                style: const TextStyle(fontSize: 11),
                              ),
                            ),
                        ],
                      ),
                    ),
                    _field(
                      context,
                      vm,
                      'job',
                      '岗位',
                      _job,
                      80,
                      TextInputType.text,
                      '例如：产品负责人',
                    ),
                    const SizedBox(height: 20),
                    _field(
                      context,
                      vm,
                      'company',
                      '公司或组织',
                      _company,
                      80,
                      TextInputType.text,
                      '例如：公司或团队名称',
                    ),
                    const SizedBox(height: 20),
                    _field(
                      context,
                      vm,
                      'email',
                      '联系邮箱',
                      _email,
                      254,
                      TextInputType.emailAddress,
                      'name@example.com',
                    ),
                    const SizedBox(height: 20),
                    _field(
                      context,
                      vm,
                      'phone',
                      '电话',
                      _phone,
                      32,
                      TextInputType.phone,
                      '选填',
                    ),
                    if (_error != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 16),
                        child: Text(
                          _error!.tr(context),
                          style: TextStyle(color: colors.error),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 14),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  key: const ValueKey('profile-save'),
                  onPressed: busy ? null : _save,
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(48, 48),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  child: Text((vm.saving ? '正在保存' : '保存').tr(context)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _field(
    BuildContext context,
    ProfileViewModel vm,
    String id,
    String label,
    TextEditingController controller,
    int maxLength,
    TextInputType keyboard,
    String hint,
  ) {
    final colors = Theme.of(context).colorScheme;
    final border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: BorderSide(color: colors.primary.withValues(alpha: .14)),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label.tr(context),
          style: TextStyle(
            fontSize: 12,
            height: 1.5,
            color: colors.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 6),
        TextFormField(
          key: ValueKey('profile-field-$id'),
          controller: controller,
          enabled: !vm.saving && !_picking,
          maxLength: maxLength,
          keyboardType: keyboard,
          textInputAction: id == 'phone'
              ? TextInputAction.done
              : TextInputAction.next,
          style: TextStyle(fontSize: 14, height: 1.5, color: colors.onSurface),
          decoration: InputDecoration(
            hintText: hint.tr(context),
            hintStyle: TextStyle(
              fontSize: 13,
              color: colors.onSurfaceVariant.withValues(alpha: .7),
            ),
            counterText: '',
            filled: true,
            fillColor: colors.surfaceContainerLowest,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 13,
              vertical: 12,
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
            errorMaxLines: 3,
          ),
          validator: (value) {
            if (id == 'name' && (value == null || value.trim().isEmpty)) {
              return '请输入昵称'.tr(context);
            }
            if (id == 'email' &&
                value!.trim().isNotEmpty &&
                !RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(value.trim())) {
              return '请输入有效邮箱'.tr(context);
            }
            return null;
          },
        ),
      ],
    );
  }
}
