import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/pdf.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import 'package:yanshu/app/app.dart';
import 'package:yanshu/features/home/viewmodels/home_view_model.dart';
import 'package:yanshu/features/knowledge/repositories/knowledge_repository.dart';
import 'package:yanshu/features/profile/models/profile_data.dart';
import 'package:yanshu/features/profile/repositories/profile_repository.dart';
import 'package:yanshu/features/profile/services/profile_media.dart';
import 'package:yanshu/features/profile/services/system_access.dart';
import 'package:yanshu/features/profile/viewmodels/profile_view_model.dart';
import 'package:yanshu/features/profile/views/profile_page.dart';

Future<void> openProfile(
  WidgetTester tester, {
  ProfileStore? store,
  ProfileMediaPicker? media,
  FakeSystemAccess? permissions,
  KnowledgeStore? library,
}) async {
  await tester.pumpWidget(
    YanShuApp(
      initialLocation: '/profile',
      profileRepository: ProfileRepository(store ?? MemoryProfileStore()),
      knowledgeRepository: KnowledgeRepository(
        library ?? MemoryKnowledgeStore(),
        seedExamples: true,
      ),
      profileMediaPicker: media ?? FakeProfileMedia(),
      systemAccessService: permissions ?? FakeSystemAccess(),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> profileTap(WidgetTester tester, Finder finder) async {
  if (finder.evaluate().isEmpty) {
    final scrollables = find.byType(Scrollable);
    for (var index = 0; index < scrollables.evaluate().length; index++) {
      await tester.scrollUntilVisible(
        finder,
        240,
        scrollable: find.byType(Scrollable).at(index),
      );
      if (finder.evaluate().isNotEmpty) break;
    }
  }
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void profilePhone(WidgetTester tester) {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  testWidgets(
    'inline preferences respect haptics and notification permission before saving',
    (tester) async {
      profilePhone(tester);
      tester.view.physicalSize = const Size(320, 740);
      final store = MemoryProfileStore();
      final access = FakeSystemAccess();
      await openProfile(tester, store: store, permissions: access);
      expect(find.byType(BottomSheet), findsNothing);
      await profileTap(
        tester,
        find.byKey(const ValueKey('profile-theme-light')),
      );
      expect(jsonDecode(store.value!)['appearance'], 'light');
      await profileTap(tester, find.byKey(const ValueKey('profile-haptics')));
      expect(jsonDecode(store.value!)['hapticFeedback'], isFalse);
      await profileTap(
        tester,
        find.byKey(const ValueKey('profile-background-notifications')),
      );
      expect(access.requests, 1);
      expect(jsonDecode(store.value!)['backgroundNotifications'], isTrue);
      await profileTap(
        tester,
        find.byKey(const ValueKey('profile-background-notifications')),
      );
      expect(jsonDecode(store.value!)['backgroundNotifications'], isFalse);
      access.notifications = PermissionStatus.permanentlyDenied;
      await profileTap(
        tester,
        find.byKey(const ValueKey('profile-background-notifications')),
      );
      expect(access.requests, 1);
      expect(jsonDecode(store.value!)['backgroundNotifications'], isFalse);
      expect(find.text('请先在系统设置中允许通知'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'unreadable settings keep account entry closed until retry succeeds',
    (tester) async {
      profilePhone(tester);
      final store = RecoverableProfileStore(
        value: jsonEncode(const ProfileData(sessionActive: false).toJson()),
      );
      await openProfile(tester, store: store);
      expect(find.byType(NavigationBar), findsNothing);
      expect(find.text('资料读取失败，原有设置未被覆盖'), findsOneWidget);
      store.failRead = false;
      await profileTap(tester, find.text('重试'));
      expect(find.text('欢迎回来'), findsOneWidget);
      expect(find.byType(NavigationBar), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'edit personal information and avatar, validate email, persist only on save',
    (tester) async {
      profilePhone(tester);
      final store = MemoryProfileStore();
      final png = await PdfRasterBase(
        2,
        2,
        true,
        Uint8List.fromList(List.filled(16, 255)),
      ).toPng();
      final media = FakeProfileMedia()..value = base64Encode(png);
      await openProfile(tester, store: store, media: media);
      final vm = tester
          .element(find.byType(ProfilePage))
          .read<ProfileViewModel>();
      await profileTap(tester, find.byKey(const ValueKey('profile-edit')));
      await tester.enterText(
        find.byKey(const ValueKey('profile-field-name')),
        '林言',
      );
      await tester.enterText(
        find.byKey(const ValueKey('profile-field-email')),
        'invalid',
      );
      await profileTap(tester, find.byKey(const ValueKey('profile-save')));
      expect(find.text('请输入有效邮箱'), findsOneWidget);
      expect(vm.data.name, isEmpty);
      await tester.enterText(
        find.byKey(const ValueKey('profile-field-email')),
        'lin@example.com',
      );
      await profileTap(
        tester,
        find.byKey(const ValueKey('profile-avatar-picker')),
      );
      expect(vm.data.avatar, isNull);
      await profileTap(tester, find.byKey(const ValueKey('profile-save')));
      expect(find.text('林言'), findsOneWidget);
      expect(vm.data.avatar, media.value);
      expect(store.value, contains('lin@example.com'));
      await profileTap(tester, find.byKey(const ValueKey('profile-edit')));
      media.value = null;
      await profileTap(
        tester,
        find.byKey(const ValueKey('profile-avatar-picker')),
      );
      await tester.tap(find.byKey(const ValueKey('profile-editor-close')));
      await tester.pumpAndSettle();
      expect(vm.data.avatar, base64Encode(png));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'language, dark appearance and system options update the app and persist',
    (tester) async {
      profilePhone(tester);
      final store = MemoryProfileStore();
      await openProfile(tester, store: store);
      await profileTap(tester, find.byKey(const ValueKey('profile-language')));
      final selectorBottom = tester
          .getBottomLeft(find.byKey(const ValueKey('profile-language')))
          .dy;
      final firstOptionTop = tester
          .getTopLeft(find.byKey(const ValueKey('profile-option-zh')))
          .dy;
      expect(firstOptionTop, greaterThanOrEqualTo(selectorBottom + 8));
      expect(
        firstOptionTop,
        greaterThan(
          tester
              .getBottomLeft(find.byKey(const ValueKey('profile-appearance')))
              .dy,
        ),
      );
      await profileTap(
        tester,
        find.byKey(const ValueKey('profile-option-en')).last,
      );
      expect(find.text('Language'), findsOneWidget);
      expect(find.text('Home'), findsOneWidget);
      await profileTap(
        tester,
        find.byKey(const ValueKey('profile-theme-dark')),
      );
      expect(
        Theme.of(tester.element(find.byType(ProfilePage))).brightness,
        Brightness.dark,
      );
      expect(jsonDecode(store.value!)['appearance'], 'dark');
      for (final tab in ['Home', 'Progress', 'Library', 'Me']) {
        await profileTap(
          tester,
          find.descendant(
            of: find.byType(NavigationBar),
            matching: find.text(tab),
          ),
        );
        expect(tester.takeException(), isNull, reason: 'English dark $tab');
      }
      await profileTap(
        tester,
        find.byKey(const ValueKey('profile-theme-system')),
      );
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
      await tester.pumpAndSettle();
      expect(
        Theme.of(tester.element(find.byType(ProfilePage))).brightness,
        Brightness.dark,
      );
      await profileTap(tester, find.byKey(const ValueKey('profile-language')));
      await profileTap(
        tester,
        find.byKey(const ValueKey('profile-option-system')).last,
      );
      tester.platformDispatcher.localesTestValue = const [Locale('zh', 'CN')];
      addTearDown(tester.platformDispatcher.clearLocalesTestValue);
      await tester.pumpAndSettle();
      expect(find.text('界面语言'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'system permissions open directly without retrieval tabs and request access only after confirmation',
    (tester) async {
      profilePhone(tester);
      final access = FakeSystemAccess();
      await openProfile(tester, permissions: access);
      await profileTap(
        tester,
        find.byKey(const ValueKey('profile-permissions')),
      );
      expect(find.byType(TabBar), findsNothing);
      expect(find.byType(TabBarView), findsNothing);
      expect(find.text('检索范围'), findsNothing);
      expect(find.text('系统权限'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('system-permission-notifications')),
        findsOneWidget,
      );
      expect(access.requests, 0);
      await profileTap(
        tester,
        find.byKey(const ValueKey('system-permission-microphone')),
      );
      await profileTap(tester, find.text('取消'));
      expect(access.requests, 0);
      await profileTap(
        tester,
        find.byKey(const ValueKey('system-permission-microphone')),
      );
      await profileTap(tester, find.text('继续'));
      expect(access.requests, 1);
      expect(find.text('已允许'), findsOneWidget);
      await profileTap(
        tester,
        find.byKey(const ValueKey('system-permission-microphone')),
      );
      expect(access.openedSettings, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'sign-out locks all tabs, stops the demo, persists and resumes the same local account',
    (tester) async {
      profilePhone(tester);
      final store = MemoryProfileStore();
      await openProfile(tester, store: store);
      final context = tester.element(find.byType(ProfilePage));
      final vm = context.read<ProfileViewModel>(),
          home = context.read<HomeViewModel>();
      final id = vm.data.accountId;
      home.startDemo();
      await profileTap(tester, find.byKey(const ValueKey('profile-logout')));
      expect(find.text('是否退出登录？'), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);
      await profileTap(tester, find.text('取消'));
      expect(vm.data.sessionActive, isTrue);
      await profileTap(tester, find.byKey(const ValueKey('profile-logout')));
      await profileTap(tester, find.widgetWithText(FilledButton, '退出'));
      expect(find.byType(NavigationBar), findsNothing);
      expect(find.text('欢迎回来'), findsOneWidget);
      expect(home.sessionActive, isFalse);
      expect(jsonDecode(store.value!)['sessionActive'], isFalse);
      await profileTap(tester, find.byKey(const ValueKey('profile-resume')));
      expect(find.byType(NavigationBar), findsOneWidget);
      expect(vm.data.accountId, id);
      expect(tester.takeException(), isNull);
    },
    skip: true,
  );
  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    testWidgets(
      'profile and editor support English dark mode on narrow large text $platform',
      (tester) async {
        tester.view.physicalSize = const Size(320, 640);
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.textScaleFactorTestValue = 2;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        await openProfile(
          tester,
          store: MemoryProfileStore(
            value: jsonEncode(
              const ProfileData(
                accountId: 'local-test',
                language: 'en',
                appearance: 'dark',
              ).toJson(),
            ),
          ),
        );
        expect(tester.takeException(), isNull);
        await tester.scrollUntilVisible(
          find.byKey(const ValueKey('profile-background-notifications')),
          240,
          scrollable: find.byType(Scrollable).first,
        );
        expect(tester.takeException(), isNull);
        await tester.scrollUntilVisible(
          find.byKey(const ValueKey('profile-edit')),
          -400,
          scrollable: find.byType(Scrollable).first,
        );
        await profileTap(tester, find.byKey(const ValueKey('profile-edit')));
        await profileTap(
          tester,
          find.byKey(const ValueKey('profile-field-name')),
        );
        await tester.enterText(
          find.byKey(const ValueKey('profile-field-name')),
          'Local user',
        );
        await profileTap(tester, find.byKey(const ValueKey('profile-save')));
        expect(find.text('Local user'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await profileTap(tester, find.byKey(const ValueKey('profile-logout')));
        expect(find.text('Sign out?'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await profileTap(tester, find.text('Cancel'));
      },
      variant: TargetPlatformVariant({platform}),
    );
  }
}

class FakeProfileMedia implements ProfileMediaPicker {
  String? value;
  @override
  Future<String?> chooseAvatar() async => value;
}

class RecoverableProfileStore extends MemoryProfileStore {
  RecoverableProfileStore({super.value});
  bool failRead = true;
  @override
  Future<String?> read() async {
    if (failRead) throw StateError('Temporary read failure');
    return super.read();
  }
}

class FakeSystemAccess implements SystemAccessService {
  int requests = 0, openedSettings = 0;
  PermissionStatus microphone = PermissionStatus.denied;
  PermissionStatus notifications = PermissionStatus.denied;
  @override
  Future<Map<SystemAccess, PermissionStatus>> read() async => {
    SystemAccess.microphone: microphone,
    SystemAccess.notifications: notifications,
  };
  @override
  Future<void> request(SystemAccess access) async {
    requests++;
    if (access == SystemAccess.microphone) {
      microphone = PermissionStatus.granted;
    } else {
      notifications = PermissionStatus.granted;
    }
  }

  @override
  Future<bool> settings() async {
    openedSettings++;
    return true;
  }
}
