import 'dart:async';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../auth/views/auth_brand_widgets.dart';
import '../first_run/brand_tokens.dart';
import '../profile/viewmodels/profile_view_model.dart';
import 'personalization_controller.dart';

const professionChoices = <String, String>{
  'software': '软件开发',
  'design': '产品设计',
  'project': '项目管理',
  'marketing': '市场运营',
  'education': '教育',
  'finance': '财务',
  'other': '其他 / 自定义',
};
const scenarioChoices = <String, (String, String, IconData)>{
  'work': ('工作会议', '记录会议重点与后续行动。', Icons.groups_outlined),
  'project': ('项目讨论', '整理决策、进度与待确认事项。', Icons.account_tree_outlined),
  'technical': ('技术交流', '理解专业术语与复杂讨论。', Icons.code_rounded),
  'customer': ('客户沟通', '梳理客户需求与沟通事项。', Icons.chat_bubble_outline_rounded),
  'learning': ('学习培训', '回顾知识点与重要内容。', Icons.school_outlined),
  'brainstorm': ('头脑风暴', '捕捉想法并梳理思路。', Icons.lightbulb_outline_rounded),
  'other': ('其他', '填写自己的使用场景。', Icons.more_horiz_rounded),
};

class PersonalizationPage extends StatefulWidget {
  const PersonalizationPage({
    super.key,
    this.drafts = const SecurePersonalizationDrafts(),
  });
  final PersonalizationDraftStore drafts;
  @override
  State<PersonalizationPage> createState() => _PersonalizationPageState();
}

class _PersonalizationPageState extends State<PersonalizationPage> {
  late final PersonalizationController c;
  double _dragStart = 999, _dragDistance = 0;
  late final TextEditingController _name, _profession, _scenario;
  final _nicknameFocus = FocusNode();
  @override
  void initState() {
    super.initState();
    c = PersonalizationController(
      context.read<ProfileViewModel>(),
      store: widget.drafts,
    );
    _name = TextEditingController(text: c.name);
    _profession = TextEditingController(text: c.professionOther);
    _scenario = TextEditingController(text: c.scenarioOther);
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    await c.initialize();
    if (!mounted) return;
    _name.text = c.name;
    _profession.text = c.professionOther;
    _scenario.text = c.scenarioOther;
    setState(() {});
  }

  @override
  void dispose() {
    _nicknameFocus.dispose();
    c.dispose();
    _name.dispose();
    _profession.dispose();
    _scenario.dispose();
    super.dispose();
  }

  Future<void> _submit(String action) async {
    FocusScope.of(context).unfocus();
    final ok = await c.submit(action);
    if (ok && mounted && action != 'continue') context.go('/home');
  }

