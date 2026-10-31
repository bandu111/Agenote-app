import 'package:flutter/material.dart';
import '../../features/home/views/home_style.dart';

Future<bool> showAppConfirmation(
  BuildContext context, {
  required String title,
  required String message,
  required String action,
  String cancel = '取消',
  IconData icon = Icons.info_outline_rounded,
  Color actionColor = HomeStyle.blue,
  Key? actionKey,
}) async =>
    await showDialog<bool>(
      context: context,
      useRootNavigator: true,
      builder: (dialog) => Dialog(
        backgroundColor: HomeStyle.surface(dialog),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(24),
          side: BorderSide(
            color: HomeStyle.secondary(dialog).withValues(alpha: .12),
          ),
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: EdgeInsets.only(top: 2),
                    child: Icon(icon, color: actionColor, size: 20),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: HomeStyle.text(
                            15,
                            bold: true,
                            color: HomeStyle.foreground(dialog),
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          message,
                          style: HomeStyle.text(
                            12,
                            color: HomeStyle.secondary(dialog),
                          ).copyWith(height: 1.6),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              LayoutBuilder(
                builder: (context, constraints) {
                  final textStyle = HomeStyle.text(
                    13,
                    bold: true,
                  ).copyWith(height: 1.3);
                  final scaler = MediaQuery.textScalerOf(context);
                  final buttonHeight = (scaler.scale(13) * 1.3 + 20).clamp(
                    44.0,
                    double.infinity,
                  );
                  double labelWidth(String label) {
                    final painter = TextPainter(
                      text: TextSpan(text: label, style: textStyle),
                      textScaler: scaler,
                      textDirection: Directionality.of(context),
                    )..layout();
                    final width = painter.width;
                    painter.dispose();
                    return width + 24;
                  }

                  final stacked =
                      labelWidth(cancel) > (constraints.maxWidth - 10) / 2 ||
                      labelWidth(action) > (constraints.maxWidth - 10) / 2;
                  final cancelButton = SizedBox(
                    height: buttonHeight,
                    child: OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        textStyle: textStyle,
                        foregroundColor: HomeStyle.foreground(dialog),
                        side: BorderSide(
                          color: HomeStyle.blue.withValues(alpha: .15),
                        ),
                        shape: const StadiumBorder(),
                      ),
                      onPressed: () => Navigator.pop(dialog, false),
                      child: Text(cancel, maxLines: 1, softWrap: false),
                    ),
                  );
                  final actionButton = SizedBox(
                    height: buttonHeight,
                    child: FilledButton(
                    key: actionKey,
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        textStyle: textStyle,
                        backgroundColor: actionColor,
                        foregroundColor: Colors.white,
                        shape: const StadiumBorder(),
                      ),
                      onPressed: () => Navigator.pop(dialog, true),
                      child: Text(action, maxLines: 1, softWrap: false),
                    ),
                  );
                  return stacked
                      ? Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            cancelButton,
                            const SizedBox(height: 10),
                            actionButton,
                          ],
                        )
                      : Row(
                          children: [
                            Expanded(child: cancelButton),
                            const SizedBox(width: 10),
                            Expanded(child: actionButton),
                          ],
                        );
                },
              ),
            ],
          ),
        ),
      ),
    ) ??
    false;
