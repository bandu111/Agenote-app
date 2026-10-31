import 'package:flutter/material.dart';
import '../home/views/home_style.dart';
import 'recorder_models.dart';

String deviceConnectionLabel(RecorderConnection state) => switch (state) {
  RecorderConnection.connected => '已连接',
  RecorderConnection.connecting => '连接中',
  RecorderConnection.disconnecting => '正在断开',
  RecorderConnection.disconnected => '未连接',
};
String deviceRecordingLabel(RecorderState state) => switch (state) {
  RecorderState.idle => '未在录音',
  RecorderState.recording => '录音中',
  RecorderState.paused => '已暂停',
  _ => '状态未知',
};
String deviceCapacity(int? kb) => kb == null
    ? '未获取'
    : kb >= 1024 * 1024
    ? '${(kb / (1024 * 1024)).toStringAsFixed(2)} GiB'
    : '${(kb / 1024).toStringAsFixed(1)} MiB';
String maskedSerial(String sn) =>
    '•••• ${sn.length > 4 ? sn.substring(sn.length - 4) : sn}';

class DeviceGroup extends StatelessWidget {
  const DeviceGroup({super.key, required this.children});
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 22),
    child: Material(
      color: HomeStyle.surface(context),
      borderRadius: BorderRadius.circular(18),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0) const Divider(indent: 16, height: 1),
            children[i],
          ],
        ],
      ),
    ),
  );
}

class DeviceInfoRow extends StatelessWidget {
  const DeviceInfoRow(
    this.label,
    this.value, {
    super.key,
    this.onTap,
    this.icon,
    this.loading = false,
    this.destructive = false,
    this.action = false,
  });
  final String label, value;
  final VoidCallback? onTap;
  final IconData? icon;
  final bool loading, destructive, action;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final stacked =
        MediaQuery.textScalerOf(context).scale(16) > 22 ||
        MediaQuery.sizeOf(context).width < 340;
    final title = Text(
      label,
      style: TextStyle(
        fontSize: 16,
        color: action && onTap == null
            ? colors.onSurfaceVariant
            : destructive
            ? colors.error
            : (action || onTap != null)
            ? colors.primary
            : colors.onSurface,
      ),
    );
    final detail = Text(
      value,
      softWrap: true,
      style: TextStyle(fontSize: 15, color: colors.onSurfaceVariant),
    );
    final content = Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          if (icon != null && icon != Icons.copy_outlined) ...[
            Icon(icon, size: 21, color: colors.primary),
            const SizedBox(width: 12),
          ],
          Expanded(
            child: stacked
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      title,
                      if (value.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        detail,
                      ],
                    ],
                  )
                : Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      title,
                      const SizedBox(width: 12),
                      if (value.isNotEmpty)
                        Expanded(
                          child: Align(
                            alignment: Alignment.centerRight,
                            child: detail,
                          ),
                        ),
                    ],
                  ),
          ),
          if (loading) ...[
            const SizedBox(width: 10),
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ],
          if (onTap != null && icon == Icons.copy_outlined) ...[
            const SizedBox(width: 8),
            Icon(Icons.copy_outlined, size: 18, color: colors.primary),
          ],
        ],
      ),
    );
    return Semantics(
      button: action || onTap != null,
      enabled: action ? onTap != null : null,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 56),
        child: onTap == null ? content : InkWell(onTap: onTap, child: content),
      ),
    );
  }
}

class DeviceNotice extends StatelessWidget {
  const DeviceNotice(this.text, {super.key, this.error = false});
  final String text;
  final bool error;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 0, 4, 16),
    child: Semantics(
      liveRegion: true,
      child: Text(
        text,
        style: TextStyle(
          fontSize: 14,
          color: error
              ? Theme.of(context).colorScheme.error
              : HomeStyle.secondary(context),
        ),
      ),
    ),
  );
}

class DeviceContent extends StatelessWidget {
  const DeviceContent({super.key, required this.children});
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => SafeArea(
    child: Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 30),
          children: children,
        ),
      ),
    ),
  );
}
