import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';
import 'meeting_models.dart';

abstract interface class MeetingStore {
  Future<List<MeetingRecord>> read();
  Future<void> save(MeetingRecord record);
  Future<void> delete(String id, {String? ownerId});
}

class MemoryMeetingStore implements MeetingStore {
  final Map<String, MeetingRecord> records = {};
  final _deleted = <String>{};
  @override
  Future<List<MeetingRecord>> read() async => records.values.toList();
  @override
  Future<void> save(MeetingRecord record) async {
    if (_deleted.contains('${record.ownerId ?? ''}:${record.id}')) return;
    records[record.id] = record;
  }

  @override
  Future<void> delete(String id, {String? ownerId}) async {
    _deleted.add('${ownerId ?? ''}:$id');
    if (records[id]?.ownerId == ownerId) records.remove(id);
  }
}

class LocalMeetingStore implements MeetingStore {
  LocalMeetingStore({this.directory});
  final Directory? directory;
  Future<void> _queue = Future.value();
  String _deletedName(String id, String? owner) =>
      '.deleted-${sha256.convert(utf8.encode('${owner ?? ''}:$id'))}.flag';
  Future<Directory> _directory() async {
    final root = directory ?? await getApplicationSupportDirectory();
    return Directory('${root.path}/meetings').create(recursive: true);
  }

  @override
  Future<List<MeetingRecord>> read() async {
    final directory = await _directory();
    final entries = await directory.list().toList();
    for (final entity in entries.whereType<File>().where(
      (f) => f.path.endsWith('.json.backup'),
    )) {
      final target = File(entity.path.substring(0, entity.path.length - 7));
      if (!await target.exists()) {
        await entity.rename(target.path);
      }
    }
    final records = <MeetingRecord>[];
    await for (final entity in directory.list()) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      try {
        final record = MeetingRecord.fromJson(
          Map<String, dynamic>.from(jsonDecode(await entity.readAsString())),
        );
        if (await File(
          '${directory.path}/${_deletedName(record.id, record.ownerId)}',
        ).exists()) {
          continue;
        }
        records.add(record);
      } catch (_) {
        // Preserve the original file for recovery; one damaged record must not
        // block unrelated history or the background audio recovery queue.
        continue;
      }
    }
    records.sort((a, b) => b.startedAt.compareTo(a.startedAt));
    return records;
  }

  @override
  Future<void> save(MeetingRecord record) {
    final next = _queue.catchError((Object _) {}).then((_) async {
      final directory = await _directory();
      if (await File(
        '${directory.path}/${_deletedName(record.id, record.ownerId)}',
      ).exists()) {
        return;
      }
      final file = File('${directory.path}/${record.id}.json');
      final temp = File('${file.path}.tmp');
      final backup = File('${file.path}.backup');
      await temp.writeAsString(jsonEncode(record.toJson()), flush: true);
      if (await backup.exists()) await backup.delete();
      if (await file.exists()) await file.rename(backup.path);
      try {
        await temp.rename(file.path);
      } catch (_) {
        if (await backup.exists()) await backup.rename(file.path);
        rethrow;
      }
      if (await backup.exists()) await backup.delete();
    });
    _queue = next;
    return next;
  }

  @override
  Future<void> delete(String id, {String? ownerId}) {
    if (!RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(id)) {
      throw ArgumentError('Invalid meeting id');
    }
    final next = _queue.catchError((Object _) {}).then((_) async {
      final folder = await _directory();
      await File(
        '${folder.path}/${_deletedName(id, ownerId)}',
      ).writeAsString('deleted', flush: true);
      final original = File('${folder.path}/$id.json');
      final backup = File('${original.path}.backup');
      final source = await original.exists() ? original : backup;
      if (await source.exists()) {
        final record = MeetingRecord.fromJson(
          Map<String, dynamic>.from(jsonDecode(await source.readAsString())),
        );
        if (record.ownerId != ownerId) return;
        final root = directory ?? await getApplicationSupportDirectory();
        final allowed = await root.resolveSymbolicLinks();
        for (final path in record.audioPaths.toSet()) {
          final audio = File(path);
          if (!await audio.exists()) continue;
          final resolved = File(await audio.resolveSymbolicLinks());
          final offline =
              resolved.parent.path ==
                  Directory('$allowed/offline-recordings').path &&
              resolved.uri.pathSegments.last == '$id.wav' &&
              id.startsWith('offline-');
          if (!offline &&
              (resolved.parent.path != allowed ||
                  !resolved.uri.pathSegments.last.startsWith('meeting-$id-'))) {
            continue;
          }
          if (offline) {
            final raw = File('${resolved.parent.path}/$id.opus');
            if (await raw.exists()) await raw.delete();
          }
          for (final suffix in [
            '',
            '.capture.json',
            '.capture.json.backup',
            '.asr-progress.json',
            '.asr-progress.json.backup',
          ]) {
            final file = File('$path$suffix');
            if (await file.exists()) await file.delete();
          }
        }
      }
      for (final suffix in ['.json', '.json.backup', '.json.tmp']) {
        final file = File('${folder.path}/$id$suffix');
        if (await file.exists()) await file.delete();
      }
    });
    _queue = next;
    return next;
  }
}
