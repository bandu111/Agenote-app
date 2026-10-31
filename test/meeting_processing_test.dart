import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yanshu/features/meeting/minutes/meeting_processing_view.dart';

void main() {
  testWidgets(
    'processing shows actual loading, failure with retry, and verified results',
    (tester) async {
      var retried = false;
      Widget page({bool loading = true, String? error}) => MaterialApp(
        home: MeetingProcessingView(
          loading: loading,
          title: '接口验收讨论',
          progress: const {
            'percent': 65,
            'stage': 'validation',
            'label': '正在核对引用与行动项',
          },
          transcripts: 8,
          actions: 2,
          error: error,
          onOpen: () {},
          onHome: () {},
          onRetry: () => retried = true,
        ),
      );
      await tester.pumpWidget(page());
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('100%'), findsNothing);
      expect(find.text('65%'), findsOneWidget);
      expect(find.text('正在核对引用与行动项'), findsOneWidget);
      expect(find.text('先去忙别的'), findsOneWidget);
      await tester.pumpWidget(page(loading: false, error: '模型额度不足'));
      await tester.pumpAndSettle();
      expect(find.text('生成会议纪要失败'), findsOneWidget);
      expect(find.text('模型额度不足'), findsOneWidget);
      await tester.tap(find.text('重新生成'));
      expect(retried, isTrue);
      await tester.pumpWidget(page(loading: false));
      await tester.pumpAndSettle();
      expect(find.text('100%'), findsOneWidget);
      expect(find.text('查看纪要'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
