import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yanshu/features/meeting/meeting_ai_glow.dart';

void main() {
  testWidgets('生成结束后停止循环并恢复，卡片内容保持可见', (tester) async {
    Widget scene(bool active) => MaterialApp(
      home: Scaffold(body: MeetingAiGlow(
        active: active,
        child: const SizedBox(width: 300, height: 120, child: Text('原始发言')),
      )),
    );
    await tester.pumpWidget(scene(true));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('原始发言'), findsOneWidget);
    expect(tester.hasRunningAnimations, isTrue);
    await tester.pumpWidget(scene(false));
    await tester.pumpAndSettle();
    expect(tester.hasRunningAnimations, isFalse);
    expect(find.text('原始发言'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
