import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:yanshu/core/network/api_client.dart';
import 'package:yanshu/features/profile/models/profile_data.dart';
import 'package:yanshu/features/profile/repositories/profile_repository.dart';
import 'package:yanshu/features/profile/viewmodels/profile_view_model.dart';
import 'package:yanshu/features/work_assistant/outcome_detail_page.dart';
import 'package:yanshu/features/work_assistant/outcome_page.dart';
import 'package:yanshu/features/work_assistant/pdf_button.dart';
import 'package:yanshu/shared/widgets/content_skeleton.dart';
import 'dio_auth_repository_test.dart' show TestAdapter, envelope;

class MutableProfileViewModel extends ProfileViewModel {
  MutableProfileViewModel(ProfileRepository repository, String owner)
    : super(repository: repository) {
    data = ProfileData(accountId: owner, sessionActive: true);
    ready = true;
    loading = false;
  }

  void switchOwner(String owner) {
    data = ProfileData(accountId: owner, sessionActive: true);
    notifyListeners();
  }
}

void main() {
  testWidgets('成果详情捕获 owner，账号切换后丢弃迟到私有响应', (tester) async {
    String owner = 'owner-a';
    final pending = Completer<(int, Object?)>();
    String? requestedPath;
    final api =
        ApiClient(
            baseUrl: 'https://test.example/',
            dio: Dio()
              ..httpClientAdapter = TestAdapter((request) {
                requestedPath = request.path;
                return pending.future;
              }),
          )
          ..accountId = (() => owner)
          ..accessToken = (() async => 'token');
    final profile = MutableProfileViewModel(
      ProfileRepository(MemoryProfileStore(), client: api),
      owner,
    );
    addTearDown(profile.dispose);
    addTearDown(() => api.dio.close(force: true));
    await tester.pumpWidget(
      ChangeNotifierProvider<ProfileViewModel>.value(
        value: profile,
        child: const MaterialApp(home: OutcomeDetailPage(runId: 'private/id')),
      ),
    );
    await tester.pump();
    expect(find.byType(ContentSkeleton), findsOneWidget);
    for (var i = 0; i < 10 && requestedPath == null; i++) {
      await tester.pump(const Duration(milliseconds: 1));
    }
    expect(requestedPath, 'assistant/outcomes/private%2Fid');
    owner = 'owner-b';
    profile.switchOwner(owner);
    await tester.pump();
    expect(find.text('账号已切换，请返回重新打开成果'), findsOneWidget);
    pending.complete((
      200,
      envelope({
        'id': 'private/id',
        'kind': 'role_outcome',
        'status': 'succeeded',
        'result': {'title': 'A 账号私有报告'},
      }),
    ));
    await tester.pump(const Duration(milliseconds: 30));
    expect(find.text('A 账号私有报告'), findsNothing);
    expect(find.text('账号已切换，请返回重新打开成果'), findsOneWidget);
  });

  testWidgets('成果详情使用鉴权 GET 并明确显示 404 失效', (tester) async {
    final api =
        ApiClient(
            baseUrl: 'https://test.example/',
            dio: Dio()
              ..httpClientAdapter = TestAdapter((request) async {
                expect(request.path, 'assistant/outcomes/missing');
                expect(request.headers['Authorization'], 'Bearer token');
                return (
                  404,
                  envelope(null, status: 404, message: 'outcome_not_found'),
                );
              }),
          )
          ..accountId = (() => 'owner')
          ..accessToken = (() async => 'token');
    final profile = MutableProfileViewModel(
      ProfileRepository(MemoryProfileStore(), client: api),
      'owner',
    );
    addTearDown(profile.dispose);
    addTearDown(() => api.dio.close(force: true));
    await tester.pumpWidget(
      ChangeNotifierProvider<ProfileViewModel>.value(
        value: profile,
        child: const MaterialApp(home: OutcomeDetailPage(runId: 'missing')),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('成果已失效或不存在'), findsOneWidget);
    expect(find.text('重试'), findsNothing);
  });

  testWidgets('会前准备渲染服务端字段且无 PDF，职业成果保留 PDF', (tester) async {
    tester.view.physicalSize = const Size(800, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = ApiClient(baseUrl: 'https://test.example/', dio: Dio())
      ..accountId = (() => 'owner');
    final profile = MutableProfileViewModel(
      ProfileRepository(MemoryProfileStore(), client: api),
      'owner',
    );
    addTearDown(profile.dispose);
    addTearDown(() => api.dio.close(force: true));
    Widget page(Map<String, dynamic> row) =>
        ChangeNotifierProvider<ProfileViewModel>.value(
          value: profile,
          child: MaterialApp(
            home: OutcomePage(row: row, owner: 'owner', client: api),
          ),
        );
    await tester.pumpWidget(
      page({
        'id': 'prep-1',
        'kind': 'meeting_preparation',
        'status': 'succeeded',
        'result': {
          'title': '项目评审会前准备',
          'summary': '仅依据已核验资料整理。',
          'meeting': {
            'title': '项目评审',
            'start': '2030-10-29T14:00:00+08:00',
            'timeZone': 'Asia/Shanghai',
            'agenda': '确认验收范围',
          },
          'sections': [
            {'title': '历史决定', 'content': '范围以已签字版本为准。'},
          ],
          'checklist': [
            {'text': '打开验收清单', 'status': 'suggested'},
          ],
          'reading': [
            {'title': '验收清单', 'sourceId': 'doc:1', 'reason': '核对范围'},
          ],
          'dataGaps': ['缺少最新排期'],
          'sources': [
            {
              'id': 'doc:1',
              'title': '已核验清单',
              'quote': '范围以已签字版本为准',
              'path': '/knowledge/documents/doc-1',
            },
            {
              'id': 'external:1',
              'title': '外部地址只展示不跳转',
              'quote': '不可信路径',
              'path': 'https://evil.example/private',
            },
          ],
        },
      }),
    );
    expect(find.text('会前准备'), findsOneWidget);
    expect(find.text('项目评审'), findsOneWidget);
    expect(find.textContaining('Asia/Shanghai'), findsOneWidget);
    expect(find.text('议程：确认验收范围'), findsOneWidget);
    expect(find.text('历史决定'), findsOneWidget);
    expect(find.text('打开验收清单'), findsOneWidget);
    expect(find.textContaining('缺少最新排期'), findsOneWidget);
    expect(find.text('范围以已签字版本为准'), findsOneWidget);
    expect(find.byType(OutcomePdfButton), findsNothing);
    expect(find.text('查看 PDF 报告'), findsNothing);
    expect(find.text('查看资料'), findsNWidgets(2));

    await tester.pumpWidget(
      page({
        'id': 'role-1',
        'kind': 'role_outcome',
        'status': 'succeeded',
        'delivery': {'status': 'accepted'},
        'result': {'title': '职业分析报告', 'summary': '真实摘要'},
      }),
    );
    await tester.pump();
    expect(find.text('分析成果'), findsOneWidget);
    expect(find.text('职业分析报告'), findsOneWidget);
    expect(find.byType(OutcomePdfButton), findsOneWidget);
    expect(find.text('查看 PDF 报告'), findsOneWidget);
  });
}
