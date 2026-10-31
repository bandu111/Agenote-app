import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:provider/provider.dart';
import 'package:yanshu/app/app.dart';
import 'package:yanshu/features/profile/repositories/profile_repository.dart';
import 'package:yanshu/features/knowledge/repositories/knowledge_repository.dart';
import 'package:yanshu/features/recording_device/recorder_device_page.dart';
import 'package:yanshu/features/recording_device/recorder_device_view_model.dart';

void main() {
 final binding=IntegrationTestWidgetsFlutterBinding.ensureInitialized();
 binding.shouldPropagateDevicePointerEvents=true;
 testWidgets('手动连接录音卡，观测真实双击事件，不自动开始录音', (tester) async {
  await tester.pumpWidget(YanShuApp(connectRecordingCardToMeetings:false,
   initialLocation:'/profile/recording-device',
   profileRepository:ProfileRepository(MemoryProfileStore()),
   knowledgeRepository:KnowledgeRepository(MemoryKnowledgeStore(),seedExamples:false)));
  for (var i=0;i<100 && find.byType(RecorderDevicePage).evaluate().isEmpty;i++) {
   await tester.pump(const Duration(milliseconds:100));
  }
  final vm=tester.element(find.byType(RecorderDevicePage)).read<RecorderDeviceViewModel>();
  final events=<Map<String,dynamic>>[];
  final sub=vm.service.events.listen((e) {
   if (['button_observed','button','recording','connection','disconnected','control_packet_probe'].contains(e.type)) {
    final data={'type':e.type,'button':e.data['button'],'atMs':e.data['atMs'],
      'state':e.data['state'],'query':e.data['query'],'hex':e.data['hex'],'length':e.data['length'],'error':e.data['error']};
    events.add(data);debugPrint('DOUBLE_PRESS_PROBE ${jsonEncode(data)}');
   }
  });
  debugPrint('DOUBLE_PRESS_PROBE_MANUAL_READY');
  var probing=false;
  try {
   final until=DateTime.now().add(const Duration(minutes:10));
   while (DateTime.now().isBefore(until)) {
    if (vm.connected && !probing) {
     await Future<void>.delayed(const Duration(seconds:2));
     try {
      await const MethodChannel('yanshu/soninote').invokeMethod<void>('debugControlProbe', {'enabled':true});
      probing=true;debugPrint('CONTROL_PACKET_PROBE_READY');
     } on PlatformException { /* Service discovery may still be pending. */ }
    }
    await tester.pump(const Duration(milliseconds:100));
    await Future<void>.delayed(const Duration(milliseconds:100));
   }
  } finally {
   binding.reportData={'sdkMocked':false,'automaticRecordingCommands':false,'events':events};
   await const MethodChannel('yanshu/soninote').invokeMethod<void>('debugControlProbe', {'enabled':false});
   await sub.cancel();
  }
 },timeout:const Timeout(Duration(minutes:12)));
}
