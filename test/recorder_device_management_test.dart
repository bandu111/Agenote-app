import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:yanshu/app/theme/app_theme.dart';
import 'package:yanshu/app/router/app_router.dart';
import 'package:yanshu/features/recording_device/recorder_device_page.dart';
import 'package:yanshu/features/recording_device/recorder_device_detail_page.dart';
import 'package:yanshu/features/recording_device/recorder_device_view_model.dart';
import 'package:yanshu/features/recording_device/recorder_models.dart';
import 'support/recorder_device_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late DeviceServiceFake sdk;
  late MemoryRecorderRepository repository;
  late RecorderDeviceViewModel model;
  Future<void> tick() => Future<void>.delayed(Duration.zero);
  setUp(() async {
    sdk = DeviceServiceFake();
    repository = MemoryRecorderRepository();
    model = RecorderDeviceViewModel(
      sdk,
      repository: repository,
      readyDelay: Duration.zero,
      scanTimeout: const Duration(milliseconds: 150),
      commandTimeout: const Duration(milliseconds: 180),
    );
    await model.initialize();
    sdk.emit('bluetooth', {'authorized': true, 'enabled': true});
  });
  tearDown(() => model.dispose());
  Future<RecorderDevice> discover([String id = 'sdk-id']) async {
    sdk.id = id;
    await model.startScan();
    sdk.emit('discovered', {'name': 'CB08'});
    return model.devices.single;
  }

  Future<bool> add([String id = 'sdk-id', String? serial]) async {
    final token = model.beginAdding();
    final device = await discover(id);
    final result = model.addDevice(device, token);
    await tick();
    sdk.emit('connection', {'connected': true});
    if (serial != null) sdk.emit('serial', {'sn': serial});
    return result;
  }

  Future<void> disconnect() async {
    await model.disconnect();
    sdk.emit('connection', {'connected': false});
    await tick();
  }

  Future<void> useInteractiveTimeouts() async {
    model.dispose();
    sdk = DeviceServiceFake();
    repository = MemoryRecorderRepository();
    model = RecorderDeviceViewModel(
      sdk,
      repository: repository,
      readyDelay: Duration.zero,
      scanTimeout: const Duration(seconds: 10),
      commandTimeout: const Duration(seconds: 10),
    );
    await model.initialize();
    sdk.emit('bluetooth', {'authorized': true, 'enabled': true});
  }

  void completeDeviceInfo() {
    sdk.emit('battery', {'cbc': 80});
    sdk.emit('capacity', {'totalSpace': 2048, 'residueSpace': 1024});
    sdk.emit('firmware', {'version': '544'});
    sdk.emit('firmware_code', {'versionCode': 544});
    sdk.emit('serial', {'sn': 'test-serial'});
    sdk.emit('recording', {'state': 'idle'});
  }

  test('设备名称保存在本机，更新信息后仍保留，旧记录默认 AI Voice', () async {
    await add();
    final record = model.savedDevices.single;
    expect(record.displayName, 'AI Voice');
    expect(await model.renameDevice(record.recordId, '  会议录音卡  '), isTrue);
    expect(model.savedDevices.single.displayName, '会议录音卡');
    final persisted = SavedRecorderDevice.fromJson(
      model.savedDevices.single.toJson(),
    );
    expect(persisted.withInfo(RecorderInfo()).displayName, '会议录音卡');
    expect(await model.renameDevice(record.recordId, '  '), isFalse);
    expect(model.savedDevices.single.displayName, '会议录音卡');
  });

  test('发现、连接、持久化分别完成，写盘前不显示已添加', () async {
    repository.writeGate = Completer<void>();
    final token = model.beginAdding();
    final device = await discover();
    expect(model.savedDevices, isEmpty);
    final adding = model.addDevice(device, token);
    await tick();
    expect(model.savedDevices, isEmpty);
    sdk.emit('connection', {'connected': true});
    await tick();
    expect(model.connected, true);
    expect(model.saving, true);
    expect(model.savedDevices, isEmpty);
    repository.writeGate!.complete();
    expect(await adding, true);
    expect(model.savedDevices.single.device.id, device.id);
    await model.cancelAdding(
      token,
    ); // Successful close must preserve connection.
    expect(model.connected, true);
  });

  test('重启恢复多条本机记录但不恢复在线状态', () async {
    expect(await add('a', 'SERIAL-A'), true);
    await disconnect();
    expect(await add('b', 'SERIAL-B'), true);
    final restored = RecorderDeviceViewModel(
      DeviceServiceFake(),
      repository: repository,
    );
    await restored.initialize();
    expect(restored.savedDevices.length, 2);
    expect(restored.connected, false);
    expect(restored.selected, isNull);
    expect(
      restored.savedDevices.map((r) => r.serialNumber),
      containsAll(['SERIAL-A', 'SERIAL-B']),
    );
    restored.dispose();
  });

  test('同名不同标识不合并；相同SN回读只保留一个设备记录', () async {
    expect(await add('a', 'SAME-SN'), true);
    await disconnect();
    expect(await add('b', 'SAME-SN'), true);
    expect(model.savedDevices.length, 1);
    expect(model.savedDevices.single.device.id, 'b');
    await disconnect();
    expect(await add('c', 'OTHER-SN'), true);
    expect(model.savedDevices.length, 2);
  });

  test('SN稍晚回读合并重复项时，保留当前设备详情使用的记录ID', () async {
    await add('a', 'SAME-SN');
    await disconnect();
    await add('b');
    final activeId = model.savedFor('b')!.recordId;
    sdk.emit('serial', {'sn': 'SAME-SN'});
    await tick();
    expect(model.savedDevices.length, 1);
    expect(model.savedDevices.single.recordId, activeId);
    expect(model.savedDevices.single.serialNumber, 'SAME-SN');
  });

  test('取消连接后迟到成功不能添加，等待真实断开后才能重连', () async {
    final token = model.beginAdding();
    final device = await discover();
    final result = model.addDevice(device, token);
    await tick();
    await model.cancelAdding(token);
    sdk.emit('connection', {'connected': true});
    expect(await result, false);
    expect(model.savedDevices, isEmpty);
    expect(model.connection, RecorderConnection.disconnecting);
    sdk.emit('connection', {'connected': false});
    expect(model.connection, RecorderConnection.disconnected);
  });

  test('停止扫描尚未完成时取消，不会迟到提交连接或卡在断开中', () async {
    final token = model.beginAdding();
    final device = await discover();
    sdk.stopScanGate = Completer<void>();
    final result = model.addDevice(device, token);
    await tick();
    await model.cancelAdding(token);
    sdk.stopScanGate!.complete();
    expect(await result, false);
    expect(model.connection, RecorderConnection.disconnected);
    expect(sdk.calls, isNot(contains('connect')));
    expect(sdk.calls, isNot(contains('disconnect')));
  });

  test('写盘期间取消会补偿撤销，重启没有幽灵设备', () async {
    repository.writeGate = Completer<void>();
    final token = model.beginAdding();
    final device = await discover();
    final result = model.addDevice(device, token);
    await tick();
    sdk.emit('connection', {'connected': true});
    await tick();
    await model.cancelAdding(token);
    repository.writeGate!.complete();
    expect(await result, false);
    expect(model.savedDevices, isEmpty);
    expect(await repository.load(), isEmpty);
    sdk.emit('connection', {'connected': false});
  });

  test('保存失败可重试且不重复建立蓝牙连接', () async {
    repository.failSave = true;
    final token = model.beginAdding();
    final device = await discover();
    final result = model.addDevice(device, token);
    await tick();
    sdk.emit('connection', {'connected': true});
    expect(await result, false);
    expect(model.savedDevices, isEmpty);
    repository.failSave = false;
    expect(await model.addDevice(device, token), true);
    expect(sdk.calls.where((c) => c == 'connect').length, 1);
  });

  test('读盘失败不把已有资料覆盖为空；移除写盘失败记录仍保留', () async {
    await add();
    final record = model.savedDevices.single;
    await disconnect();
    repository.failSave = true;
    expect(await model.removeDevice(record), false);
    expect(model.savedDevices.length, 1);
    repository.failSave = false;
    repository.failLoad = true;
    await model.reloadRecords();
    expect(model.recordsReady, false);
    expect(model.savedDevices.length, 1);
    expect(await model.removeDevice(record), false);
  });

  test('独立录音允许断开，会议占用从模型层拦截断开和移除', () async {
    await add();
    sdk.emit('recording', {'state': 'recording'});
    final record = model.savedDevices.single;
    model.meetingUsesDevice = () => true;
    await model.disconnect();
    expect(await model.removeDevice(record), false);
    expect(sdk.calls, isNot(contains('disconnect')));
    model.meetingUsesDevice = () => false;
    await disconnect();
    expect(model.savedDevices.length, 1);
    expect(sdk.calls, isNot(contains('stop')));
    expect(await model.removeDevice(record), true);
    expect(await repository.load(), isEmpty);
  });

  test('已连接设备先收到断开确认，才能从持久化记录移除', () async {
    await add();
    final result = model.removeDevice(model.savedDevices.single);
    await tick();
    expect(model.savedDevices.length, 1);
    expect(model.connection, RecorderConnection.disconnecting);
    sdk.emit('connection', {'connected': false});
    expect(await result, true);
    expect(model.savedDevices, isEmpty);
  });

  test('重连先重新发现标识，名称相同的其他设备不会被连接', () async {
    await add('known');
    final record = model.savedDevices.single;
    await disconnect();
    final result = model.reconnect(record);
    await tick();
    sdk.id = 'other';
    sdk.emit('discovered', {'name': 'CB08'});
    await tick();
    expect(sdk.calls.where((c) => c == 'connect').length, 1);
    sdk.id = 'known';
    sdk.emit('discovered', {'name': 'CB08'});
    await tick();
    sdk.emit('connection', {'connected': true});
    await result;
    expect(model.selected!.id, 'known');
    expect(sdk.calls.where((c) => c == 'connect').length, 2);
  });

  test('第二台连接被拒绝；SN不匹配不覆写已有身份', () async {
    await add('known', 'EXPECTED');
    final token = model.beginAdding();
    expect(
      await model.addDevice(const RecorderDevice('other', 'CB08'), token),
      false,
    );
    expect(model.savedDevices.length, 1);
    expect(model.selected!.id, 'known');
    sdk.id = 'known';
    sdk.emit('serial', {'sn': 'WRONG'});
    await tick();
    expect(model.identityMismatch, true);
    expect(model.savedDevices.single.serialNumber, 'EXPECTED');
    expect(model.connection, RecorderConnection.disconnecting);
    sdk.emit('connection', {'connected': false});
  });

  test('SN空值不伪造，超时按字段结束，迟到旧连接回调不能更新新设备', () async {
    final info = RecorderInfo();
    for (final value in [null, '', 'null', '<null>']) {
      info.update('serial', {'sn': value});
      expect(info.serialNumber, isNull);
    }
    info.update('serial', {'sn': '  REAL  '});
    expect(info.serialNumber, 'REAL');
    await add('a');
    final old = sdk.epoch;
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(model.refreshing, false);
    expect(model.failedFields, contains('serial'));
    await disconnect();
    await add('b');
    sdk.emit('serial', {'sn': 'OLD'}, old);
    expect(model.info.serialNumber, isNull);
  });

  Future<void> show(
    WidgetTester tester,
    Widget page, {
    double scale = 1,
    bool dark = false,
    bool reduced = false,
  }) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: model,
        child: RepaintBoundary(
          key: const ValueKey('device-capture'),
          child: MaterialApp(
            theme: (dark ? AppTheme.dark() : AppTheme.light()).copyWith(
              textTheme: (dark ? AppTheme.dark() : AppTheme.light()).textTheme
                  .apply(fontFamily: 'DeviceTestChinese'),
            ),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                size: const Size(390, 844),
                textScaler: TextScaler.linear(scale),
                disableAnimations: reduced,
              ),
              child: child!,
            ),
            home: page,
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets(
    '修改设备名称弹窗关闭动画期间安全保存和取消',
    (tester) async {
      await tester.runAsync(() => add());
      completeDeviceInfo();
      await tester.runAsync(tick);
      final record = model.savedDevices.single;
      await show(tester, RecorderDeviceDetailPage(recordId: record.recordId));
      await tester.tap(find.byIcon(Icons.edit_outlined));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.byTooltip('清空名称'));
      await tester.pump();
      expect(
        tester.widget<EditableText>(find.byType(EditableText)).controller.text,
        isEmpty,
      );
      expect(
        tester
            .widget<CupertinoDialogAction>(
              find.widgetWithText(CupertinoDialogAction, '完成'),
            )
            .onPressed,
        isNull,
      );
      await tester.enterText(find.byType(EditableText), '会议录音卡');
      await tester.pump();
      await tester.tap(find.text('完成'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.runAsync(tick);
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(model.savedDevices.single.displayName, '会议录音卡');
      expect(find.text('AI Voice'), findsNothing);
      expect(find.text('会议录音卡'), findsNWidgets(2));
      expect(find.text('设备详情'), findsOneWidget);
      expect(find.text('设备名称'), findsOneWidget);
      await tester.tap(find.byIcon(Icons.edit_outlined));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.enterText(find.byType(EditableText), '不保存');
      await tester.tap(find.text('取消'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 400));
      expect(tester.takeException(), isNull);
      expect(model.savedDevices.single.displayName, '会议录音卡');
    },
    variant: TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.iOS,
    }),
  );

  testWidgets(
    '设备列表push详情有返回按钮；直接打开详情仍保留父层',
    (tester) async {
      await tester.runAsync(() => add());
      final record = model.savedDevices.single;
      final router = createRouter(initialLocation: '/profile/recording-device');
      addTearDown(router.dispose);
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: model,
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pump();
      await tester.tap(find.text('AI Voice'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(router.canPop(), true);
      expect(find.byType(BackButton), findsOneWidget);
      await tester.pageBack();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('我的设备'), findsOneWidget);
      expect(model.connected, true);
      router.go('/profile/recording-device/${record.recordId}');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(router.canPop(), true);
      expect(find.byType(BackButton), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.iOS,
    }),
  );

  testWidgets(
    '添加成功关闭Sheet回列表，不跳转详情或断开连接',
    (tester) async {
      await useInteractiveTimeouts();
      await show(tester, const RecorderDevicePage());
      await tester.tap(find.byTooltip('添加设备'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      sdk.emit('discovered', {'name': 'CB08'});
      await tester.pump();
      await tester.ensureVisible(find.text('AI Voice'));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(find.text('AI Voice'));
      await tester.pump();
      await tester.runAsync(() async {
        sdk.emit('connection', {'connected': true});
        await tick();
      });
      await tester.pump();
      for (var i = 0; i < 16 && find.text('取消').evaluate().isNotEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.text('我的设备'), findsOneWidget);
      expect(find.text('取消'), findsNothing);
      expect(find.byType(RecorderDeviceDetailPage), findsNothing);
      expect(model.savedDevices.length, 1);
      expect(model.connected, true);
      expect(sdk.calls, isNot(contains('disconnect')));
      completeDeviceInfo();
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.iOS,
    }),
  );

  testWidgets('动效与连接和持久化结果绑定，等待期间不会伪造成功', (tester) async {
    if (const bool.fromEnvironment('CAPTURE_DEVICE_UI')) {
      await tester.runAsync(() async {
        await (FontLoader('DeviceTestChinese')
              ..addFont(rootBundle.load('assets/fonts/NotoSansSC-Regular.ttf')))
            .load();
        await (FontLoader(
          'MaterialIcons',
        )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
      });
    }
    Future<void> capture(String name) async {
      if (!const bool.fromEnvironment('CAPTURE_DEVICE_UI')) return;
      await tester.pump(const Duration(milliseconds: 220));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump();
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(const ValueKey('device-capture')),
      );
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 2);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final folder = Directory('build/ai_voice_motion_ui')
          ..createSync(recursive: true);
        await File(
          '${folder.path}/$name.png',
        ).writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }

    model.dispose();
    sdk = DeviceServiceFake();
    repository = MemoryRecorderRepository()..writeGate = Completer<void>();
    model = RecorderDeviceViewModel(
      sdk,
      repository: repository,
      readyDelay: Duration.zero,
      scanTimeout: const Duration(seconds: 10),
      commandTimeout: const Duration(seconds: 10),
    );
    await model.initialize();
    sdk.emit('bluetooth', {'authorized': true, 'enabled': true});
    await show(tester, const RecorderDevicePage());
    await tester.tap(find.byTooltip('添加设备'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.text('正在搜索附近设备'), findsOneWidget);
    await capture('scanning');
    sdk.emit('discovered', {'name': 'CB08'});
    await tester.pump();
    expect(find.text('已发现附近设备'), findsOneWidget);
    await tester.ensureVisible(find.text('AI Voice'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.text('AI Voice'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    expect(model.connected, false);
    expect(find.text('正在连接 AI Voice'), findsOneWidget);
    expect(find.text('AI Voice 已添加'), findsNothing);
    await capture('connecting');
    await tester.runAsync(() async {
      sdk.emit('connection', {'connected': true});
      await tick();
    });
    await tester.pump();
    expect(model.connected, true);
    expect(model.savedDevices, isEmpty);
    expect(find.text('正在保存设备'), findsOneWidget);
    expect(find.text('AI Voice 已添加'), findsNothing);
    await tester.runAsync(() async {
      repository.writeGate!.complete();
      await tick();
    });
    await tester.pump();
    expect(model.savedDevices.length, 1);
    expect(find.text('AI Voice 已添加'), findsOneWidget);
    await capture('success');
    for (var i = 0; i < 20 && find.text('取消').evaluate().isNotEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('取消'), findsNothing);
    expect(model.connected, true);
    expect(sdk.calls, isNot(contains('disconnect')));
    completeDeviceInfo();
    expect(tester.takeException(), isNull);
  });

  testWidgets('连接失败停止动效，提供真实重试和取消', (tester) async {
    await useInteractiveTimeouts();
    await show(tester, const RecorderDevicePage());
    await tester.tap(find.byTooltip('添加设备'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    sdk.emit('discovered', {'name': 'CB08'});
    await tester.pump();
    await tester.ensureVisible(find.text('AI Voice'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.text('AI Voice'));
    await tester.pump();
    await tester.runAsync(() async {
      sdk.emit('connection', {'connected': false});
      await tick();
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(model.connected, false);
    expect(model.savedDevices, isEmpty);
    expect(find.text('连接未完成'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    expect(find.text('取消'), findsOneWidget);
    expect(find.text('AI Voice 已添加'), findsNothing);
    await tester.tap(find.text('取消'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.takeException(), isNull);
  });

  testWidgets('连接成功但保存失败时说明真实状态，重试保存不重复连接', (tester) async {
    await useInteractiveTimeouts();
    repository.failSave = true;
    await show(tester, const RecorderDevicePage());
    await tester.tap(find.byTooltip('添加设备'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    sdk.emit('discovered', {'name': 'CB08'});
    await tester.pump();
    await tester.ensureVisible(find.text('AI Voice'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.text('AI Voice'));
    await tester.pump();
    await tester.runAsync(() async {
      sdk.emit('connection', {'connected': true});
      await tick();
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(model.connected, true);
    expect(model.savedDevices, isEmpty);
    expect(find.text('设备已连接，保存失败'), findsOneWidget);
    expect(find.text('AI Voice 已添加'), findsNothing);
    repository.failSave = false;
    await tester.ensureVisible(find.text('重试保存'));
    await tester.tap(find.text('重试保存'));
    await tester.pump();
    await tester.runAsync(tick);
    await tester.pump();
    expect(model.savedDevices.length, 1);
    expect(sdk.calls.where((call) => call == 'connect').length, 1);
    for (var i = 0; i < 16 && find.text('取消').evaluate().isNotEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    completeDeviceInfo();
    expect(model.connected, true);
    expect(tester.takeException(), isNull);
  });

  testWidgets('减少动态效果仍展示静态搜索与成功确认', (tester) async {
    await useInteractiveTimeouts();
    await show(tester, const RecorderDevicePage(), reduced: true);
    await tester.tap(find.byTooltip('添加设备'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('正在搜索附近设备'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    sdk.emit('discovered', {'name': 'CB08'});
    await tester.pump();
    await tester.ensureVisible(find.text('AI Voice'));
    await tester.tap(find.text('AI Voice'));
    await tester.pump();
    await tester.runAsync(() async {
      sdk.emit('connection', {'connected': true});
      await tick();
    });
    await tester.pump();
    expect(find.text('AI Voice 已添加'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('AI Voice 已添加'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
    expect(find.text('取消'), findsNothing);
    completeDeviceInfo();
    expect(tester.takeException(), isNull);
  });

  testWidgets('首页设备列表与详情在手机尺寸可读，导出审查用截图', (tester) async {
    if (const bool.fromEnvironment('CAPTURE_DEVICE_UI')) {
      await tester.runAsync(() async {
        await (FontLoader('DeviceTestChinese')
              ..addFont(rootBundle.load('assets/fonts/NotoSansSC-Regular.ttf')))
            .load();
        await (FontLoader(
          'MaterialIcons',
        )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
      });
    }
    await tester.runAsync(() => add('one', 'REAL-SERIAL-1234'));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 5));
      sdk.emit('battery', {'cbc': 82});
      sdk.emit('capacity', {'totalSpace': 67108864, 'residueSpace': 50331648});
      sdk.emit('firmware', {'version': '544'});
      sdk.emit('firmware_code', {'versionCode': 100000544});
      sdk.emit('serial', {'sn': 'REAL-SERIAL-1234'});
      sdk.emit('recording', {'state': 'idle'});
    });
    final record = model.savedDevices.single;
    Future<void> capture(String name) async {
      if (!const bool.fromEnvironment('CAPTURE_DEVICE_UI')) return;
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(const ValueKey('device-capture')),
      );
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 2);
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        final folder = Directory('build/ai_voice_v2_ui')
          ..createSync(recursive: true);
        await File(
          '${folder.path}/$name.png',
        ).writeAsBytes(data!.buffer.asUint8List());
        image.dispose();
      });
    }

    Future<void> page(Widget child, {bool dark = false}) async {
      final theme = dark ? AppTheme.dark() : AppTheme.light();
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: model,
          child: MaterialApp(
            theme: theme.copyWith(
              textTheme: theme.textTheme.apply(fontFamily: 'DeviceTestChinese'),
            ),
            home: RepaintBoundary(
              key: const ValueKey('device-capture'),
              child: child,
            ),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
    }

    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await page(const RecorderDevicePage());
    expect(find.text('AI Voice'), findsOneWidget);
    await capture('device-list-light');
    await page(RecorderDeviceDetailPage(recordId: record.recordId));
    expect(find.text('82%'), findsOneWidget);
    await capture('device-detail-light');
    await page(RecorderDeviceDetailPage(recordId: record.recordId), dark: true);
    await capture('device-detail-dark');
  });

  testWidgets(
    '添加Sheet取消停止扫描但不释放全局设备服务',
    (tester) async {
      await show(tester, const RecorderDevicePage());
      await tester.tap(find.byTooltip('添加设备'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('添加设备'), findsOneWidget);
      expect(model.scanning, true);
      await tester.tap(find.text('取消'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(model.scanning, false);
      expect(find.text('我的设备'), findsOneWidget);
      // The same service still receives events after dismissing the sheet.
      sdk.emit('bluetooth', {'authorized': true, 'enabled': false});
      expect(model.bluetoothEnabled, false);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant({
      TargetPlatform.iOS,
      TargetPlatform.android,
    }),
  );

  testWidgets(
    '200%文字深色详情可滚动且只读信息没有录音控制',
    (tester) async {
      await tester.runAsync(() => add('known', 'LONG-SERIAL-1234'));
      await show(
        tester,
        RecorderDeviceDetailPage(recordId: model.savedDevices.single.recordId),
        scale: 2,
        dark: true,
      );
      expect(find.text('AI Voice'), findsWidgets);
      expect(find.text('开始录音'), findsNothing);
      expect(find.text('暂停录音'), findsNothing);
      expect(find.text('停止并保存'), findsNothing);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant({
      TargetPlatform.iOS,
      TargetPlatform.android,
    }),
  );
}
