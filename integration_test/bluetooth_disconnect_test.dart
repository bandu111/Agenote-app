import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yanshu/features/meeting/meeting_services.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    '耳机真实断连后停止接纳采样，并禁止静默回退到手机麦克风',
    (tester) async {
      final stage = ValueNotifier('正在启用耳机麦克风，请先保持连接');
      final recorder = DeviceMeetingRecorder(requireBluetooth: true);
      final paths = <String>[];
      var lost = false;
      final report = <String, dynamic>{
        'real_bluetooth_disconnect': true,
        'checks': <String, bool>{},
      };
      void save() => binding.reportData = report;
      final subscription = recorder.states.listen((s) {
        if (s == 'input_lost') lost = true;
      });
      final errors = recorder.transcripts.listen(
        (_) {},
        onError: (Object _) {},
      );
      Future<void> waitFor(Future<bool> Function() ready, int seconds) async {
        final until = DateTime.now().add(Duration(seconds: seconds));
        while (DateTime.now().isBefore(until)) {
          if (await ready()) return;
          await tester.pump(const Duration(milliseconds: 100));
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        fail('等待耳机断开或重新连接超时');
      }

      try {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Center(
                child: ValueListenableBuilder(
                  valueListenable: stage,
                  builder: (_, text, _) => Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(text, style: const TextStyle(fontSize: 24)),
                  ),
                ),
              ),
            ),
          ),
        );
        paths.add(await recorder.start('bluetooth-disconnect-qa'));
        expect(recorder.inputRoute?.bluetooth, isTrue);
        stage.value = '请将两只耳机放回盒内并合上盒盖，等待系统断开连接';
        await waitFor(() async => lost, 60);
        report['after_disconnect'] = recorder.diagnostics;
        expect(recorder.diagnostics['routeLost'], isTrue);
        final samples = recorder.diagnostics['samples'];
        await Future<void>.delayed(const Duration(seconds: 1));
        expect(recorder.diagnostics['samples'], samples);
        report['checks']['disconnect_stops_audio_samples'] = true;
        await expectLater(
          recorder.start('bluetooth-disconnect-qa'),
          throwsStateError,
        );
        report['checks']['no_silent_phone_microphone_fallback'] = true;
        save();
        stage.value = '断连保护已通过。请取出并戴好耳机，等待自动重新连接';
        await waitFor(
          () async =>
              selectMeetingInput(
                await recorder.device.listInputDevices(),
              )?.type.name.startsWith('bluetooth') ==
              true,
          60,
        );
        paths.add(await recorder.start('bluetooth-disconnect-qa'));
        expect(recorder.inputRoute?.bluetooth, isTrue);
        expect(recorder.inputRoute?.verified, isTrue);
        report['checks']['reconnection_uses_verified_bluetooth_input'] = true;
        await Future<void>.delayed(const Duration(seconds: 2));
        await recorder.stop();
        report['after_reconnect'] = recorder.diagnostics;
        report['passed'] = true;
        stage.value = '断连与重连测试完成';
        save();
      } catch (error) {
        report['passed'] = false;
        report['failure_type'] = error.runtimeType.toString();
        save();
        rethrow;
      } finally {
        await recorder.dispose();
        await subscription.cancel();
        await errors.cancel();
        for (final path in paths) {
          for (final name in [path, '$path.capture.json']) {
            final file = File(name);
            if (await file.exists()) await file.delete();
          }
        }
        await tester.pumpWidget(const SizedBox());
        stage.dispose();
      }
    },
    semanticsEnabled: false,
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
