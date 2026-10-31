import 'package:flutter/material.dart';
import '../home/views/home_style.dart';

/// Returns consent only. The caller performs the authenticated unbind request.
Future<bool?> showWechatUnbindSheet(BuildContext context, String identity) =>
    showModalBottomSheet<bool>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => WechatUnbindSheet(identity: identity),
    );

class WechatUnbindSheet extends StatelessWidget {
  const WechatUnbindSheet({super.key, required this.identity});
  final String identity;
  static const danger = Color(0xFFD52832);

  @override
  Widget build(BuildContext context) {
    final muted = HomeStyle.secondary(context);
    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * .85,
      ),
      decoration: BoxDecoration(
        color: HomeStyle.canvas(context).withValues(alpha: .98),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      ),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 32,
                  height: 4,
                  decoration: BoxDecoration(
                    color: muted.withValues(alpha: .25),
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '解除微信绑定？',
                      style: HomeStyle.text(
                        16,
                        bold: true,
                        color: HomeStyle.foreground(context),
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭',
                    onPressed: () => Navigator.pop(context, false),
                    style: IconButton.styleFrom(
                      backgroundColor: HomeStyle.tint(context),
                      foregroundColor: muted,
                      minimumSize: const Size(44, 44),
                    ),
                    icon: const Icon(Icons.close, size: 18),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: HomeStyle.tint(context),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      identity,
                      style: HomeStyle.text(
                        11,
                        color: HomeStyle.foreground(context),
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      '解除后这条微信身份与账号的关联会立即失效。',
                      style: HomeStyle.text(
                        10,
                        color: muted,
                      ).copyWith(height: 1.6),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              for (final note in const [
                '已推送的消息会留在微信聊天里，不会被撤回',
                '知识库、会议纪要与 AI 成果照常保留',
                '之后重新绑定会换一个新的绑定码',
              ])
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        Icons.check,
                        size: 14,
                        color: muted.withValues(alpha: .7),
                      ),
                      const SizedBox(width: 7),
                      Expanded(
                        child: Text(
                          note,
                          style: HomeStyle.text(
                            10.5,
                            color: muted,
                          ).copyWith(height: 1.6),
                        ),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: 10),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                style: FilledButton.styleFrom(
                  backgroundColor: danger,
                  foregroundColor: Colors.white,
                  minimumSize: const Size.fromHeight(44),
                  shape: const StadiumBorder(),
                ),
                child: const Text(
                  '确认解除绑定',
                  style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
                ),
              ),
              const SizedBox(height: 6),
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                style: TextButton.styleFrom(
                  foregroundColor: muted,
                  minimumSize: const Size.fromHeight(44),
                ),
                child: const Text('继续用微信接收', style: TextStyle(fontSize: 12)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
