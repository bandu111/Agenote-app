import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:record/record.dart';
import 'package:yanshu/features/meeting/pcm_audio.dart';
import 'package:yanshu/features/meeting/meeting_services.dart';

void main() {
  test('不规则及奇数字节分包重组后与原始PCM逐字节一致，暂停尾帧也保留', () {
    final input = Uint8List.fromList(List.generate(17039 * 2, (i) => i % 251));
    final buffer = MeetingPcmBuffer();
    final output = BytesBuilder();
    var offset = 0;
    for (final length in [1, 17, 3199, 7001, 3, 6023, 6]) {
      for (final frame in buffer.add(
        Uint8List.sublistView(input, offset, offset + length),
      )) {
        expect(frame.length, 3200);
        output.add(frame);
      }
      offset += length;
    }
    output.add(buffer.finish());
    for (final frame in buffer.add(Uint8List.sublistView(input, offset))) {
      output.add(frame);
    }
    output.add(buffer.finish());
    expect(output.takeBytes(), input);
    expect(buffer.samples, 17039);
    expect(buffer.duration.inMicroseconds, 17039 * 1000000 ~/ 16000);
  });

  test('真正的末尾缺字节明确报错，不制造新采样', () {
    final buffer = MeetingPcmBuffer()..add(Uint8List.fromList([1, 2, 3]));
    expect(buffer.finish, throwsFormatException);
    expect(buffer.samples, 0);
  });

  test('统计削波与能量，不改变波形或插入静音', () {
    final data = ByteData(8)
      ..setInt16(0, -32768, Endian.little)
      ..setInt16(2, 0, Endian.little)
      ..setInt16(4, 32767, Endian.little)
      ..setInt16(6, 16384, Endian.little);
    final buffer = MeetingPcmBuffer()..add(data.buffer.asUint8List());
    expect(buffer.finish(), data.buffer.asUint8List());
    expect(buffer.diagnostics['clippedFraction'], 0.5);
    expect(buffer.diagnostics['zeroFraction'], 0.25);
    expect(buffer.rms, closeTo(0.75, 0.0001));
  });

  test('选蓝牙麦克风而不是A2DP播放端口；后续USB设备复用同一接口', () {
    const phone = InputDevice(
      id: '1',
      label: '手机',
      type: InputDeviceType.builtIn,
    );
    const a2dp = InputDevice(
      id: '2',
      label: '耳机播放',
      type: InputDeviceType.bluetoothA2dp,
    );
    const sco = InputDevice(
      id: '3',
      label: '耳机麦克风',
      type: InputDeviceType.bluetoothSco,
    );
    const usb = InputDevice(
      id: '4',
      label: 'USB录音设备',
      type: InputDeviceType.usb,
    );
    expect(selectMeetingInput([phone, a2dp, sco, usb]), sco);
    expect(selectMeetingInput([phone, a2dp, usb]), usb);
    expect(selectMeetingInput([phone, a2dp]), phone);
    expect(selectMeetingInput([a2dp]), isNull);
    expect(
      selectMeetingInput([
        phone,
        sco,
      ], preference: MeetingInputPreference.phone),
      phone,
    );
    expect(
      selectMeetingInput([
        phone,
        sco,
      ], preference: MeetingInputPreference.bluetooth),
      sco,
    );
    expect(
      selectMeetingInput([
        phone,
        a2dp,
      ], preference: MeetingInputPreference.bluetooth),
      isNull,
    );
    expect(
      selectMeetingInput([sco], preference: MeetingInputPreference.phone),
      isNull,
    );
  });
}
