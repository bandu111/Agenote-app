import 'dart:convert';
import 'package:yanshu/app/router/app_router.dart';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:go_router/go_router.dart';
import 'package:yanshu/features/profile/models/profile_data.dart';
import 'package:yanshu/features/profile/models/personalization_data.dart';
import 'package:yanshu/features/profile/repositories/profile_repository.dart';
import 'package:yanshu/features/profile/viewmodels/profile_view_model.dart';
import 'package:yanshu/features/personalization/personalization_controller.dart';
import 'package:yanshu/features/personalization/personalization_page.dart';
import 'package:yanshu/core/network/api_config.dart';

class Drafts implements PersonalizationDraftStore {
  final values = <String, String>{};
  @override
  Future<String?> read(String owner) async => values[owner];
  @override
  Future<void> write(String owner, String? value) async {
    if (value == null) {
      values.remove(owner);
    } else {
      values[owner] = value;
    }
  }
}

class CloudProfiles extends ProfileRepository {
  CloudProfiles()
    : super(
        MemoryProfileStore(
          value: jsonEncode(
            const ProfileData(
              accountId: 'owner',
              cloudVersion: 1,
              name: 'Registered name',
              personalization: PersonalizationData(),
            ).toJson(),
          ),
        ),
      );
  bool fail = false;
  int writes = 0;
  @override
  Future<void> savePersonalization(
    ProfileData current,
    Map<String, dynamic> p,
  ) async {
    writes++;
    if (fail) throw const ApiFailure('网络不可用，请重试');
    final value = PersonalizationData(
      status: p['action'] == 'complete'
          ? 'completed'
          : p['action'] == 'skip'
          ? 'skipped'
          : 'in_progress',
      step: p['action'] == 'continue' ? 2 : p['step'],
      profession: p['profession'],
      professionOther: p['profession_other'],
      scenarios: List<String>.from(p['scenarios']),
      scenarioOther: p['scenario_other'],
    );
    await save(
      current.copyWith(
        name: (p['name'] as String).isEmpty ? current.name : p['name'],
        cloudVersion: current.cloudVersion + 1,
        personalization: value,
      ),
    );
  }
}

Future<ProfileViewModel> profile(CloudProfiles r) async {
  final p = ProfileViewModel(repository: r);
  await p.load();
  return p;
}