  Future<void> _back() async {
    if (c.busy) return;
    if (c.step == 2) {
      c.back();
      return;
    }
    final leave = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog.adaptive(
        title: const Text('稍后再设置？'),
        content: const Text('已填写的信息会保留，你可以先进入 Agenote。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('继续填写'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('稍后设置'),
          ),
        ],
      ),
    );
    if (leave == true && mounted) await _submit('skip');
  }

  @override
  Widget build(BuildContext context) => AuthAppearance(
    child: Builder(
      builder: (ctx) {
        final colors = Theme.of(ctx).colorScheme;
        final reduced = BrandMotion.reduced(ctx);
        final duration = reduced ? Duration.zero : BrandMotion.page;
        final ios = Theme.of(ctx).platform == TargetPlatform.iOS;
        return GestureDetector(
          onHorizontalDragStart: ios
              ? (details) {
                  _dragStart = details.localPosition.dx;
                  _dragDistance = 0;
                }
              : null,
          onHorizontalDragUpdate: ios
              ? (details) {
                  _dragDistance += details.delta.dx;
                }
              : null,
          onHorizontalDragEnd: ios
              ? (_) {
                  if (_dragStart <= 24 && _dragDistance > 72) {
                    unawaited(_back());
                  }
                }
              : null,
          child: AnimatedBuilder(
            animation: c,
            builder: (_, _) => PopScope(
              canPop: false,
              onPopInvokedWithResult: (didPop, _) {
                if (!didPop) unawaited(_back());
              },
              child: Scaffold(
                backgroundColor: Colors.transparent,
                resizeToAvoidBottomInset: true,
                body: SafeArea(
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 520),
                      child: c.loading
                          ? const Center(child: CircularProgressIndicator())
                          : Column(
                              children: [
                                Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    12,
                                    8,
                                    28,
                                    0,
                                  ),
                                  child: Row(
                                    children: [
                                      IconButton(
                                        tooltip: '返回',
                                        onPressed: c.busy ? null : _back,
                                        icon: const Icon(
                                          Icons.arrow_back_ios_new_rounded,
                                          size: 19,
                                        ),
                                      ),
                                      const Spacer(),
                                      Text(
                                        '0${c.step} / 02',
                                        style: TextStyle(
                                          color: colors.onSurfaceVariant,
                                          fontSize: 12,
                                          letterSpacing: 2,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    28,
                                    14,
                                    28,
                                    0,
                                  ),
                                  child: Row(
                                    children: List.generate(
                                      2,
                                      (i) => Expanded(
                                        child: AnimatedContainer(
                                          duration: duration,
                                          height: 3,
                                          margin: EdgeInsets.only(
                                            right: i == 0 ? 6 : 0,
                                          ),
                                          decoration: BoxDecoration(
                                            color: i < c.step
                                                ? colors.primary
                                                : colors.primary.withValues(
                                                    alpha: .12,
                                                  ),
                                            borderRadius: BorderRadius.circular(
                                              9,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                                Expanded(
                                  child: SingleChildScrollView(
                                    key: const ValueKey(
                                      'personalization-scroll',
                                    ),
                                    padding: const EdgeInsets.fromLTRB(
                                      28,
                                      26,
                                      28,
                                      20,
                                    ),
                                    child: AnimatedSwitcher(
                                      duration: duration,
                                      switchInCurve: BrandMotion.curve,
                                      transitionBuilder: (child, a) =>
                                          FadeTransition(
                                            opacity: a,
                                            child: SlideTransition(
                                              position: Tween(
                                                begin: const Offset(.025, 0),
                                                end: Offset.zero,
                                              ).animate(a),
                                              child: child,
                                            ),
                                          ),
                                      child: c.step == 1
                                          ? _stepOne(ctx)
                                          : _stepTwo(ctx),
                                    ),
                                  ),
                                ),
                                Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    28,
                                    4,
                                    28,
                                    8,
                                  ),
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      if (c.error != null)
                                        Padding(
                                          padding: const EdgeInsets.only(
                                            bottom: 10,
                                          ),
                                          child: Semantics(
                                            liveRegion: true,
                                            child: Row(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                Expanded(
                                                  child: Text(
                                                    c.error!,
                                                    style: TextStyle(
                                                      color: colors.error,
                                                      fontSize: 13,
                                                    ),
                                                  ),
                                                ),
                                                TextButton(
                                                  onPressed: c.busy
                                                      ? null
                                                      : () => _submit(
                                                          c.step == 1
                                                              ? 'continue'
                                                              : 'complete',
                                                        ),
                                                  child: const Text('重试'),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),
                                      AuthButtonSurface(
                                        disabled: c.busy,
                                        child: SizedBox(
                                          width: double.infinity,
                                          height: 54,
                                          child: TextButton(
                                            onPressed: c.busy
                                                ? null
                                                : () => _submit(
                                                    c.step == 1
                                                        ? 'continue'
                                                        : 'complete',
                                                  ),
                                            style: TextButton.styleFrom(
                                              foregroundColor: Colors.white,
                                              disabledForegroundColor:
                                                  Colors.white70,
                                            ),
                                            child: c.busy
                                                ? const SizedBox(
                                                    width: 20,
                                                    height: 20,
                                                    child:
                                                        CircularProgressIndicator(
                                                          strokeWidth: 2,
                                                          color: Colors.white,
                                                        ),
                                                  )
                                                : Text(
                                                    c.step == 1
                                                        ? '继续'
                                                        : '开启 Agenote',
                                                    style: const TextStyle(
                                                      fontSize: 16,
                                                      fontWeight:
                                                          FontWeight.w500,
                                                    ),
                                                  ),
                                          ),
                                        ),
                                      ),
                                      TextButton(
                                        onPressed: c.busy
                                            ? null
                                            : () => _submit('skip'),
                                        child: Text(
                                          c.step == 1 ? '稍后设置' : '跳过',
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
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
  Widget _input(
    BuildContext ctx,
    TextEditingController controller,
    String hint,
    int max,
    ValueChanged<String> changed, {
    String? label,
  }) {
    final colors = Theme.of(ctx).colorScheme;
    return TextField(
      controller: controller,
      enabled: !c.busy,
      maxLength: max,
      textInputAction: TextInputAction.done,
      onChanged: changed,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        filled: true,
        fillColor: colors.surface.withValues(alpha: .85),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 16,
        ),
        counterText: '',
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: colors.primary.withValues(alpha: .12)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: colors.primary.withValues(alpha: .12)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: colors.primary, width: 1.5),
        ),
      ),
    );
  }

  Widget _stepOne(BuildContext ctx) {
    final colors = Theme.of(ctx).colorScheme;
    return Column(
      key: const ValueKey('personalization-step-1'),
      children: [
        const SizedBox(height: 8),
        Image.asset(
          BrandAssets.logo,
          width: 26,
          height: 26,
          excludeFromSemantics: true,
        ),
        const SizedBox(height: 20),
        Text(
          '先简单认识一下你。',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 22,
            height: 1.45,
            fontWeight: FontWeight.w500,
            color: colors.onSurface,
          ),
        ),
        const SizedBox(height: 12),
        Text(
          '让 Agenote 以更适合你的方式与你交流。',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 12,
            height: 1.65,
            color: colors.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 26),
        AuthFormSurface(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AnimatedBuilder(
                  animation: _nicknameFocus,
                  builder: (_, _) => AnimatedContainer(
                    duration: BrandMotion.reduced(ctx)
                        ? Duration.zero
                        : const Duration(milliseconds: 180),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                    decoration: BoxDecoration(
                      color: colors.surface.withValues(alpha: .75),
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(
                        color: colors.primary.withValues(
                          alpha: _nicknameFocus.hasFocus ? .7 : .15,
                        ),
                        width: _nicknameFocus.hasFocus ? 1.5 : 1,
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '昵称（可选）',
                          style: TextStyle(
                            fontSize: 11,
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                        TextField(
                          controller: _name,
                          focusNode: _nicknameFocus,
                          enabled: !c.busy,
                          maxLength: 40,
                          textInputAction: TextInputAction.done,
                          style: const TextStyle(fontSize: 14),
                          onChanged: (v) {
                            c.name = v;
                            c.changed();
                          },
                          decoration: InputDecoration(
                            hintText: '怎么称呼你？',
                            hintStyle: TextStyle(
                              color: colors.onSurfaceVariant.withValues(
                                alpha: .6,
                              ),
                            ),
                            isDense: true,
                            counterText: '',
                            contentPadding: const EdgeInsets.only(
                              top: 7,
                              bottom: 1,
                            ),
                            border: InputBorder.none,
                            enabledBorder: InputBorder.none,
                            focusedBorder: InputBorder.none,
                            disabledBorder: InputBorder.none,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '已填入当前用户名，可随时修改并同步账户。',
                  style: TextStyle(
                    fontSize: 10.5,
                    height: 1.6,
                    color: colors.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 20),
                Text(
                  '专业背景（可选）',
                  style: TextStyle(
                    fontSize: 11,
                    color: colors.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 2,
                  children: professionChoices.entries.map((e) {
                    final selected = c.profession == e.key;
                    return Semantics(
                      button: true,
                      selected: selected,
                      label: e.value,
                      child: Material(
                        color: Colors.transparent,
                        child: InkWell(
                          borderRadius: BorderRadius.circular(99),
                          onTap: c.busy
                              ? null
                              : () {
                                  c.profession = selected ? '' : e.key;
                                  c.changed();
                                },
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(minHeight: 44),
                            child: Center(
                              widthFactor: 1,
                              heightFactor: 1,
                              child: AnimatedContainer(
                                duration: BrandMotion.reduced(ctx)
                                    ? Duration.zero
                                    : const Duration(milliseconds: 180),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 7,
                                ),
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(99),
                                  color: selected
                                      ? colors.primary.withValues(alpha: .1)
                                      : colors.surface.withValues(alpha: .7),
                                  border: Border.all(
                                    color: colors.primary.withValues(
                                      alpha: selected ? .5 : .12,
                                    ),
                                  ),
                                ),
                                child: Text(
                                  e.value,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: selected
                                        ? colors.primary
                                        : colors.onSurfaceVariant,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                ),
                if (c.profession == 'other') ...[
                  const SizedBox(height: 10),
                  _input(ctx, _profession, '填写你的专业领域', 80, (v) {
                    c.professionOther = v;
                    c.changed();
                  }),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _stepTwo(BuildContext ctx) {
    final colors = Theme.of(ctx).colorScheme;
    return Column(
      key: const ValueKey('personalization-step-2'),
      children: [
        const SizedBox(height: 8),
        Image.asset(
          BrandAssets.logo,
          width: 26,
          height: 26,
          excludeFromSemantics: true,
        ),
        const SizedBox(height: 20),
        Text(
          '你希望 Agenote 在哪些时刻帮助你？',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 22,
            height: 1.45,
            fontWeight: FontWeight.w500,
            color: colors.onSurface,
          ),
        ),
        const SizedBox(height: 12),
        Text(
          '选择常见的使用场景，让会议内容更贴近你的需求。',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 12,
            height: 1.65,
            color: colors.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 26),
        AuthFormSurface(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 6,
                  runSpacing: 2,
                  children: scenarioChoices.entries.map((e) {
                    final selected = c.scenarios.contains(e.key);
                    return Semantics(
                      button: true,
                      selected: selected,
                      label: e.value.$1,
                      child: Tooltip(
                        message: e.value.$2,
                        child: Material(
                          color: Colors.transparent,
                          child: InkWell(
                            borderRadius: BorderRadius.circular(99),
                            onTap: c.busy
                                ? null
                                : () {
                                    selected
                                        ? c.scenarios.remove(e.key)
                                        : c.scenarios.add(e.key);
                                    c.changed();
                                  },
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(minHeight: 44),
                              child: Center(
                                widthFactor: 1,
                                heightFactor: 1,
                                child: AnimatedContainer(
                                  duration: BrandMotion.reduced(ctx)
                                      ? Duration.zero
                                      : const Duration(milliseconds: 180),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 7,
                                  ),
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(99),
                                    color: selected
                                        ? colors.primary.withValues(alpha: .1)
                                        : colors.surface.withValues(alpha: .7),
                                    border: Border.all(
                                      color: colors.primary.withValues(
                                        alpha: selected ? .5 : .12,
                                      ),
                                    ),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        e.value.$3,
                                        size: 13,
                                        color: selected
                                            ? colors.primary
                                            : colors.onSurfaceVariant,
                                      ),
                                      const SizedBox(width: 5),
                                      Text(
                                        e.value.$1,
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: selected
                                              ? colors.primary
                                              : colors.onSurfaceVariant,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                ),
                if (c.scenarios.contains('other')) ...[
                  const SizedBox(height: 10),
                  _input(ctx, _scenario, '填写自己的使用场景', 120, (v) {
                    c.scenarioOther = v;
                    c.changed();
                  }),
                ],
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Divider(
                    height: 1,
                    color: colors.primary.withValues(alpha: .1),
                  ),
                ),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.info_outline_rounded,
                      size: 14,
                      color: colors.onSurfaceVariant,
                    ),
                    const SizedBox(width: 7),
                    Expanded(
                      child: Text(
                        '可多选、可随时取消。不选也可以继续，之后仍可补充。',
                        style: TextStyle(
                          fontSize: 11,
                          height: 1.6,
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
