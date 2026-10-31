import 'package:yanshu/features/progress/repositories/progress_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:yanshu/app/app.dart';
import 'package:yanshu/features/notifications/notification_model.dart';
import 'package:yanshu/features/notifications/notification_views.dart';
import 'package:yanshu/features/profile/repositories/profile_repository.dart';
import 'package:yanshu/features/knowledge/repositories/knowledge_repository.dart';

void main() {
  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    testWidgets(
      'global notification prompts, badge and permissions on $platform',
      (tester) async {
        tester.view.physicalSize = const Size(320, 640);
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.textScaleFactorTestValue = 2;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        await tester.pumpWidget(
          YanShuApp(
            progressRepository: MockProgressRepository(),
            profileRepository: ProfileRepository(MemoryProfileStore()),
            knowledgeRepository: KnowledgeRepository(
              MemoryKnowledgeStore(),
              seedExamples: true,
            ),
          ),
        );
        await tester.pumpAndSettle();
        final model = tester
            .element(find.byType(NotificationHost))
            .read<NotificationModel>();
        model.clearAll();
        expect(model.pendingCount, 0);
        var calls = 0;
        model.receive(
          const ActionNotice(
            id: 'global-action',
            kind: NoticeKind.warning,
            title: '保存会议摘要',
            instruction: '将摘要保存到知识库。',
          ),
          onAllow: () async {
            calls++;
            return true;
          },
        );
        await tester.pumpAndSettle();
        expect(find.text('保存会议摘要'), findsOneWidget);
        expect(model.pendingCount, 1);
        await tester.tap(find.byTooltip('稍后处理'));
        await tester.pumpAndSettle();
        expect(model.pendingCount, 1);
        await tester.tap(find.byTooltip('通知'));
        await tester.pumpAndSettle();
        expect(find.byType(NotificationsPage), findsOneWidget);
        final allow = find.byKey(const ValueKey('allow-global-action'));
        await tester.scrollUntilVisible(allow, 200);
        await tester.pumpAndSettle();
        await tester.tap(allow);
        await tester.pumpAndSettle();
        expect(calls, 1);
        expect(model.pendingCount, 0);
        expect(find.text('内容预览'), findsNothing);
        await tester.tap(find.byType(BackButton));
        await tester.pumpAndSettle();
        expect(find.byTooltip('通知'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant({platform}),
    );
  }
}
