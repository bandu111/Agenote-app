import 'package:flutter/material.dart';
import '../../home/views/home_style.dart';

Future<bool> showGoalRemovalSheet(BuildContext context, String title) async =>
    await showModalBottomSheet<bool>(
      context: context,
      useRootNavigator: true,
      useSafeArea: true,
      isScrollControlled: true,
      barrierColor: const Color(0xFF101937).withValues(alpha: .30),
      backgroundColor: HomeStyle.canvas(context),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (sheet) => SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 10, 24, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 38,
                  height: 4,
                  decoration: BoxDecoration(
                    color: HomeStyle.secondary(sheet).withValues(alpha: .22),
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '移除这个目标？',
                      style: HomeStyle.text(
                        17,
                        bold: true,
                        color: HomeStyle.foreground(sheet),
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭',
                    onPressed: () => Navigator.pop(sheet, false),
                    style: IconButton.styleFrom(
                      backgroundColor: HomeStyle.blue.withValues(alpha: .05),
                    ),
                    icon: const Icon(Icons.close_rounded, size: 18),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 11,
                ),
                decoration: BoxDecoration(
                  color: HomeStyle.tint(sheet),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  title,
                  style: HomeStyle.text(13, color: HomeStyle.foreground(sheet)),
                ),
              ),
              const SizedBox(height: 14),
              Text(
                '移除后不再出现在目标列表与本周统计里。对应的承诺、依据和会议原话仍保留在记录中。',
                style: HomeStyle.text(
                  12,
                  color: HomeStyle.secondary(sheet),
                ).copyWith(height: 1.65),
              ),
              const SizedBox(height: 20),
              FilledButton(
                key: const ValueKey('remove-goal-submit'),
                onPressed: () => Navigator.pop(sheet, true),
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFFD82532),
                  foregroundColor: Colors.white,
                  minimumSize: const Size.fromHeight(48),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                  shape: const StadiumBorder(),
                ),
                child: const Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.remove_rounded, size: 16),
                    SizedBox(width: 7),
                    Flexible(child: Text('确认移除')),
                  ],
                ),
              ),
              const SizedBox(height: 4),
              TextButton(
                onPressed: () => Navigator.pop(sheet, false),
                child: Text(
                  '取消',
                  style: HomeStyle.text(13, color: HomeStyle.secondary(sheet)),
                ),
              ),
            ],
          ),
        ),
      ),
    ) ??
    false;
