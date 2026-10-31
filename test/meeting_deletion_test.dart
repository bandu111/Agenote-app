import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:yanshu/features/meeting/meeting_models.dart';
import 'package:yanshu/features/meeting/meeting_store.dart';

void main() {
  test(
    'local deletion removes owned audio and survives restart and delayed saves',
    () async {
      final root = await Directory.systemTemp.createTemp('meeting-delete-');
      addTearDown(() => root.delete(recursive: true));
      final owned = File('${root.path}/meeting-test-1.m4a');
      final external = File('${root.path}/imported.m4a');
      await owned.writeAsBytes([1, 2]);
      await external.writeAsBytes([3, 4]);
      final source = MeetingRecord(
        id: 'test',
        ownerId: 'account',
        startedAt: DateTime(2026),
        demo: false,
        ended: true,
        audioPaths: [owned.path, external.path],
      );
      final store = LocalMeetingStore(directory: root);
      await store.save(source);
      await store.delete(source.id, ownerId: 'account');
      expect(await owned.exists(), false);
      expect(await external.exists(), true);
      final reopened = LocalMeetingStore(directory: root);
      await reopened.save(source);
      expect(await reopened.read(), isEmpty);
    },
  );
  test('local deletion respects account ownership', () async {
    final store = MemoryMeetingStore();
    final source = MeetingRecord(
      id: 'test',
      ownerId: 'first',
      startedAt: DateTime(2026),
      demo: false,
      ended: true,
    );
    await store.save(source);
    await store.delete(source.id, ownerId: 'second');
    expect((await store.read()).single.ownerId, 'first');
  });
}
