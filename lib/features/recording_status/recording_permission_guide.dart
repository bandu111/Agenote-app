import 'package:flutter/material.dart';
import '../meeting/meeting_models.dart';
import '../first_run/brand_tokens.dart';
import 'recording_status_snapshot.dart';

/// App-owned explanation, not an OS permission result or a fake system island.
class RecordingPermissionGuide extends StatelessWidget {
  const RecordingPermissionGuide({super.key, this.snapshot});
  final RecordingStatusSnapshot? snapshot;
  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    const blue = Color(0xFF065CFF);
    final ink = dark ? const Color(0xFFF2F5FF) : const Color(0xFF111C3E);
    final secondary = dark ? const Color(0xFFB1BDD8) : const Color(0xFF657494);
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      backgroundColor: dark ? const Color(0xFF172239) : const Color(0xFFFCFDFF),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(22, 20, 22, 14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Container(
                  constraints: const BoxConstraints(minWidth: 146),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFF0B1B3B),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Icon(
                        Icons.radio_button_checked_rounded,
                        size: 12,
                        color: Color(0xFF9DC3FF),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        snapshot?.stateLabel ?? '录音实时状态',
                        style: const TextStyle(
                          fontSize: 9,
                          fontWeight: FontWeight.w500,
                          color: Color(0xFFD9E6FF),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Text(
                        snapshot == null
                            ? 'Agenote'
                            : meetingTime(snapshot!.elapsed),
                        style: const TextStyle(
                          fontSize: 10,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(width: 5),
                      const Icon(
                        Icons.graphic_eq_rounded,
                        size: 15,
                        color: Color(0xFF4A94FF),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Text(
                '允许「录音中」显示在流体云？',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 15,
                  height: 1.4,
                  fontWeight: FontWeight.w600,
                  color: ink,
                ),
              ),
              const SizedBox(height: 7),
              Text(
                '会议刚开始。开启后退出应用或回到桌面，也能在流体云看到录音进度，随时回到这场会议。',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 11, height: 1.6, color: secondary),
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 16,
                ),
                decoration: BoxDecoration(
                  color: dark
                      ? const Color(0xFF202F4A)
                      : const Color(0xFFF2F6FF),
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Column(
                  children: [
                    _feature(
                      Icons.cloud_outlined,
                      '流体云显示实时活动',
                      '录音时在屏幕顶部显示实时胶囊',
                      ink,
                      secondary,
                    ),
                    const SizedBox(height: 16),
                    _feature(
                      Icons.lock_outline_rounded,
                      '锁屏',
                      '锁屏界面也显示录音进度',
                      ink,
                      secondary,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.info_outline_rounded, size: 11, color: secondary),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      '将在系统设置中开启，授权状态以实际开关为准。',
                      style: TextStyle(
                        fontSize: 10,
                        height: 1.5,
                        color: secondary,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  key: const ValueKey('recording-permission-enable'),
                  style: FilledButton.styleFrom(
                    backgroundColor: blue,
                    foregroundColor: Colors.white,
                    minimumSize: const Size(0, 48),
                    shape: const StadiumBorder(),
                    textStyle: BrandTypography.text(
                      13,
                      color: Colors.white,
                      weight: FontWeight.w600,
                    ),
                  ),
                  onPressed: () => Navigator.of(context).pop(true),
                  child: const Text('开启实时活动'),
                ),
              ),
              const SizedBox(height: 4),
              TextButton(
                key: const ValueKey('recording-permission-later'),
                onPressed: () => Navigator.of(context).pop(false),
                style: TextButton.styleFrom(
                  foregroundColor: secondary,
                  minimumSize: const Size(48, 40),
                ),
                child: const Text('暂不开启', style: TextStyle(fontSize: 12)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _feature(
    IconData icon,
    String title,
    String subtitle,
    Color ink,
    Color secondary,
  ) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Icon(Icons.check_box_rounded, size: 20, color: Color(0xFF065CFF)),
      const SizedBox(width: 9),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 13, color: secondary),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    title,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: ink,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              subtitle,
              style: TextStyle(fontSize: 10, height: 1.45, color: secondary),
            ),
          ],
        ),
      ),
    ],
  );
}
