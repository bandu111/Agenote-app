import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yanshu/app/theme/app_theme.dart';
import 'package:yanshu/features/recording_status/recording_permission_guide.dart';
import 'package:yanshu/features/recording_status/recording_status_snapshot.dart';

void main() {
  for (final answer in [true, false]) {
    testWidgets(
      'permission guide returns explicit choice $answer, not a granted state',
      (t) async {
        bool? result;
        await t.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () async {
                    result = await showDialog<bool>(
                      context: context,
                      builder: (_) => const RecordingPermissionGuide(),
                    );
                  },
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        );
        await t.tap(find.text('Open'));
        await t.pumpAndSettle();
        expect(find.textContaining('授权状态以实际开关为准'), findsOneWidget);
        await t.tap(
          find.byKey(
            ValueKey(
              answer
                  ? 'recording-permission-enable'
                  : 'recording-permission-later',
            ),
          ),
        );
        await t.pumpAndSettle();
        expect(result, answer);
      },
    );
  }
  testWidgets('guide adapts to narrow large text without losing its actions', (
    t,
  ) async {
    t.view.physicalSize = const Size(320, 640);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    await t.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(
            textScaler: TextScaler.linear(2),
            disableAnimations: true,
          ),
          child: Scaffold(body: const RecordingPermissionGuide()),
        ),
      ),
    );
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
    await t.ensureVisible(
      find.byKey(const ValueKey('recording-permission-enable')),
    );
    expect(find.text('开启实时活动'), findsOneWidget);
  });
  testWidgets('guide screenshot for selected source comparison', (t) async {
    if (!const bool.fromEnvironment('RECORDING_STATUS_CAPTURE')) return;
    await t.runAsync(() async {
      for (final font in [
        ('Roboto', 'assets/fonts/NotoSansSC-Regular.ttf'),
        ('InstrumentSans', 'assets/fonts/InstrumentSans.ttf'),
        ('AgenoteNotoSC', 'assets/fonts/NotoSansSC-Regular.ttf'),
        ('MaterialIcons', 'fonts/MaterialIcons-Regular.otf'),
      ]) {
        await (FontLoader(font.$1)..addFont(rootBundle.load(font.$2))).load();
      }
    });
    t.view.physicalSize = const Size(393, 500);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    await t.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: RepaintBoundary(
          key: const ValueKey('guide-shot'),
          child: Scaffold(
            backgroundColor: const Color(0xFF9196A3),
            body: RecordingPermissionGuide(
              snapshot: RecordingStatusSnapshot(
                meetingId: 'qa',
                source: 'phone',
                sourceLabel: '手机麦克风',
                capturing: true,
                connected: true,
                state: 'recording',
                transcription: 'transcribing',
                elapsed: const Duration(minutes: 12, seconds: 4),
                startedAt: DateTime(2026),
              ),
            ),
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    await t.runAsync(() async {
      final im = await t
          .renderObject<RenderRepaintBoundary>(
            find.byKey(const ValueKey('guide-shot')),
          )
          .toImage();
      final png = await im.toByteData(format: ui.ImageByteFormat.png);
      await Directory('build/recording-status-qa').create(recursive: true);
      await File(
        'build/recording-status-qa/permission-guide.png',
      ).writeAsBytes(png!.buffer.asUint8List());
      im.dispose();
    });
  });
}
