import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import '../recording_device/recorder_device_view_model.dart';
import '../recording_device/recorder_models.dart';
import '../recording_device/soninote_device_adapter.dart';

class CardRecording {
  const CardRecording(this.name, this.bytes, this.seconds);
  final String name;
  final int bytes, seconds;
  factory CardRecording.parse(Map value) {
    final name = value['name']?.toString() ?? '';
    final bytes = int.tryParse('${value['size']}') ?? -1;
    final seconds = int.tryParse('${value['time']}') ?? -1;
    if (name.isEmpty ||
        name.length > 200 ||
        bytes <= 0 ||
        bytes > 512 * 1024 * 1024 ||
        seconds < 0) {
      throw const FormatException('录音卡文件信息无效');
    }
    return CardRecording(name, bytes, seconds);
  }
}

/// One SDK transfer at a time; only explicit finish callbacks complete an operation.
class CardFileTransport {
  CardFileTransport(this.device);
  final RecorderDeviceViewModel device;
  bool _busy = false;
  int? _taintedEpoch;
  Future<List<CardRecording>> list() async {
    if (_busy || !device.connected) throw StateError('请连接录音卡并等待当前传输结束');
    _busy = true;
    final epoch = device.connectionEpoch, id = device.selected!.id;
    final result = Completer<List<CardRecording>>();
    final items = <String, CardRecording>{};
    late final StreamSubscription<RecorderEvent> subscription;
    subscription = device.service.events.listen((event) {
      if (result.isCompleted) return;
      if (!device.connected || device.connectionEpoch != epoch) {
        result.completeError(StateError('录音卡已断开'));
        return;
      }
      if (event.epoch != epoch || event.deviceId != id) return;
      try {
        if (event.type == 'files') {
          for (final value
              in jsonDecode(event.data['items'] as String) as List) {
            final item = CardRecording.parse(value as Map);
            items[item.name] = item;
          }
          if ('${event.data['finish']}' == '1') {
            result.complete(items.values.toList());
          }
        } else if (event.type == 'error') {
          result.completeError(StateError('无法读取录音卡文件列表'));
        }
      } catch (e) {
        result.completeError(e);
      }
    });
    try {
      // Install the error handler before a synchronous SDK callback can fail.
      final waiting = result.future.timeout(const Duration(seconds: 30));
      waiting.ignore();
      await SoniNoteDeviceAdapter.method.invokeMethod<void>('listFiles');
      return await waiting;
    } finally {
      await subscription.cancel();
      _busy = false;
    }
  }

  Future<void> download(
    CardRecording recording,
    File target, {
    required bool Function() current,
    required void Function(int) progress,
  }) async {
    if (_busy ||
        !device.connected ||
        device.managementLocked ||
        device.recording != RecorderState.idle) {
      throw StateError('请先停止录音并连接录音卡');
    }
    if (_taintedEpoch == device.connectionEpoch) {
      throw StateError("上次传输已中断，请重新连接录音卡后续传");
    }
    _busy = true;
    final epoch = device.connectionEpoch, id = device.selected!.id;
    final result = Completer<void>();
    late final RandomAccessFile output;
    try {
      await target.parent.create(recursive: true);
      output = await target.open(mode: FileMode.append);
    } catch (_) {
      _busy = false;
      rethrow;
    }
    var count = await output.length();
    Timer? timer;
    void fail(Object error) {
      if (!result.isCompleted) result.completeError(error);
    }

    void resetTimeout() {
      timer?.cancel();
      timer = Timer(
        const Duration(seconds: 30),
        () => fail(StateError('录音卡传输超时，已保留下载进度')),
      );
    }

    final subscription = device.service.events.listen((event) {
      if (result.isCompleted) return;
      if (!current() || !device.connected || device.connectionEpoch != epoch) {
        fail(StateError('同步已暂停，下载进度保留'));
        return;
      }
      if (event.epoch != epoch || event.deviceId != id) return;
      try {
        if (event.type == 'file_bytes') {
          final data = event.data['bytes'];
          if (data is! Uint8List || count + data.length > recording.bytes) {
            throw StateError('录音卡文件长度异常');
          }
          output.writeFromSync(
            data,
          ); // Bounded SDK packets, never buffers a whole recording.
          count += data.length;
          resetTimeout();
          progress(count);
        } else if (event.type == 'file_state') {
          final name = event.data['name'];
          if (name != null && name != '' && name != recording.name) return;
          final state = '${event.data['state']}';
          if (state == '0') {
            if (count != recording.bytes) throw StateError('录音卡文件不完整，请重试');
            result.complete();
          } else if (state != '4') {
            throw StateError('录音卡传输未完成（$state），可重新同步');
          }
        } else if (event.type == 'error') {
          throw StateError('录音卡传输失败');
        }
      } catch (e) {
        fail(e);
      }
    });
    final cancel = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (!current() ||
          !device.connected ||
          device.connectionEpoch != epoch ||
          device.recording != RecorderState.idle) {
        fail(StateError('同步已暂停，录音保留'));
      }
    });
    try {
      if (count > recording.bytes) throw StateError('本机下载文件大小异常');
      if (count == recording.bytes) return;
      final waiting = result.future;
      waiting.ignore();
      resetTimeout();
      await SoniNoteDeviceAdapter.method.invokeMethod<void>('downloadFile', {
        'name': recording.name,
        'offset': count,
      });
      await waiting;
      await output.flush();
    } catch (_) {
      _taintedEpoch = epoch;
      rethrow;
    } finally {
      timer?.cancel();
      cancel.cancel();
      await subscription.cancel();
      await output.close();
      // Do not advance to another file after an unacknowledged stop in the same connection.
      if (!result.isCompleted || count != recording.bytes) {
        try {
          await SoniNoteDeviceAdapter.method.invokeMethod<void>(
            'stopDownload',
            {'name': recording.name},
          );
        } catch (_) {}
      }
      _busy = false;
    }
  }
}
