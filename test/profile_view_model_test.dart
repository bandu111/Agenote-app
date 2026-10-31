import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yanshu/features/profile/repositories/profile_repository.dart';
import 'package:yanshu/features/profile/viewmodels/profile_view_model.dart';

Future<ProfileViewModel> profileModel(ProfileStore store) async {
  final vm = ProfileViewModel(repository: ProfileRepository(store));
  await vm.load();
  return vm;
}

void main() {
  test(
    'personal data, preferences and local sign-out persist across restarts',
    () async {
      final store = MemoryProfileStore();
      final vm = await profileModel(store);
      addTearDown(vm.dispose);
      expect(vm.ready, isTrue);
      expect(
        await vm.updatePersonal(
          name: '林言',
          job: '产品经理',
          company: 'YanShu',
          email: 'lin@example.com',
          phone: '+86 123',
        ),
        isTrue,
      );
      expect(await vm.setLanguage('en'), isTrue);
      expect(await vm.setAppearance('dark'), isTrue);
      expect(await vm.setHapticFeedback(false), isTrue);
      expect(await vm.setBackgroundNotifications(true), isTrue);
      expect(await vm.signOut(), isTrue);
      await ProfileRepository(store).save(vm.data);
      final fresh = await profileModel(store);
      addTearDown(fresh.dispose);
      expect(fresh.data.name, '林言');
      expect(fresh.data.company, 'YanShu');
      expect(fresh.data.hapticFeedback, isFalse);
      expect(fresh.data.backgroundNotifications, isTrue);
      expect(fresh.locale, const Locale('en'));
      expect(fresh.themeMode, ThemeMode.dark);
      expect(fresh.data.sessionActive, isFalse);
      final id = fresh.data.accountId;
      expect(await fresh.resumeLocalAccount(), isTrue);
      expect(fresh.data.accountId, id);
      expect(fresh.data.name, '林言');
      expect(await fresh.setLanguage('system'), isTrue);
      expect(fresh.locale, isNull);
    },
  );
  test(
    'invalid profile fields, images and unsupported preferences never overwrite data',
    () async {
      final store = MemoryProfileStore();
      final vm = await profileModel(store);
      addTearDown(vm.dispose);
      final before = vm.data.toJson();
      final beforeRaw = store.value;
      expect(
        await vm.updatePersonal(
          name: '',
          job: '',
          company: '',
          email: '',
          phone: '',
        ),
        isFalse,
      );
      expect(
        await vm.updatePersonal(
          name: 'Lin',
          job: '',
          company: '',
          email: 'invalid',
          phone: '',
        ),
        isFalse,
      );
      expect(
        await vm.updatePersonal(
          name: 'Lin',
          job: '',
          company: '',
          email: '',
          phone: '',
          avatar: 'not an image',
        ),
        isFalse,
      );
      expect(await vm.setLanguage('bad'), isFalse);
      expect(await vm.setAppearance('bad'), isFalse);
      expect(vm.data.toJson(), before);
      expect(store.value, beforeRaw);
    },
  );
  test(
    'save failures do not claim successful changes and corrupt files are not overwritten',
    () async {
      final store = FailingProfileStore();
      final failing = ProfileViewModel(repository: ProfileRepository(store));
      addTearDown(failing.dispose);
      await failing.load();
      store.failWrite = true;
      expect(await failing.setAppearance('dark'), isFalse);
      expect(failing.data.appearance, 'system');
      expect(failing.error, isNotNull);
      store.failWrite = false;
      expect(await failing.setAppearance('dark'), isTrue);
      final corrupt = MemoryProfileStore(value: '{bad json');
      final broken = await profileModel(corrupt);
      addTearDown(broken.dispose);
      expect(broken.ready, isFalse);
      expect(broken.error, isNotNull);
      expect(await broken.signOut(), isFalse);
      expect(corrupt.value, '{bad json');
    },
  );
  test(
    'real local profile file survives restart and does not keep old personal backups',
    () async {
      final dir = await Directory.systemTemp.createTemp('yanshu-profile-test-');
      addTearDown(() => dir.delete(recursive: true));
      final store = LocalProfileStore(directory: dir),
          vm = await profileModel(LocalProfileStore(directory: dir));
      addTearDown(vm.dispose);
      await vm.updatePersonal(
        name: 'Lin',
        job: '',
        company: '',
        email: 'lin@example.com',
        phone: '123',
      );
      final fresh = await profileModel(store);
      addTearDown(fresh.dispose);
      expect(fresh.data.email, 'lin@example.com');
      expect((await dir.list().toList()).length, 1);
      expect(jsonDecode((await store.read())!)['name'], 'Lin');
    },
  );
}

class FailingProfileStore extends MemoryProfileStore {
  bool failWrite = false;
  @override
  Future<void> write(String value) async {
    if (failWrite) throw const FileSystemException('write');
    return super.write(value);
  }
}
