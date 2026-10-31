import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yanshu/features/work_assistant/wechat_unbind_sheet.dart';

void main() {
  for (final confirm in [false, true]) {
    testWidgets('unbind sheet returns explicit consent: $confirm', (t) async {
      bool? result;
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  result = await showWechatUnbindSheet(
                    context,
                    'Hermes 助手 · 测试微信',
                  );
                },
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      );
      await t.tap(find.text('打开'));
      await t.pumpAndSettle();
      expect(find.byType(BottomSheet), findsOneWidget);
      expect(find.text('Hermes 助手 · 测试微信'), findsOneWidget);
      expect(find.text('知识库、会议纪要与 AI 成果照常保留'), findsOneWidget);
      expect(result, isNull);
      await t.tap(find.text(confirm ? '确认解除绑定' : '继续用微信接收'));
      await t.pumpAndSettle();
      expect(result, confirm);
      expect(find.byType(WechatUnbindSheet), findsNothing);
      expect(t.takeException(), isNull);
    });
  }
}
