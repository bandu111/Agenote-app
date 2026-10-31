import 'package:flutter/material.dart';
import '../../home/views/home_style.dart';
import '../meeting_models.dart';

/// Shared footer for meeting evidence; navigation never starts audio playback.
class MeetingEvidenceLink extends StatelessWidget {
  const MeetingEvidenceLink({
    super.key,
    required this.at,
    required this.label,
    this.onPressed,
    this.topSpacing = 8,
    this.compact = false,
    this.inline = false,
  });
  final Duration at;
  final String label;
  final VoidCallback? onPressed;
  final double topSpacing;
  final bool compact, inline;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(top: topSpacing),
    child: Align(
      // 同行来源链接贴齐条目右边缘，避免停在分配区域的左侧。
      alignment: inline ? Alignment.centerRight : Alignment.centerLeft,
      child: TextButton(
        style: TextButton.styleFrom(
          padding: EdgeInsets.zero,
          alignment: Alignment.centerLeft,
          // 紧凑来源链接减少正文下方留白，同行显示时保留单行。
          minimumSize: Size(44, compact ? 32 : 44),
          tapTargetSize: compact ? MaterialTapTargetSize.shrinkWrap : null,
        ),
        onPressed: onPressed,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.play_circle_outline, size: 14),
            SizedBox(width: inline ? 4 : 7),
            Flexible(
              child: Text(
                label.isEmpty
                    ? meetingTime(at)
                    : '${meetingTime(at)}  ·  $label',
                maxLines: inline ? 1 : null,
                overflow: inline ? TextOverflow.ellipsis : null,
                style: HomeStyle.text(
                  12,
                  color: onPressed == null
                      ? HomeStyle.secondary(context)
                      : HomeStyle.blue,
                ),
              ),
            ),
            SizedBox(width: inline ? 3 : 5),
            const Icon(Icons.chevron_right, size: 16),
          ],
        ),
      ),
    ),
  );
}
