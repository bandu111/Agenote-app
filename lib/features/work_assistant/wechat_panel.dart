import 'wechat_unbind_sheet.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:qr/qr.dart';
import '../profile/viewmodels/profile_view_model.dart';
import 'assistant_model.dart';

String _bindingTime(Object? value) {
  final date = value is String ? DateTime.tryParse(value)?.toLocal() : null;
  if (date == null) return '暂未获取';
  return '${date.month} 月 ${date.day} 日 · ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
}

class WechatPanel extends StatelessWidget {
  const WechatPanel({super.key});
  @override
  Widget build(BuildContext context) {
    final vm = context.watch<AssistantModel>();
    final colors = Theme.of(context).colorScheme;
    final bound = vm.channel['bindingStatus'] == 'bound';
    final rawQr = vm.channel['qr'];
    final qr =
        rawQr is String &&
            ![
              'expired',
              'failed',
              'reauth_required',
            ].contains(vm.channel['bindingStatus']) &&
            _QrPainter._decode(rawQr) != null
        ? rawQr
        : null;
    final prefs = vm.channel['preferences'] as Map? ?? {};
    Widget surface(Widget child, {bool tinted = false}) => Material(
      color: tinted
          ? Color.alphaBlend(
              colors.primary.withValues(alpha: .025),
              colors.surfaceContainerLowest,
            )
          : colors.surfaceContainerLowest,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(22),
        side: BorderSide(color: colors.primary.withValues(alpha: .12)),
      ),
      child: Padding(padding: const EdgeInsets.all(16), child: child),
    );
    if (!bound) {
      return surface(
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  '用微信扫一扫',
                  style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w500),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: colors.onSurfaceVariant.withValues(alpha: .06),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Text(
                    '添加助手',
                    style: TextStyle(
                      fontSize: 9,
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),
            if (qr != null && qr.isNotEmpty)
              Center(
                child: Semantics(
                  key: const ValueKey('wechat-authorization-qr'),
                  label: '微信授权二维码',
                  image: true,
                  child: RepaintBoundary(
                    child: CustomPaint(
                      size: const Size(208, 208),
                      painter: _QrPainter(qr),
                    ),
                  ),
                ),
              )
            else if (vm.saving)
              const SizedBox(
                height: 180,
                child: Center(child: Text('正在获取微信授权二维码…')),
              )
            else
              const SizedBox(
                height: 120,
                child: Center(child: Icon(Icons.qr_code_2, size: 56)),
              ),
            const SizedBox(height: 14),
            Text(
              switch (vm.channel['bindingStatus']) {
                'scanned' => '已扫码，请在微信中确认授权',
                'expired' => '二维码已过期，请刷新后扫码',
                'failed' => '微信连接未完成，请重新扫码',
                'reauth_required' => '微信会话已失效，请重新授权',
                'pending' => '扫码后请在微信中确认，完成后自动进入已连接页面',
                _ =>
                  vm.channel['canBind'] == true
                      ? '每个 Agenote 账号独立授权，不使用管理员二维码'
                      : '微信绑定服务尚未就绪，请稍后重新检查',
              },
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                height: 1.6,
                color: colors.onSurfaceVariant,
              ),
            ),
            if (qr == null ||
                [
                  'expired',
                  'failed',
                  'reauth_required',
                ].contains(vm.channel['bindingStatus']))
              Center(
                child: TextButton(
                  onPressed: vm.saving
                      ? null
                      : vm.channel['canBind'] == true
                      ? vm.createQr
                      : vm.load,
                  child: Text(
                    vm.channel['canBind'] == true ? '重新获取二维码' : '重新检查',
                  ),
                ),
              ),
          ],
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        surface(
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      color: colors.primary,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: const Icon(
                      Icons.forum,
                      color: Colors.white,
                      size: 21,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Flexible(
                              child: Text(
                                '微信助手已连接',
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 3,
                              ),
                              decoration: BoxDecoration(
                                color: colors.primary.withValues(alpha: .06),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Text(
                                '已验证',
                                style: TextStyle(
                                  fontSize: 9,
                                  color: colors.primary,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Text(
                          '与你独立授权的微信连接收发消息，不会代你回复。',
                          style: TextStyle(
                            fontSize: 9.5,
                            height: 1.5,
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: colors.surfaceContainerLowest,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: colors.primary.withValues(alpha: .1),
                  ),
                ),
                child: Column(
                  children: [
                    for (final item in [
                      (
                        '助手名称',
                        vm.channel['assistantName'] as String? ??
                            'Agenote 工作助手',
                      ),
                      ('微信身份', vm.channel['peerLabel'] as String? ?? '已验证'),
                      ('接收账号', context.watch<ProfileViewModel>().data.email),
                      ('绑定时间', _bindingTime(vm.channel['boundAt'])),
                      ('当前设备', '当前手机 · 本机会话'),
                    ])
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 7),
                        child: Row(
                          children: [
                            Text(
                              item.$1,
                              style: TextStyle(
                                fontSize: 11,
                                color: colors.onSurfaceVariant,
                              ),
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Text(
                                item.$2,
                                textAlign: TextAlign.right,
                                style: const TextStyle(fontSize: 10.5),
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
              if (vm.channel['canSend'] != true)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(
                    '请先在微信发送一条消息',
                    style: TextStyle(fontSize: 11, color: colors.primary),
                  ),
                ),
              if ((vm.channel['message'] as String? ?? '').isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(
                    vm.channel['message'] as String,
                    style: TextStyle(fontSize: 12, color: colors.primary),
                  ),
                ),
            ],
          ),
          tinted: true,
        ),
        const SizedBox(height: 18),
        Text(
          '微信助手设置',
          style: TextStyle(
            fontSize: 10,
            letterSpacing: 1,
            color: colors.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 10),
        surface(
          Column(
            children: [
              for (final item in [
                (
                  'autoMeeting',
                  '自动接收会议分析成果',
                  '会议结束后，Hermes 判断值得分析时自动推送',
                  Icons.auto_awesome_outlined,
                ),
                (
                  'importantOnly',
                  '重要工作结果提醒',
                  '只推值得关注的问题和结论',
                  Icons.notification_important_outlined,
                ),
                (
                  'aiDone',
                  'AI 分析完成通知',
                  '分析完成时收到一条简短摘要',
                  Icons.notifications_none,
                ),
                (
                  'paused',
                  '暂停微信推送',
                  '临时安静一段时间；仍可主动追问',
                  Icons.pause_circle_outline,
                ),
              ])
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Row(
                    children: [
                      Container(
                        width: 30,
                        height: 30,
                        decoration: BoxDecoration(
                          color: colors.primary.withValues(alpha: .04),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Icon(item.$4, size: 17, color: colors.primary),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(item.$2, style: const TextStyle(fontSize: 12)),
                            const SizedBox(height: 3),
                            Text(
                              item.$3,
                              style: TextStyle(
                                fontSize: 10,
                                height: 1.5,
                                color: colors.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      Semantics(
                        label: item.$2,
                        child: CupertinoSwitch(
                          activeTrackColor: colors.primary,
                          value:
                              prefs[item.$1] == true &&
                              (item.$1 != 'autoMeeting' ||
                                  (vm.channel['analysisPreferences']
                                          as Map?)?['autoAnalyze'] ==
                                      true),
                          onChanged: vm.saving
                              ? null
                              : (value) => vm.preference(item.$1, value),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        OutlinedButton.icon(
          onPressed: vm.saving
              ? null
              : () async {
                  final identity =
                      [
                            vm.channel['assistantName'] as String? ??
                                'Hermes 助手',
                            vm.channel['peerLabel'] as String?,
                          ]
                          .whereType<String>()
                          .where((v) => v.trim().isNotEmpty)
                          .join(' · ');
                  final accepted = await showWechatUnbindSheet(
                    context,
                    identity,
                  );
                  if (accepted == true &&
                      context.mounted &&
                      vm.current &&
                      !vm.saving) {
                    await vm.unbind();
                  }
                },
          style: OutlinedButton.styleFrom(
            foregroundColor: WechatUnbindSheet.danger,
            backgroundColor: colors.surfaceContainerLowest,
            minimumSize: const Size.fromHeight(46),
            side: BorderSide(color: colors.primary.withValues(alpha: .12)),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
          ),
          icon: const Icon(Icons.link_off_rounded, size: 16),
          label: const Text('解除微信绑定', style: TextStyle(fontSize: 11.5)),
        ),
      ],
    );
  }
}

class _QrPainter extends CustomPainter {
  _QrPainter(String value) : value = value, image = _decode(value);
  final String value;
  final QrImage? image;
  static String? _cachedValue;
  static QrImage? _cachedImage;
  static QrImage? _decode(String value) {
    if (_cachedValue == value) return _cachedImage;
    _cachedValue = value;
    _cachedImage = null;
    if (value.isEmpty || value.length > 2000) return null;
    try {
      return _cachedImage = QrImage(
        QrCode.fromData(data: value, errorCorrectLevel: QrErrorCorrectLevel.M),
      );
    } catch (_) {
      return null;
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.white);
    final image = this.image;
    if (image == null) return;
    final unit = size.shortestSide / (image.moduleCount + 8);
    final ink = Paint()
      ..color = const Color(0xff10162b)
      ..isAntiAlias = false;
    for (var y = 0; y < image.moduleCount; y++) {
      for (var x = 0; x < image.moduleCount; x++) {
        if (image.isDark(y, x)) {
          canvas.drawRect(
            Rect.fromLTWH((x + 4) * unit, (y + 4) * unit, unit, unit),
            ink,
          );
        }
      }
    }
  }

  @override
  bool shouldRepaint(covariant _QrPainter old) => old.value != value;
}
