import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:yanshu/features/recording_device/recorder_device_page.dart';
import 'support/recorder_device_fakes.dart';
import 'package:yanshu/features/recording_device/recorder_device_detail_page.dart';
import 'package:yanshu/features/recording_device/recorder_device_view_model.dart';
import 'package:yanshu/features/recording_device/recorder_models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late DeviceServiceFake sdk;
  late RecorderDeviceViewModel model;
  setUp(() async {
    sdk = DeviceServiceFake();
    model = RecorderDeviceViewModel(
      sdk,
      repository: MemoryRecorderRepository(),
      readyDelay: Duration.zero,
      scanTimeout: const Duration(milliseconds: 60),
      commandTimeout: const Duration(milliseconds: 80),
    );
    await model.initialize();
  });
  tearDown(() => model.dispose());
  void bluetooth({bool authorized = true, bool enabled = true}) =>
      sdk.emit('bluetooth', {'authorized': authorized, 'enabled': enabled});
  Future<void> discover() async {
    bluetooth();
    await model.startScan();
    sdk.emit('discovered', {
      'name': 'SoniNote',
      'productType': 'actual-sdk-value',
    });
  }

  Future<void> connected() async {
    await discover();
    await model.connect(model.devices.single);
    sdk.emit('connection', {'connected': true});
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }

  test('未授权或蓝牙关闭不能扫描，重复初始化只有一次', () async {
    await model.initialize();
    await model.startScan();
    expect(sdk.calls.where((c) => c == 'init').length, 1);
    expect(sdk.calls, isNot(contains('scan')));
    bluetooth(enabled: false);
    await model.startScan();
    expect(sdk.calls, isNot(contains('scan')));
    bluetooth();
    await model.startScan();
    expect(sdk.calls, contains('scan'));
  });
  test('iOS 初始化状态不冒充关闭，回调就绪后清除旧提示并允许扫描', () async {
    sdk.emit('bluetooth', {
      'authorized': true,
      'enabled': false,
      'authorization': 'authorized',
      'state': 'unknown',
    });
    expect(model.bluetoothLabel, '正在确认状态');
    await model.startScan();
    expect(model.error, '蓝牙状态确认中，请稍候重试');
    expect(sdk.calls, isNot(contains('scan')));
    sdk.emit('bluetooth', {
      'authorized': true,
      'enabled': true,
      'authorization': 'authorized',
      'state': 'powered_on',
    });
    expect(model.error, isNull);
    expect(model.bluetoothLabel, '已开启');
    await model.startScan();
    expect(sdk.calls, contains('scan'));
  });
  test('iOS 权限未决定、拒绝、系统限制与关闭分别显示', () async {
    for (final authorization in ['not_determined', 'denied', 'restricted']) {
      sdk.emit('bluetooth', {
        'authorized': false,
        'enabled': false,
        'authorization': authorization,
        'state': 'unauthorized',
      });
      expect(model.bluetoothLabel, '授权后可检测');
      await model.startScan();
      expect(model.error, '请先允许蓝牙权限');
    }
    expect(model.permissionLabel, '系统限制使用');
    bluetooth(enabled: false);
    expect(model.bluetoothLabel, '未开启');
    await model.startScan();
    expect(model.error, '请先开启系统蓝牙');
  });
  test('iOS 未知回调不伪造断连，明确关闭才清理连接', () async {
    await connected();
    sdk.emit('bluetooth', {
      'authorized': true,
      'enabled': false,
      'authorization': 'authorized',
      'state': 'unknown',
    });
    expect(model.connected, true);
    bluetooth(enabled: false);
    expect(model.connected, false);
  });
  test('从系统设置回到前台会重新读取蓝牙授权与开关', () async {
    model.didChangeAppLifecycleState(AppLifecycleState.resumed);
    expect(sdk.calls, contains('status'));
    sdk.emit('bluetooth', {
      'authorized': true,
      'enabled': true,
      'authorization': 'authorized',
      'state': 'powered_on',
    });
    expect(model.permissionLabel, '已允许');
    expect(model.bluetoothLabel, '已开启');
  });
  test('扫描去重并更新同一标识，不伪造连接地址', () async {
    await discover();
    sdk.emit('discovered', {'name': 'SoniNote updated'});
    expect(model.devices.length, 1);
    expect(model.devices.single.id, 'sdk-id');
    expect(model.devices.single.name, 'SoniNote updated');
  });
  test('扫描超时停止，显示无设备说明', () async {
    bluetooth();
    await model.startScan();
    await Future<void>.delayed(const Duration(milliseconds: 70));
    expect(model.scanning, false);
    expect(model.message, contains('未找到'));
  });
  test('连接命令不冒充成功，禁止重复连接，回调后同步时间再查询', () async {
    await discover();
    final device = model.devices.single;
    final a = model.connect(device);
    final b = model.connect(device);
    await Future.wait([a, b]);
    expect(sdk.calls.where((c) => c == 'connect').length, 1);
    expect(model.connection, RecorderConnection.connecting);
    expect(sdk.calls, isNot(contains('info')));
    sdk.emit('connection', {'connected': true});
    await Future<void>.delayed(const Duration(milliseconds: 5));
    expect(model.connected, true);
    expect(sdk.calls.indexOf('syncTime'), lessThan(sdk.calls.indexOf('info')));
  });
  test('连接超时断开且不伪造已断开，收到确认后可重试', () async {
    await discover();
    await model.connect(model.devices.single);
    await Future<void>.delayed(const Duration(milliseconds: 90));
    expect(model.connection, RecorderConnection.disconnecting);
    expect(sdk.calls, contains('disconnect'));
    sdk.emit('connection', {'connected': false});
    expect(model.connection, RecorderConnection.disconnected);
  });
  test('电量正常，110只表示充电，异常值未知', () {
    final info = RecorderInfo();
    info.update('battery', {'cbc': '82'});
    expect(info.battery, 82);
    expect(info.charging, false);
    info.update('battery', {'cbc': 110});
    expect(info.battery, isNull);
    expect(info.charging, true);
    info.update('battery', {'cbc': '-1'});
    expect(info.battery, isNull);
    expect(info.charging, isNull);
  });
  test('容量以KB计算已用比例，零值/缺字段/剩余大于总量安全处理', () {
    final info = RecorderInfo();
    info.update('capacity', {'totalSpace': '2048', 'residueSpace': 1024});
    expect(info.usedKb, 1024);
    expect(info.usage, .5);
    for (final data in [
      {'totalSpace': 0, 'residueSpace': 0},
      {'totalSpace': 10},
      {'totalSpace': 10, 'residueSpace': 11},
      {'totalSpace': 10, 'residueSpace': -1},
    ]) {
      info.update('capacity', data);
      expect(info.usage, isNull);
    }
  });
  test('版本与Code只取真实事件，不把V544写死', () async {
    await connected();
    expect(model.info.firmware, isNull);
    sdk.emit('firmware', {'version': 'V999'});
    sdk.emit('firmware_code', {'versionCode': '999'});
    expect(model.info.firmware, 'V999');
    expect(model.info.firmwareCode, 999);
  });
  test('开始暂停继续停止全部等待回调，停止确认后才显示已保存', () async {
    await connected();
    sdk.emit('recording', {'state': 'idle'});
    await model.startRecording();
    await model.startRecording();
    expect(model.recording, RecorderState.starting);
    expect(sdk.calls.where((c) => c == 'start').length, 1);
    sdk.emit('recording', {'state': 'recording'});
    await model.pauseRecording();
    expect(model.recording, RecorderState.pausing);
    sdk.emit('recording', {'state': 'paused'});
    await model.resumeRecording();
    expect(model.recording, RecorderState.resuming);
    sdk.emit('recording', {'state': 'recording'});
    await model.stopRecording();
    expect(model.recording, RecorderState.stopping);
    expect(model.message, isNull);
    sdk.emit('recording', {'state': 'idle', 'query': true});
    expect(model.recording, RecorderState.stopping); // 旧查询不是保存确认。
    sdk.emit('recording', {'state': 'idle', 'saved': true});
    expect(model.message, contains('已确认停止并保存'));
  });
  test('实体按键事件不重复发送App录音命令，仅状态回调改变录音状态', () async {
    await connected();
    sdk.emit('recording', {'state': 'idle'});
    sdk.emit('button', {'button': '1'});
    expect(model.recording, RecorderState.idle);
    sdk.emit('recording', {'state': 'recording'});
    expect(model.recording, RecorderState.recording);
    sdk.emit('button', {'button': '5'});
    sdk.emit('recording', {'state': 'paused'});
    expect(model.recording, RecorderState.paused);
    expect(sdk.calls, isNot(contains('start')));
    expect(sdk.calls, isNot(contains('pause')));
  });
  test('断线不表示停止，延迟回调不能覆盖新连接与设备信息', () async {
    await connected();
    final old = sdk.epoch;
    sdk.emit('recording', {'state': 'recording'});
    sdk.emit('connection', {'connected': false});
    expect(model.recording, RecorderState.unknown);
    expect(model.message, contains('可能仍在独立录音'));
    await discover();
    await model.connect(model.devices.single);
    sdk.emit('connection', {'connected': true});
    sdk.emit('battery', {'cbc': '99'}, old);
    sdk.emit('recording', {'state': 'idle'}, old);
    expect(model.info.battery, isNull);
    expect(model.recording, RecorderState.unknown);
    sdk.emit('battery', {'cbc': '50'});
    expect(model.info.battery, 50);
  });
  test('命令异常恢复为未知，可查询设备状态后继续操作', () async {
    await connected();
    sdk.emit('recording', {'state': 'idle'});
    sdk.fail = 'start';
    await model.startRecording();
    expect(model.recordingBusy, false);
    expect(model.error, '设备测试失败');
    sdk.fail = null;
    await model.queryRecording();
    sdk.emit('recording', {'state': 'idle'});
    await model.startRecording();
    expect(model.recording, RecorderState.starting);
  });
  test('录音操作超时不会显示成功', () async {
    await connected();
    sdk.emit('recording', {'state': 'idle'});
    await model.startRecording();
    await Future<void>.delayed(const Duration(milliseconds: 90));
    expect(model.recording, RecorderState.unknown);
    expect(model.error, contains('未获设备确认'));
  });
  test('缺失信息查询超时可再次刷新', () async {
    await connected();
    await Future<void>.delayed(const Duration(milliseconds: 90));
    expect(model.refreshing, false);
    expect(model.infoError, isNotNull);
    await model.refreshDeviceInfo();
    expect(model.refreshing, true);
    for (final type in [
      'battery',
      'capacity',
      'firmware',
      'firmware_code',
      'serial',
      'recording',
    ]) {
      sdk.emit(type);
    }
    expect(model.refreshing, false);
  });

  testWidgets('列表没有设备时不自动扫描或申请权限', (tester) async {
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: model,
        child: const MaterialApp(home: RecorderDevicePage()),
      ),
    );
    await tester.pump();
    expect(find.text('我的设备'), findsOneWidget);
    expect(find.text('还没有添加设备'), findsOneWidget);
    expect(sdk.calls, isNot(contains('scan')));
    expect(sdk.calls, isNot(contains('permission')));
  });

  testWidgets('详情展示真实电量版本SN和只读录音状态', (tester) async {
    await tester.runAsync(connected);
    sdk.emit('battery', {'cbc': 110});
    sdk.emit('firmware', {'version': 'V999'});
    sdk.emit('serial', {'sn': 'REAL-1234'});
    sdk.emit('recording', {'state': 'paused'});
    final token = model.beginAdding();
    await tester.runAsync(() => model.addDevice(model.selected!, token));
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: model,
        child: MaterialApp(
          home: RecorderDeviceDetailPage(
            recordId: model.savedDevices.single.recordId,
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('充电中'), findsOneWidget);
    expect(find.text('110%'), findsNothing);
    await tester.scrollUntilVisible(
      find.text('V999'),
      160,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('V999'), findsOneWidget);
    expect(find.text('•••• 1234'), findsOneWidget);
    expect(find.text('已暂停'), findsOneWidget);
    expect(find.text('继续录音'), findsNothing);
    expect(find.text('停止并保存'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
