import '../knowledge/repositories/knowledge_importer.dart';
import 'wav_import.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:opus_dart/opus_dart.dart';
import '../meeting/meeting_models.dart';
import '../meeting/meeting_view_model.dart';
import '../meeting/local_speech.dart' show meetingWavHeader;
import '../meeting/meeting_remote.dart';
import '../recording_device/recorder_device_view_model.dart';
import '../recording_device/soninote_pcm_input.dart';
import 'card_file_transport.dart';

String offlineRecordingId(String owner, String device, String name, int size) =>
    'offline-${sha256.convert(utf8.encode(jsonEncode([owner, device, name, size]))).toString().substring(0, 40)}';

class OfflineRecording {
  OfflineRecording({
    required this.id,
    required this.name,
    required this.deviceId,
    required this.size,
    required this.seconds,
    required this.startedAt,
    this.meetingId,
    this.alias,
    this.category = '会议录音',
    this.note = '',
    this.localPath,
    this.documentId,
    this.fileType = '录音',
    this.state = 'waiting',
    this.excluded = false,
    this.hidden = false,
    this.error,
  });
  final String id, name, deviceId;
  final int size, seconds;
  final DateTime startedAt;
  String? meetingId, error, alias, localPath, documentId;
  String category, note;
  final String fileType;
  String get displayName => alias ?? name;
  String state;
  bool excluded, hidden;
  double progress = 0;
  bool get complete => state == 'complete';
  bool get serverQueued => const {
    'processing',
    'queued',
    'recognizing',
    'archiving',
  }.contains(state);
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'deviceId': deviceId,
    'size': size,
    'seconds': seconds,
    'startedAt': startedAt.toIso8601String(),
    'meetingId': meetingId,
    'alias': alias,
    'category': category,
    'note': note,
    'localPath': localPath,
    'documentId': documentId,
    'fileType': fileType,
    'state': state,
    'excluded': excluded,
    'hidden': hidden,
    'error': error,
  };
  factory OfflineRecording.fromJson(Map j) => OfflineRecording(
    id: j['id'],
    name: j['name'],
    deviceId: j['deviceId'],
    size: j['size'],
    seconds: j['seconds'],
    startedAt: DateTime.parse(j['startedAt']),
    meetingId: j['meetingId'],
    alias: j['alias'],
    category: j['category'] ?? '会议录音',
    note: j['note'] ?? '',
    localPath: j['localPath'],
    documentId: j['documentId'],
    fileType: j['fileType'] ?? '录音',
    state:
        const {
          'complete',
        }.contains(j['state'])
        ? j['state']
        : 'waiting',
    excluded: j['excluded'] == true,
    hidden: j['hidden'] == true,
  );
}