void main() {
  test(
    'real account gate: old/completed/skipped bypass, pending resumes, resolving does not jump home',
    () async {
      final p = await profile(CloudProfiles());
      expect(accountRedirect(p, '/home'), '/personalization');
      p.resolvingAccount = true;
      expect(accountRedirect(p, '/register'), isNull);
      p.resolvingAccount = false;
      p.data = p.data.copyWith(clearPersonalization: true);
      expect(accountRedirect(p, '/login'), '/home');
      for (final status in ['completed', 'skipped']) {
        p.data = p.data.copyWith(
          personalization: PersonalizationData(status: status),
        );
        expect(accountRedirect(p, '/personalization'), '/home');
      }
      p.data = p.data.copyWith(sessionActive: false);
      expect(accountRedirect(p, '/personalization'), '/login');
      p.dispose();
    },
  );
  testWidgets(
    'iOS left edge gesture returns to first step with retained username',
    (t) async {
      final p = await profile(CloudProfiles());
      await t.pumpWidget(
        ChangeNotifierProvider.value(
          value: p,
          child: MaterialApp(
            theme: ThemeData(platform: TargetPlatform.iOS),
            home: PersonalizationPage(drafts: Drafts()),
          ),
        ),
      );
      await t.pumpAndSettle();
      await t.tap(find.text('继续'));
      await t.pumpAndSettle();
      expect(find.text('02 / 02'), findsOneWidget);
      await t.dragFrom(const Offset(8, 220), const Offset(160, 0));
      await t.pumpAndSettle();
      expect(find.text('01 / 02'), findsOneWidget);
      expect(find.text('Registered name'), findsOneWidget);
      await t.pumpWidget(const SizedBox());
      p.dispose();
    },
  );

  test(
    'cloud roundtrip retains nickname, resume step, completion and per-account drafts',
    () async {
      final r = CloudProfiles(), drafts = Drafts();
      final p = await profile(r);
      final c = PersonalizationController(p, store: drafts);
      await c.initialize();
      expect(c.name, 'Registered name');
      c.name = '新昵称';
      c.profession = 'software';
      c.changed();
      expect(await c.submit('continue'), isTrue);
      expect(p.data.name, '新昵称');
      expect(c.step, 2);
      c.dispose();
      final fresh = await profile(r),
          resumed = PersonalizationController(await profile(r), store: drafts);
      await resumed.initialize();
      expect(resumed.step, 2);
      expect(resumed.profession, 'software');
      resumed.scenarios = {'work', 'technical'};
      expect(await resumed.submit('complete'), isTrue);
      expect(fresh.data.personalization!.step, 2);
      expect((await r.load()).personalization!.status, 'completed');
      expect(drafts.values.containsKey('owner'), isFalse);
      resumed.dispose();
      p.dispose();
      fresh.dispose();
    },
  );
  test(
    'failed saves preserve input, retry, empty nickname retains actual username, skip incomplete custom',
    () async {
      final r = CloudProfiles(), drafts = Drafts();
      final p = await profile(r);
      final c = PersonalizationController(p, store: drafts);
      await c.initialize();
      r.fail = true;
      c.name = 'Name edit';
      c.profession = 'finance';
      c.changed();
      expect(await c.submit('continue'), isFalse);
      expect(c.name, 'Name edit');
      expect(c.step, 1);
      expect(c.error, isNotNull);
      r.fail = false;
      c.name = '';
      c.profession = 'other';
      c.professionOther = '';
      expect(await c.submit('skip'), isTrue);
      expect(p.data.name, 'Registered name');
      expect(p.data.personalization!.status, 'skipped');
      expect(p.data.personalization!.profession, '');
      c.dispose();
      p.dispose();
    },
  );
  test(
    'draft restore is isolated by account and ignores stale versions',
    () async {
      final r = CloudProfiles(), d = Drafts();
      final p = await profile(r);
      await d.write(
        'owner',
        jsonEncode({
          'version': 1,
          'name': 'Unsent edit',
          'step': 1,
          'profession': 'design',
          'scenarios': [],
        }),
      );
      final c = PersonalizationController(p, store: d);
      await c.initialize();
      expect(c.name, 'Unsent edit');
      c.dispose();
      p.data = p.data.copyWith(
        accountId: 'other',
        name: 'Other user',
        clearPersonalization: true,
      );
      final other = PersonalizationController(p, store: d);
      await other.initialize();
      expect(other.name, 'Other user');
      other.dispose();
      p.data = p.data.copyWith(
        accountId: 'owner',
        cloudVersion: 4,
        name: 'Remote edit',
        personalization: const PersonalizationData(),
      );
      final newer = PersonalizationController(p, store: d);
      await newer.initialize();
      expect(newer.name, 'Remote edit');
      newer.dispose();
      p.dispose();
    },
  );
  testWidgets(
    'register profile routing resumes first two steps, back preserves edits and completes',
    (t) async {
      final r = CloudProfiles(), p = await profile(r), d = Drafts();
      final router = GoRouter(
        initialLocation: '/personalization',
        routes: [
          GoRoute(
            path: '/personalization',
            builder: (_, _) => PersonalizationPage(drafts: d),
          ),
          GoRoute(
            path: '/home',
            builder: (_, _) => const Scaffold(body: Text('Existing home')),
          ),
        ],
      );
      await t.pumpWidget(
        ChangeNotifierProvider.value(
          value: p,
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await t.pumpAndSettle();
      expect(find.text('Registered name'), findsOneWidget);
      await t.enterText(find.byType(TextField).first, 'My nickname');
      await t.tap(find.text('软件开发'));
      await t.tap(find.text('继续'));
      await t.pumpAndSettle();
      expect(find.text('02 / 02'), findsOneWidget);
      await t.tap(find.text('工作会议'));
      await t.tap(find.byTooltip('返回'));
      await t.pumpAndSettle();
      expect(find.text('My nickname'), findsOneWidget);
      await t.tap(find.text('继续'));
      await t.pumpAndSettle();
      await t.tap(find.text('开启 Agenote'));
      await t.pumpAndSettle();
      expect(find.text('Existing home'), findsOneWidget);
      expect(p.data.personalization!.scenarios, ['work']);
      expect(p.data.name, 'My nickname');
      await t.pumpWidget(const SizedBox());
      router.dispose();
      p.dispose();
    },
  );
  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    testWidgets('small screen large text keyboard safe $platform', (t) async {
      t.view.physicalSize = const Size(320, 640);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final p = await profile(CloudProfiles());
      await t.pumpWidget(
        ChangeNotifierProvider.value(
          value: p,
          child: MaterialApp(
            theme: ThemeData(platform: platform),
            home: MediaQuery(
              data: const MediaQueryData(
                size: Size(320, 640),
                textScaler: TextScaler.linear(2),
                viewInsets: EdgeInsets.only(bottom: 250),
                disableAnimations: true,
              ),
              child: PersonalizationPage(drafts: Drafts()),
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      await t.tap(find.text('继续'));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
      p.dispose();
    });
  }
  testWidgets('visual capture of both steps', (t) async {
    t.view.physicalSize = const Size(402, 874);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    if (const bool.fromEnvironment('PERSONALIZATION_CAPTURE')) {
      await t.runAsync(() async {
        for (final pair in [
          ('MaterialIcons', 'fonts/MaterialIcons-Regular.otf'),
          ('InstrumentSans', 'assets/fonts/InstrumentSans.ttf'),
          ('AgenoteNotoSC', 'assets/fonts/NotoSansSC-Regular.ttf'),
        ]) {
          await (FontLoader(pair.$1)..addFont(rootBundle.load(pair.$2))).load();
        }
      });
    }
    final p = await profile(CloudProfiles());
    await t.pumpWidget(
      ChangeNotifierProvider.value(
        value: p,
        child: MaterialApp(
          home: RepaintBoundary(
            key: const ValueKey('shot'),
            child: PersonalizationPage(drafts: Drafts()),
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    if (const bool.fromEnvironment('PERSONALIZATION_CAPTURE')) {
      Future<void> shot(String name) async {
        final b = t.renderObject<RenderRepaintBoundary>(
          find.byKey(const ValueKey('shot')),
        );
        final im = await b.toImage();
        final bytes = await im.toByteData(format: ui.ImageByteFormat.png);
        await Directory('build/personalization-qa').create(recursive: true);
        await File(
          'build/personalization-qa/$name.png',
        ).writeAsBytes(bytes!.buffer.asUint8List());
        im.dispose();
      }

      await t.runAsync(() => shot('step1'));
      await t.tap(find.text('继续'));
      await t.pumpAndSettle();
      await t.tap(find.text('工作会议'));
      await t.pumpAndSettle();
      await t.runAsync(() => shot('step2'));
    }
    await t.pumpWidget(const SizedBox());
    p.dispose();
  });
}
