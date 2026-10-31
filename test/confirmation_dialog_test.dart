import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yanshu/shared/widgets/confirmation_dialog.dart';

void main() {
  for (final scale in [1.0, 2.0]) {
    testWidgets('confirmation labels stay single line and equal height at scale $scale', (tester) async {
      tester.view.physicalSize = const Size(320, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      bool? result;
      await tester.pumpWidget(MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: Scaffold(body: Builder(builder: (context) => TextButton(
          onPressed: () async { result = await showAppConfirmation(context,
            title: '结束并归档会议？', message: '原始录音与逐字稿将保留。',
            cancel: '继续录音', action: '结束并归档'); },
          child: const Text('打开'),
        ))),
      ));
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      final cancel = find.byType(OutlinedButton);
      final action = find.byType(FilledButton);
      expect(tester.getSize(cancel).height, tester.getSize(action).height);
      expect(tester.widget<Text>(find.text('结束并归档')).maxLines, 1);
      if (scale == 1) {
        expect(tester.getTopLeft(cancel).dy, tester.getTopLeft(action).dy);
      } else {
        expect(tester.getTopLeft(action).dy, greaterThan(tester.getBottomLeft(cancel).dy));
      }
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(action);
      await tester.tap(action);
      await tester.pumpAndSettle();
      expect(result, isTrue);
    });
  }
}