/// Account-scoped durable opt-in queue. Never deletes the original card recording.
class OfflineRecordingsModel extends ChangeNotifier
    with WidgetsBindingObserver {
  OfflineRecordingsModel(
    this.device,
    this.meeting, {
    FlutterSecureStorage? storage,
    this.directory,
  }) : storage = storage ?? const FlutterSecureStorage(),
       transport = CardFileTransport(device) {
    WidgetsBinding.instance.addObserver(this);
    device.addListener(_deviceChanged);
    _poll = Timer.periodic(const Duration(seconds: 10), (_) {
      unawaited(refreshLocal());
    });
  }
  final RecorderDeviceViewModel device;
  final MeetingViewModel meeting;
  final FlutterSecureStorage storage;
  final Directory? directory;
  final CardFileTransport transport;
  List<OfflineRecording> items = [];
  bool importing = false;
  bool loading = false, running = false, autoSync = false;
  String? error, _owner, _connection;
  bool _ready = false;
  bool _disposed = false, _foreground = true, _readingLocal = false;
  int _generation = 0;
  Timer? _poll;
  Future<void> _writes = Future.value();
  Future<void> _loadingAccount = Future.value();
  int get pending =>
      items.where((r) => !r.complete && !r.excluded && !r.hidden).length;
  void _emit() {
    if (!_disposed) notifyListeners();
  }

  String get _key =>
      'agenote.offline_recordings.v1.${sha256.convert(utf8.encode(_owner ?? ""))}';
  String get _deviceId => '${device.platform}:${device.selected?.id}';
  String label(OfflineRecording item) => switch (item.state) {
    'downloading' => '下载中',
    'decoding' => '整理录音',
    'uploading' => '上传中',
    'complete' => '已完成',
    'failed' => '同步失败',
    _ => item.excluded ? '不上传' : '待同步',
  };
  void refreshAccount() {
    final owner = meeting.remote?.accountId;
    if (_owner == owner) return;
    _ready = false;
    _owner = owner;
    _generation++;
    _connection = null;
    items = [];
    error = null;
    autoSync = false;
    final generation = _generation;
    _emit();
    _loadingAccount = () async {
      if (owner == null) return;
      try {
        final raw = await storage.read(key: _key);
        if (generation != _generation || _disposed) return;
        if (raw != null) {
          final j = jsonDecode(raw) as Map;
          items = (j['items'] as List)
              .map((v) => OfflineRecording.fromJson(v as Map))
              .toList();
          autoSync = j['autoSync'] == true;
        }
        _ready = true;
        await refreshLocal();

        _deviceChanged();
      } catch (_) {
        if (generation == _generation) error = '无法读取离线同步记录，请重试';
      }
      _emit();
    }();
  }

  Future<void> _save() {
    if (!_ready) throw StateError("同步记录未能加载，未覆盖原数据");
    final key = _key;
    final value = jsonEncode({
      'items': items.map((r) => r.toJson()).toList(),
      'autoSync': autoSync,
    });
    final next = _writes
        .catchError((Object _) {})
        .then((_) => storage.write(key: key, value: value));
    _writes = next;
    return next;
  }

  Future<void> setAutoSync(bool value) async {
    autoSync = value;
    await _save();
    _emit();
    if (value && _foreground && device.connected) unawaited(sync());
  }

  /// Snapshot only the current card entries. New files keep distinct identities.
  Future<void> ignoreExistingCardRecordings() async {
    if (running || loading || !_ready) return;
    final affected = items
        .where((r) => r.deviceId != 'phone' && !r.complete && !r.hidden)
        .toList();
    for (final item in affected) {
      item.hidden = true;
      item.excluded = true;
    }
    try {
      await _save();
    } catch (_) {
      for (final item in affected) {
        item.hidden = false;
        item.excluded = false;
      }
      rethrow;
    }
    _emit();
  }

  Future<void> setExcluded(OfflineRecording item, bool value) async {
    if (running) return;
    item.excluded = value;
    await _save();
    _emit();
  }

  void _deviceChanged() {
    if (_disposed || !_ready || _owner == null) return;
    final connection = device.connected
        ? '${device.selected?.id}:${device.connectionEpoch}'
        : null;
    if (_connection == connection) return;
    _connection = connection;
    if (connection != null) unawaited(refreshCard());
  }

  Future<void> refreshLocal() async {
    if (!_ready || _owner == null || running || _readingLocal) return;
    _readingLocal = true;
    final owner = _owner, generation = _generation;
    try {
      final records = await meeting.store.read();
      if (generation != _generation) return;
      var changed = false;
      for (final record in records.where(
        (r) =>
            r.ownerId == owner &&
            r.ended &&
            r.offlineSyncHeld &&
            r.audioPaths.isNotEmpty,
      )) {
        if (items.any((r) => r.meetingId == record.id)) continue;
        items.add(
          OfflineRecording(
            id: record.id,
            name: record.title,
            deviceId: 'phone',
            size: 0,
            seconds: record.elapsed.inSeconds,
            startedAt: record.startedAt,
            meetingId: record.id,
          ),
        );
        changed = true;
      }
      if (changed) {
        await _save();
        _emit();
      }
    } catch (_) {
      error = '无法读取本机离线录音';
      _emit();
    } finally {
      _readingLocal = false;
    }
  }

  Future<void> refreshCard() async {
    if (!_ready || loading || running || _owner == null || !device.connected) {
      return;
    }
    loading = true;
    error = null;
    _emit();
    final generation = _generation, owner = _owner!, deviceId = _deviceId;
    try {
      final files = await transport.list();
      if (generation != _generation) return;
      final existingMeetings = await meeting.store.read();
      if (generation != _generation) return;
      for (final file in files) {
        if (existingMeetings.any(
          (r) =>
              r.ownerId == owner &&
              r.recordingCardFileName == file.name &&
              r.recordingCardIdentity == deviceId,
        )) {
          continue;
        }
        final id = offlineRecordingId(owner, deviceId, file.name, file.bytes);
        if (items.any((r) => r.id == id)) continue;
        final stamp = RegExp(
          r'(20\d{2})[-_]?([01]\d)[-_]?([0-3]\d)[-_]?([0-2]\d)[-_]?([0-5]\d)[-_]?([0-5]\d)',
        ).firstMatch(file.name);
        final started = stamp == null
            ? DateTime.now()
            : DateTime(
                int.parse(stamp[1]!),
                int.parse(stamp[2]!),
                int.parse(stamp[3]!),
                int.parse(stamp[4]!),
                int.parse(stamp[5]!),
                int.parse(stamp[6]!),
              );
        items.add(
          OfflineRecording(
            id: id,
            name: file.name,
            deviceId: deviceId,
            size: file.bytes,
            seconds: file.seconds,
            startedAt: started,
          ),
        );
      }
      await _save();
    } catch (e) {
      if (generation == _generation) error = '读取录音卡文件失败：$e';
    } finally {
      loading = false;
      if (generation != _generation && !_disposed) {
        _connection = null;
        _deviceChanged();
      }
      _emit();
    }
    if (autoSync && error == null && _foreground) unawaited(sync());
  }

  Future<void> importWav(File file, String name) async {
    await _loadingAccount;
    if (!_ready || _owner == null) throw StateError('请登录后导入音频');
    if (running) throw StateError('请等待当前同步结束后导入');
    if (importing) throw StateError('正在导入音频，请稍候');
    importing = true;
    _emit();
    try {
      final owner = _owner!, generation = _generation;
      final info = await inspectWav(file);
      final hash = await sha256.bind(file.openRead()).first;
      if (_disposed || generation != _generation) throw StateError('账户已切换');
      final id = offlineRecordingId(
        owner,
        'import',
        hash.toString(),
        await file.length(),
      );
      if (items.any((r) => r.id == id)) return;
      final root = await _root();
      final original = File('${root.path}/$id.original.wav');
      final normalized = File('${root.path}/$id.wav');
      await file.copy(original.path);
      await normalizeWav(original, normalized);
      if (_disposed || generation != _generation) {
        throw StateError('账户已切换，未提交导入');
      }
      final record = MeetingRecord(
        id: id,
        ownerId: owner,
        title: name.replaceFirst(RegExp(r'\.wav$', caseSensitive: false), ''),
        startedAt: DateTime.now(),
        demo: false,
        ended: true,
        elapsed: info.duration,
        audioPaths: [normalized.path],
        cloudAudioEnabled: true,
        recoveryPendingSync: true,
        offlineSyncHeld: true,
      );
      await meeting.store.save(record);
      if (_disposed || generation != _generation) {
        throw StateError('账户已切换，录音未上传');
      }
      items.add(
        OfflineRecording(
          id: id,
          name: name,
          deviceId: 'phone',
          size: await original.length(),
          seconds: info.duration.inSeconds,
          startedAt: record.startedAt,
          meetingId: id,
        ),
      );
      await _save();
      _emit();
    } finally {
      importing = false;
      _emit();
    }
  }

  Future<void> updateInfo(
    OfflineRecording item,
    String name,
    String category,
    String note,
  ) async {
    if (running || !_ready || !items.contains(item)) {
      throw StateError('请等待传输结束后编辑');
    }
    final value = name.trim();
    if (value.isEmpty || value.length > 120 || note.length > 200) {
      throw const FormatException('文件名需为 1–120 个字，备注最多 200 个字');
    }
    final old = (item.alias, item.category, item.note);
    item.alias = value;
    item.category = category;
    item.note = note;
    try {
      await _save();
    } catch (_) {
      item.alias = old.$1;
      item.category = old.$2;
      item.note = old.$3;
      rethrow;
    }
    _emit();
  }

  Future<void> removeRecord(OfflineRecording item) async {
    if (running || !_ready || !items.contains(item)) {
      throw StateError('请等待传输结束后删除');
    }
    item.hidden = true;
    try {
      await _save();
    } catch (_) {
      item.hidden = false;
      rethrow;
    }
    _emit();
  }

  Future<void> importDocument(File file, String name) async {
    await _loadingAccount;
    if (!_ready || _owner == null || running || importing) {
      throw StateError('请登录并等待当前传输结束');
    }
    importing = true;
    _emit();
    try {
      final generation = _generation, owner = _owner!;
      final size = await file.length();
      if (size > maxKnowledgeFileBytes) {
        throw const FormatException('文档请控制在 20 MB 以内');
      }
      decodeKnowledgeImport(name, await file.readAsBytes());
      final hash = await sha256.bind(file.openRead()).first;
      final id = offlineRecordingId(owner, 'document', hash.toString(), size);
      if (items.any((r) => r.id == id && !r.hidden)) return;
      final root = await _root();
      final target = await file.copy('${root.path}/$id.document');
      if (generation != _generation || _disposed) throw StateError('账户已切换');
      final existing = items.where((r) => r.id == id).firstOrNull;
      if (existing != null) {
        existing.hidden = false;
      } else {
        items.add(
          OfflineRecording(
            id: id,
            name: name,
            deviceId: 'phone',
            size: size,
            seconds: 0,
            startedAt: DateTime.now(),
            fileType: '文档',
            category: '未分类',
            localPath: target.path,
          ),
        );
      }
      await _save();
    } finally {
      importing = false;
      _emit();
    }
  }

  Future<void> _uploadDocument(
    OfflineRecording item,
    bool Function() current,
  ) async {
    if (!current()) throw StateError('传输已暂停');
    final local = File(item.localPath!);
    final imported = decodeKnowledgeImport(
      item.name,
      await local.readAsBytes(),
    );
    if (!current()) throw StateError('传输已暂停');
    item.state = 'uploading';
    item.error = null;
    _emit();
    final id = await meeting.knowledge.addDocument(
      title: item.displayName,
      content: imported.content,
      folderId: 'inbox',
      projectId: 'personal',
      kind: imported.kind,
      filename: imported.filename,
      fileData: imported.fileData,
      fileHash: imported.fileHash,
      tags: [item.category],
    );
    if (!current()) throw StateError('账户或会话已变化，请核对知识库后重试');
    if (id == null) throw StateError(meeting.knowledge.actionError ?? '文档上传失败');
    item.documentId = id;
    item.state = 'complete';
    item.progress = 1;
    await _save();
    _emit();
  }

  Future<Directory> _root() async =>
      (directory ??
              Directory(
                '${(await getApplicationSupportDirectory()).path}/offline-recordings',
              ))
          .create(recursive: true);
  bool _current(int generation, String owner) =>
      !_disposed &&
      _foreground &&
      generation == _generation &&
      meeting.remote?.accountId == owner &&
      !meeting.active &&
      !meeting.busy;
  Future<void> pause() async {
    _generation++;
    _emit();
  }

  Future<void> sync({Set<String>? selected}) async {
    await _loadingAccount;
    if (!_ready || running || loading || _owner == null) return;
    if (meeting.active || meeting.busy) {
      error = '请在当前会议结束后同步';
      _emit();
      return;
    }
    final remote = meeting.remote;
    if (remote == null) {
      error = '请登录云端账户后同步';
      _emit();
      return;
    }
    final generation = _generation, owner = _owner!;
    final batch = items
        .where(
          (r) =>
              !r.complete &&
              !r.excluded &&
              !r.hidden &&
              !r.serverQueued &&
              (selected == null || selected.contains(r.id)),
        )
        .toList();
    running = true;
    error = null;
    _emit();
    try {
      for (final item in batch) {
        if (!_current(generation, owner)) break;
        bool current() => _current(generation, owner);
        try {
          if (item.fileType != '录音') {
            await _uploadDocument(item, current);
            continue;
          }
          var record = (await meeting.store.read())
              .where((r) => r.id == item.meetingId && r.ownerId == owner)
              .firstOrNull;
          if (!current()) throw StateError('同步已暂停');
          void stage(String value) {
            item.state = value;
            item.error = null;
            _emit();
          }

          if (record == null) {
            final root = await _root();
            final raw = File('${root.path}/${item.id}.opus');
            final wav = File('${root.path}/${item.id}.wav');
            if (!await wav.exists()) {
              if (!device.connected || _deviceId != item.deviceId) {
                throw StateError('请连接这段录音所属的设备');
              }
              stage('downloading');
              var last = DateTime.now();
              await transport.download(
                CardRecording(item.name, item.size, item.seconds),
                raw,
                current: current,
                progress: (bytes) {
                  item.progress = bytes / item.size;
                  if (DateTime.now().difference(last).inMilliseconds > 150) {
                    last = DateTime.now();
                    _emit();
                  }
                },
              );
              stage('decoding');
              await decodeCardRecording(raw, wav, current);
            }
            if (!current()) throw StateError('同步已暂停');
            final duration = Duration(
              microseconds: ((await wav.length()) - 44) * 1000000 ~/ 32000,
            );
            record = MeetingRecord(
              id: item.id,
              ownerId: owner,
              title: '离线录音',
              startedAt: item.startedAt,
              demo: false,
              ended: true,
              elapsed: duration,
              audioPaths: [wav.path],
              cloudAudioEnabled: true,
              recoveryPendingSync: true,
              offlineSyncHeld: true,
            );
            item.meetingId = record.id;
            await meeting.store.save(record);
            await _save();
          }
          if (remote is! CancelableMeetingAudioRemote) {
            throw StateError('云端未配置录音上传');
          }
          if (!current()) throw StateError('同步已暂停');
          stage('uploading');
          await remote.sync(record, paused: false);
          if (!current()) throw StateError('同步已暂停');
          await (remote as CancelableMeetingAudioRemote).uploadAudioCancelable(
            record,
            current,
          );
          if (!current()) throw StateError('同步已暂停');
          item.state = 'complete';
          item.error = null;
          item.progress = 1;
          await meeting.store.save(
            MeetingRecord.fromJson({
              ...record.toJson(),
              'cloudAudioUploaded': true,
              'recoveryPendingSync': false,
              'offlineSyncHeld': true,
            }),
          );
          await _save();
          _emit();
          await meeting.knowledge.load();
          await meeting.onProgressChanged?.call();
        } catch (e) {
          item.state = 'failed';
          item.error = '$e';
          if (generation == _generation) {
            await _save();
            _emit();
          }
        }
      }
    } finally {
      if (!_disposed && _owner == owner) {
        for (final item in batch.where(
          (r) => !r.complete && !r.serverQueued && r.state != 'failed',
        )) {
          item.state = 'waiting';
        }
        await _save();
      }
      running = false;
      _emit();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (!_foreground) _generation++;
    if (_foreground) {
      unawaited(refreshLocal());
      _deviceChanged();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _poll?.cancel();
    device.removeListener(_deviceChanged);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}

Future<void> decodeCardRecording(
  File input,
  File output,
  bool Function() current,
) async {
  await SoniNotePcmInput.loadOpus();
  final decoder = SimpleOpusDecoder(sampleRate: 16000, channels: 1);
  final framer = SoniNoteOpusFramer();
  final temp = File('${output.path}.tmp');
  final writer = await temp.open(mode: FileMode.write);
  var bytes = 0;
  try {
    await writer.writeFrom(meetingWavHeader(0));
    await for (final chunk in input.openRead()) {
      if (!current()) throw StateError('音频整理已暂停');
      for (final packet in framer.add(Uint8List.fromList(chunk))) {
        final samples = decoder.decode(input: packet);
        if (samples.isEmpty) throw const FormatException('录音卡音频解码失败');
        final pcm = Uint8List(samples.length * 2);
        final view = ByteData.sublistView(pcm);
        for (var i = 0; i < samples.length; i++) {
          view.setInt16(i * 2, samples[i], Endian.little);
        }
        await writer.writeFrom(pcm);
        bytes += pcm.length;
      }
    }
    if (framer.remainingBytes != 0 || bytes == 0) {
      throw const FormatException('不支持的录音卡文件格式，原文件已保留');
    }
    await writer.setPosition(0);
    await writer.writeFrom(meetingWavHeader(bytes));
    await writer.flush();
  } finally {
    decoder.destroy();
    await writer.close();
  }
  await temp.rename(output.path);
}
