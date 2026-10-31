import 'wechat_panel.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:go_router/go_router.dart';
import '../../shared/widgets/content_skeleton.dart';
import '../profile/viewmodels/profile_view_model.dart';
import 'assistant_model.dart';

class WorkAssistantPage extends StatelessWidget {
  const WorkAssistantPage({super.key});
  @override
  Widget build(BuildContext context) {
    final profile = context.watch<ProfileViewModel>();
    final client = profile.repository.client;
    if (client == null || !profile.data.sessionActive) {
      return Scaffold(
        appBar: AppBar(title: const Text('微信助手')),
        body: const Center(child: Text('请登录云端账号后使用微信助手')),
      );
    }
    return ChangeNotifierProvider(
      key: ValueKey(profile.data.accountId),
      create: (_) {
        final model = AssistantModel(
          client,
          profile.data.accountId,
          onBound: profile.load,
        );
        model.load().then((_) {
          if (model.current &&
              model.channel['canBind'] == true &&
              [
                'unbound',
                'expired',
                'reauth_required',
                'failed',
              ].contains(model.channel['bindingStatus'])) {
            model.createQr();
          }
        });
        return model;
      },
      child: const _AssistantBody(),
    );
  }
}

class _AssistantBody extends StatelessWidget {
  const _AssistantBody();
  @override
  Widget build(BuildContext context) {
    final vm = context.watch<AssistantModel>();
    final colors = Theme.of(context).colorScheme;
    final bound = vm.channel['bindingStatus'] == 'bound';
    final paused = (vm.channel['preferences'] as Map?)?['paused'] == true;
    final status = bound
        ? (paused ? '推送已暂停' : '已连接')
        : ['pending', 'scanned'].contains(vm.channel['bindingStatus'])
        ? '等待绑定'
        : '未绑定';
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 600),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            width: 34,
                            height: 34,
                            decoration: BoxDecoration(
                              color: colors.surface,
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: colors.primary.withValues(alpha: .1),
                              ),
                            ),
                            child: BackButton(
                              style: IconButton.styleFrom(
                                padding: EdgeInsets.zero,
                                iconSize: 19,
                              ),
                              onPressed: () {
                                if (context.canPop()) {
                                  context.pop();
                                } else {
                                  context.go('/profile');
                                }
                              },
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '微信助手',
                                  style: TextStyle(
                                    fontSize: 10,
                                    height: 1.1,
                                    letterSpacing: 1.5,
                                    color: colors.onSurfaceVariant,
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  bound ? 'Hermes 在微信里等你' : '绑定微信，接收 AI 成果',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 20,
                                    height: 1.2,
                                    fontWeight: FontWeight.w500,
                                    letterSpacing: -.6,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 7,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: colors.primary.withValues(alpha: .04),
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(
                                color: colors.primary.withValues(alpha: .13),
                              ),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  bound
                                      ? (paused
                                            ? Icons.pause_circle_outline
                                            : Icons.check_circle)
                                      : Icons.link_off,
                                  size: 10,
                                  color: colors.primary,
                                ),
                                const SizedBox(width: 3),
                                Text(
                                  status,
                                  style: TextStyle(
                                    fontSize: 9,
                                    color: colors.primary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 7),
                      Text(
                        bound
                            ? '推送只发摘要与结论，完整报告仍然回到 Agenote 里看。'
                            : '一次绑定，之后每场有价值的分析都能直接推到微信。',
                        style: TextStyle(
                          fontSize: 11,
                          height: 1.55,
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: vm.loading
                      ? const ContentSkeleton(
                          layout: SkeletonLayout.detail,
                          label: '正在核对微信助手状态',
                        )
                      : RefreshIndicator(
                          onRefresh: vm.load,
                          child: ListView(
                            physics: const AlwaysScrollableScrollPhysics(),
                            padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
                            children: [
                              if (!bound) ...[
                                _Surface(
                                  child: Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Container(
                                        width: 42,
                                        height: 42,
                                        decoration: BoxDecoration(
                                          color: colors.primary,
                                          borderRadius: BorderRadius.circular(
                                            14,
                                          ),
                                        ),
                                        child: const Icon(
                                          Icons.forum_outlined,
                                          color: Colors.white,
                                          size: 21,
                                        ),
                                      ),
                                      const SizedBox(width: 12),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              '微信助手',
                                              style: TextStyle(
                                                fontSize: 10,
                                                letterSpacing: 1,
                                                color: colors.onSurfaceVariant,
                                              ),
                                            ),
                                            const SizedBox(height: 4),
                                            const Text(
                                              '让 Hermes 在微信里找到你',
                                              style: TextStyle(
                                                fontSize: 18,
                                                height: 1.35,
                                                fontWeight: FontWeight.w500,
                                                letterSpacing: -.3,
                                              ),
                                            ),
                                            const SizedBox(height: 6),
                                            Text(
                                              '绑定一次就行。会后有价值的分析成果会推到微信，摘要之外的部分仍然留在 Agenote。',
                                              style: TextStyle(
                                                fontSize: 10.5,
                                                height: 1.6,
                                                color: colors.onSurfaceVariant,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(height: 16),
                                for (final item in [
                                  (
                                    Icons.auto_awesome_outlined,
                                    '会后自动收到分析成果',
                                    '会议纪要生成后，Hermes 会先判断这场会有没有值得深挖的问题',
                                  ),
                                  (
                                    Icons.chat_bubble_outline,
                                    '直接在微信里追问',
                                    '收到摘要后可以接着问，不用再打开 App。',
                                  ),
                                  (
                                    Icons.north_west,
                                    '报告入口回 Agenote',
                                    '微信里只推摘要，完整报告、数据来源与原始会议都留在 Agenote。',
                                  ),
                                ]) ...[
                                  _Surface(
                                    radius: 16,
                                    padding: 14,
                                    child: Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Container(
                                          width: 26,
                                          height: 26,
                                          decoration: BoxDecoration(
                                            color: colors.onSurfaceVariant
                                                .withValues(alpha: .06),
                                            borderRadius: BorderRadius.circular(
                                              8,
                                            ),
                                          ),
                                          child: Icon(
                                            item.$1,
                                            size: 14,
                                            color: colors.onSurfaceVariant,
                                          ),
                                        ),
                                        const SizedBox(width: 10),
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                item.$2,
                                                style: const TextStyle(
                                                  fontSize: 11.5,
                                                  height: 1.5,
                                                  fontWeight: FontWeight.w500,
                                                ),
                                              ),
                                              const SizedBox(height: 2),
                                              Text(
                                                item.$3,
                                                style: TextStyle(
                                                  fontSize: 9.5,
                                                  height: 1.6,
                                                  color:
                                                      colors.onSurfaceVariant,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                ],
                                const SizedBox(height: 8),
                              ],
                              const WechatPanel(),
                              if (vm.error != null)
                                Padding(
                                  padding: const EdgeInsets.only(top: 12),
                                  child: Text(
                                    vm.error!,
                                    style: TextStyle(
                                      color: colors.error,
                                      fontSize: 12,
                                    ),
                                  ),
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
    );
  }
}

class _Surface extends StatelessWidget {
  const _Surface({required this.child, this.radius = 22, this.padding = 16});
  final Widget child;
  final double radius, padding;
  @override
  Widget build(BuildContext context) => Material(
    color: Theme.of(context).colorScheme.surfaceContainerLowest,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(radius),
      side: BorderSide(
        color: Theme.of(context).colorScheme.primary.withValues(alpha: .1),
      ),
    ),
    child: Padding(padding: EdgeInsets.all(padding), child: child),
  );
}
