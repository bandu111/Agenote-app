import 'dart:async';
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:yanshu/app/app.dart';
import 'package:yanshu/core/network/api_client.dart';
import 'package:yanshu/features/knowledge/repositories/knowledge_repository.dart';
import 'package:yanshu/features/meeting/meeting_store.dart';
import 'package:yanshu/features/profile/models/profile_data.dart';
import 'package:yanshu/features/profile/repositories/profile_repository.dart';
import 'package:yanshu/features/profile/viewmodels/profile_view_model.dart';
import 'package:yanshu/features/profile/views/profile_page.dart';
import 'package:yanshu/features/work_assistant/assistant_page.dart';
import 'dio_auth_repository_test.dart' show TestAdapter, envelope;
import 'meeting_test.dart' show FakeMeetingRecorder;

class _RefreshingProfile extends ProfileRepository {
  _RefreshingProfile(ApiClient client)
    : super(
        MemoryProfileStore(
          value: jsonEncode(
            const ProfileData(
              accountId: 'owner',
              email: 'owner@example.com',
              name: '测试用户',
            ).toJson(),
          ),
        ),
        client: client,
      );
  final refresh = Completer<void>();
  int reads = 0;
  @override
  Future<ProfileData> fetchCloud(ProfileData local) async {
    if (++reads > 1) await refresh.future;
    return local;
  }
}

void main() {
  testWidgets(
    'bound assistant remains open throughout profile refresh and returns normally',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final client = ApiClient(baseUrl: 'https://test.invalid/', dio: Dio());
      client.accountId = () => 'owner';
      client.dio.httpClientAdapter = TestAdapter(
        (request) async => (
          200,
          envelope(
            request.path.endsWith('outcomes')
                ? []
                : {
                    'bindingStatus': 'bound',
                    'canSend': true,
                    'preferences': <String, dynamic>{},
                  },
          ),
        ),
      );
      final repository = _RefreshingProfile(client);
      await tester.pumpWidget(
        YanShuApp(
          initialLocation: '/profile',
          profileRepository: repository,
          meetingStore: MemoryMeetingStore(),
          meetingRecorder: FakeMeetingRecorder(),
          knowledgeRepository: KnowledgeRepository(MemoryKnowledgeStore()),
          connectRecordingCardToMeetings: false,
        ),
      );
      await tester.pumpAndSettle();
      final entry = find.byKey(const ValueKey('profile-wechat-assistant'));
      await tester.ensureVisible(entry);
      await tester.tap(entry);
      await tester.pump();
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pump(const Duration(milliseconds: 400));
      final profile = tester
          .element(find.byType(WorkAssistantPage))
          .read<ProfileViewModel>();
      expect(repository.reads, 2);
      expect(profile.loading, isTrue);
      expect(find.text('微信助手已连接'), findsOneWidget);
      expect(find.text('职业与分析偏好'), findsNothing);
      expect(find.text('分析成果'), findsNothing);
      expect(find.byType(CupertinoSwitch), findsNWidgets(4));
      expect(find.byKey(const ValueKey('startup-home-skeleton')), findsNothing);
      repository.refresh.complete();
      await tester.pumpAndSettle();
      expect(find.byType(WorkAssistantPage), findsOneWidget);
      expect(find.text('微信助手已连接'), findsOneWidget);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.byType(ProfilePage), findsOneWidget);
      expect(find.byType(WorkAssistantPage), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );
  testWidgets('unbound page shows reference introduction and QR area only', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final client = ApiClient(baseUrl: 'https://test.invalid/', dio: Dio())
      ..accountId = () => 'owner';
    client.dio.httpClientAdapter = TestAdapter(
      (request) async => (
        200,
        envelope(
          request.path.endsWith('outcomes')
              ? []
              : {
                  'bindingStatus': 'pending',
                  'canBind': true,
                  'qr': 'https://liteapp.weixin.qq.com/test',
                },
        ),
      ),
    );
    await tester.pumpWidget(
      YanShuApp(
        initialLocation: '/profile/wechat-assistant',
        profileRepository: _RefreshingProfile(client),
        meetingStore: MemoryMeetingStore(),
        meetingRecorder: FakeMeetingRecorder(),
        knowledgeRepository: KnowledgeRepository(MemoryKnowledgeStore()),
        connectRecordingCardToMeetings: false,
      ),
    );
    await tester.pump();
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpAndSettle();
    expect(find.text('让 Hermes 在微信里找到你'), findsOneWidget);
    expect(find.text('职业与分析偏好'), findsNothing);
    expect(find.text('分析成果'), findsNothing);
    expect(find.text('一次性绑定码'), findsNothing);
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('wechat-authorization-qr')),
      180,
      scrollable: find.byType(Scrollable).first,
    );
    expect(
      find.byKey(const ValueKey('wechat-authorization-qr')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });
}
