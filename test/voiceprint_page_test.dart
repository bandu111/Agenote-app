// These tests simulate UI transitions only; no test audio is sent to the real backend.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:record/record.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:yanshu/core/network/api_client.dart';
import 'package:yanshu/core/network/api_config.dart';
import 'package:yanshu/features/meeting/audio_input_route.dart';
import 'package:yanshu/features/voiceprint/voiceprint_capture.dart';
import 'package:yanshu/features/voiceprint/voiceprint_page.dart';
import 'package:yanshu/features/voiceprint/voiceprint_repository.dart';

class FakeCapture implements VoiceprintCapture {
  FakeCapture(this.directory);
  final Directory directory;
  int starts = 0;
  String? lastPath;
  @override
  Stream<RecordState> get states => const Stream.empty();
  @override
  Stream<double> get levels => const Stream.empty();
  @override
  Future<String> start() async {
    starts++;
    lastPath = '${directory.path}/test-only-$starts.wav';
    File(lastPath!).writeAsBytesSync([1, 2, 3, 4]);
    return lastPath!;
  }

  @override
  Future<AudioInputRoute> route() async => const AudioInputRoute(
    id: 'test-only',
    name: 'test-only',
    type: 'builtIn',
    verified: true,
  );
  @override
  Future<void> stop() async {}
  @override
  Future<void> cancel() async {}
  @override
  Future<void> play(String path) async {}
  @override
  Future<void> stopPlayback() async {}
  @override
  Future<void> dispose() async {}
}

class FakeVoiceprintRepository extends VoiceprintRepository {
  FakeVoiceprintRepository(Map<String, dynamic> samples)
    : data = {
        'available': true,
        'registered': false,
        'enabled': false,
        'consentVersion': 'test-consent-v1',
        'enrollment': {
          'id': 'test-only',
          'status': 'recording',
          'expiresAt': '2099-01-01T00:00:00Z',
          'attempts': 0,
          'samples': samples,
          'prompts': ['测试引导语一', '测试引导语二', '测试引导语三', '测试验证语'],
        },
      },
      super(ApiClient(baseUrl: 'https://test.invalid/'), 'test-only');
  final Map<String, dynamic> data;
  final uploads = <String>[];
  final posts = <String>[];
  final deletions = <String>[];
  bool failBuild = false;
  @override
  Future<void> post(String suffix, [Map<String, dynamic>? body]) async {
    posts.add(suffix);
    if (suffix == '/enabled') data['enabled'] = body!['enabled'];
    if (suffix.endsWith('/build')) {
      if (failBuild) {
        data['enrollment']['samples'] = <String, dynamic>{};
        throw const ApiFailure('三段声音不一致，请重新采集');
      }
      data['enrollment']['status'] = 'ready';
    }
  }

  @override
  Future<void> delete(String suffix) async {
    deletions.add(suffix);
    data['enrollment'] = null;
    if (suffix.isEmpty) {
      data['registered'] = false;
      data['enabled'] = false;
    }
  }

  bool failUpload = false;
  Completer<void>? uploadGate;
  Map<String, dynamic> get samples =>
      data['enrollment']['samples'] as Map<String, dynamic>;
  @override
  void checkAccount() {}
  @override
  Future<Map<String, dynamic>> status() async =>
      Map<String, dynamic>.from(jsonDecode(jsonEncode(data)) as Map);
  @override
  Future<void> upload(String enrollment, String slot, Uint8List wav) async {
    uploads.add(slot);
    if (failUpload) throw const ApiFailure('测试上传失败');
    if (uploadGate != null) await uploadGate!.future;
    samples[slot] = {'status': 'processing'};
  }
}

Future<void> drain(WidgetTester tester) async {
  // Real filesystem operations are allowed only in this explicit test harness.
  for (var i = 0; i < 6; i++) {
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
  }
  await tester.pump();
}

Future<void> open(
  WidgetTester tester,
  FakeVoiceprintRepository repository,
  FakeCapture capture, {
  bool enterRecorder = true,
  PermissionStatus permission = PermissionStatus.granted,
  bool meetingRecording = false,
  Size size = const Size(800, 1800),
  double textScale = 1,
  Brightness brightness = Brightness.light,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(brightness: brightness),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(textScale),
          disableAnimations: true,
        ),
        child: child!,
      ),
      home: VoiceprintPage(
        repository: repository,
        capture: capture,
        isMeetingRecording: () => meetingRecording,
        requestMicrophonePermission: () async => permission,
      ),
    ),
  );
  await drain(tester);
  if (!enterRecorder) return;
  await tester.tap(find.byKey(const ValueKey('voiceprint-resume')));
  await tester.pumpAndSettle();
  if (repoReady(repository)) return;
  await tester.ensureVisible(find.byKey(const ValueKey('voiceprint-prepare')));
  await tester.tap(find.byKey(const ValueKey('voiceprint-prepare')));
  await drain(tester);
}

bool repoReady(FakeVoiceprintRepository r) =>
    r.data['enrollment']?['status'] == 'ready';

bool lockedStep(WidgetTester tester, int index) =>
    tester
        .widget<InkWell>(find.byKey(ValueKey('voiceprint-select-$index')))
        .onTap ==
    null;

void main() {
  late Directory directory;
  setUp(
    () =>
        directory = Directory.systemTemp.createTempSync('voiceprint-ui-test-'),
  );
  tearDown(() {
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });

  testWidgets(
    'home registration requires separate unchecked consent before any server write',
    (tester) async {
      final repo = FakeVoiceprintRepository({})..data['enrollment'] = null;
      await open(tester, repo, FakeCapture(directory), enterRecorder: false);
      expect(find.text('先注册你的声纹'), findsOneWidget);
      await tester.ensureVisible(find.text('开始注册声纹'));
      await tester.tap(find.text('开始注册声纹'));
      await tester.pumpAndSettle();
      final button = find.widgetWithText(FilledButton, '单独同意并开始');
      expect(tester.widget<FilledButton>(button).onPressed, isNull);
      expect(repo.posts, isEmpty);
      await tester.ensureVisible(
        find.byKey(const ValueKey('voiceprint-consent-checkbox')),
      );
      await tester.tap(
        find.byKey(const ValueKey('voiceprint-consent-checkbox')),
      );
      await tester.pumpAndSettle();
      expect(tester.widget<FilledButton>(button).onPressed, isNotNull);
      await tester.ensureVisible(find.text('先不注册'));
      await tester.tap(find.text('先不注册'));
      await tester.pumpAndSettle();
      expect(repo.posts, isEmpty);
      await tester.pumpWidget(const SizedBox());
      await drain(tester);
    },
  );

  testWidgets(
    'live-capable backend keeps realtime disclosure in the redesigned consent sheet',
    (tester) async {
      final repo = FakeVoiceprintRepository({})
        ..data['enrollment'] = null
        ..data['realtimeIdentificationAvailable'] = true;
      await open(tester, repo, FakeCapture(directory), enterRecorder: false);
      await tester.ensureVisible(find.text('开始注册声纹'));
      await tester.tap(find.text('开始注册声纹'));
      await tester.pumpAndSettle();
      expect(find.textContaining('启用后，在会议实时转写中尝试识别你的发言'), findsOneWidget);
      expect(find.textContaining('本阶段尚未接入会议实时本人识别'), findsNothing);
      expect(repo.posts, isEmpty);
      await tester.pumpWidget(const SizedBox());
      await drain(tester);
    },
  );

  testWidgets(
    'denied permission stays in preparation without starting capture',
    (tester) async {
      final repo = FakeVoiceprintRepository({});
      final capture = FakeCapture(directory);
      await open(tester, repo, capture, permission: PermissionStatus.denied);
      expect(find.text('麦克风权限未开启'), findsOneWidget);
      expect(find.text('去系统设置'), findsOneWidget);
      expect(capture.starts, 0);
      expect(find.byKey(const ValueKey('voiceprint-record-0')), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await drain(tester);
    },
  );

  testWidgets('an active meeting blocks the registration recorder', (
    tester,
  ) async {
    final repo = FakeVoiceprintRepository({});
    final capture = FakeCapture(directory);
    await open(
      tester,
      repo,
      capture,
      enterRecorder: false,
      meetingRecording: true,
    );
    await tester.tap(find.byKey(const ValueKey('voiceprint-resume')));
    await tester.pumpAndSettle();
    expect(find.text('现在正在录音，不能注册声纹'), findsOneWidget);
    expect(find.byKey(const ValueKey('voiceprint-prepare')), findsNothing);
    expect(capture.starts, 0);
    await tester.pumpWidget(const SizedBox());
    await drain(tester);
  });

  testWidgets(
    'ready enrollment uses only the independent clip and enters management on verified response',
    (tester) async {
      final repo = FakeVoiceprintRepository({
        for (var i = 0; i < 3; i++) '$i': {'status': 'accepted'},
      });
      repo.data['enrollment']['status'] = 'ready';
      await open(tester, repo, FakeCapture(directory));
      expect(find.text('测试验证语'), findsOneWidget);
      expect(find.byKey(const ValueKey('voiceprint-record-0')), findsNothing);
      await tester.tap(
        find.byKey(const ValueKey('voiceprint-record-verification')),
      );
      await drain(tester);
      await tester.tap(
        find.byKey(const ValueKey('voiceprint-stop-verification')),
      );
      await drain(tester);
      expect(repo.uploads, ['verification']);
      expect(find.text('正在与声纹比对'), findsOneWidget);
      repo.data.addAll({
        'registered': true,
        'enabled': true,
        'verifiedAt': '2026-10-31T03:46:00Z',
        'enrollment': null,
      });
      await tester.pump(const Duration(seconds: 2));
      await drain(tester);
      expect(find.text('验证通过 · 声纹已启用'), findsOneWidget);
      await tester.tap(find.text('进入声纹管理'));
      await tester.pumpAndSettle();
      expect(find.text('声纹已启用'), findsOneWidget);
      expect(find.text('启用声纹比对'), findsOneWidget);
      expect(repo.deletions, isEmpty);
      await tester.pumpWidget(const SizedBox());
      await drain(tester);
    },
  );

  testWidgets(
    'management disable and delete confirmation retain real server semantics',
    (tester) async {
      final repo = FakeVoiceprintRepository({});
      repo.data.addAll({
        'enrollment': null,
        'registered': true,
        'enabled': true,
        'verifiedAt': '2026-10-31T03:46:00Z',
      });
      await open(tester, repo, FakeCapture(directory), enterRecorder: false);
      await tester.tap(find.byType(Switch));
      await drain(tester);
      expect(repo.posts, ['/enabled']);
      expect(find.text('声纹已关闭'), findsOneWidget);
      await tester.ensureVisible(find.text('撤回同意并删除声纹'));
      await tester.tap(find.text('撤回同意并删除声纹'));
      await tester.pumpAndSettle();
      expect(find.text('撤回同意并删除声纹？'), findsOneWidget);
      expect(repo.deletions, isEmpty);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(repo.data['registered'], isTrue);
      expect(repo.deletions, isEmpty);
      await tester.pumpWidget(const SizedBox());
      await drain(tester);
    },
  );

  for (final brightness in Brightness.values) {
    testWidgets(
      'voiceprint layout respects large text and narrow screen in $brightness',
      (tester) async {
        final repo = FakeVoiceprintRepository({});
        repo.data.addAll({
          'enrollment': null,
          'registered': true,
          'enabled': true,
          'verifiedAt': '2026-10-31T03:46:00Z',
        });
        await open(
          tester,
          repo,
          FakeCapture(directory),
          enterRecorder: false,
          size: const Size(320, 760),
          textScale: 1.6,
          brightness: brightness,
        );
        await tester.drag(find.byType(ListView), const Offset(0, -700));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await drain(tester);
      },
    );
  }

  testWidgets(
    'legacy third-only success is preserved and guides user to first missing sample',
    (tester) async {
      final repo = FakeVoiceprintRepository({
        '2': {
          'status': 'accepted',
          'quality': {'speechSeconds': 9.3},
        },
      });
      await open(tester, repo, FakeCapture(directory));
      expect(find.text('1/3 已通过'), findsOneWidget);
      expect(find.text('第 1 段'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('voiceprint-select-2')));
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('voiceprint-step-2')),
          matching: find.text('已通过 · 已保存'),
        ),
        findsOneWidget,
      );
      expect(lockedStep(tester, 0), isFalse);
      expect(lockedStep(tester, 1), isTrue);
      expect(lockedStep(tester, 2), isFalse);
      expect(repo.uploads, isEmpty);
      await tester.pumpWidget(const SizedBox());
      await drain(tester);
    },
  );

  testWidgets(
    'quality rejection explains the retry and keeps later samples locked',
    (tester) async {
      final repo = FakeVoiceprintRepository({
        '0': {'status': 'rejected', 'reason': 'too_quiet'},
      });
      await open(tester, repo, FakeCapture(directory));
      expect(find.text('未通过检查 · 需要重录'), findsOneWidget);
      expect(find.text('声音过轻，请靠近麦克风正常说话'), findsOneWidget);
      expect(find.text('0/3 已通过'), findsOneWidget);
      expect(lockedStep(tester, 0), isFalse);
      expect(lockedStep(tester, 1), isTrue);
      await tester.pumpWidget(const SizedBox());
      await drain(tester);
    },
  );

  testWidgets(
    'stopping auto uploads in the same card and unlocks next only after accepted',
    (tester) async {
      final repo = FakeVoiceprintRepository({})..uploadGate = Completer<void>();
      final capture = FakeCapture(directory);
      await open(tester, repo, capture);
      await tester.tap(find.byKey(const ValueKey('voiceprint-record-0')));
      await drain(tester);
      expect(find.text('正在录音'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('voiceprint-stop-0')));
      await drain(tester);
      expect(repo.uploads, ['0']);
      expect(find.text('录音已保存 · 正在上传'), findsOneWidget);
      expect(lockedStep(tester, 1), isTrue);
      repo.uploadGate!.complete();
      await drain(tester);
      expect(find.text('上传成功 · 正在检查'), findsOneWidget);
      expect(File(capture.lastPath!).existsSync(), isFalse);
      expect(lockedStep(tester, 1), isTrue);
      repo.samples['0'] = {
        'status': 'accepted',
        'quality': {'speechSeconds': 9.2},
      };
      await tester.pump(const Duration(seconds: 2));
      await drain(tester);
      expect(find.text('1/3 已通过'), findsOneWidget);
      expect(lockedStep(tester, 1), isFalse);
      expect(lockedStep(tester, 2), isTrue);
      expect(find.text('上传并检查'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await drain(tester);
    },
  );

  testWidgets(
    'upload failure keeps clip and retry in its card without allowing another recording',
    (tester) async {
      final repo = FakeVoiceprintRepository({})..failUpload = true;
      final capture = FakeCapture(directory);
      await open(tester, repo, capture);
      await tester.tap(find.byKey(const ValueKey('voiceprint-record-0')));
      await drain(tester);
      await tester.tap(find.byKey(const ValueKey('voiceprint-stop-0')));
      await drain(tester);
      expect(find.text('录音已保存 · 待重试上传'), findsOneWidget);
      expect(File(capture.lastPath!).existsSync(), isTrue);
      expect(lockedStep(tester, 1), isTrue);
      await tester.tap(find.byKey(const ValueKey('voiceprint-record-0')));
      await tester.pumpAndSettle();
      expect(find.text('重录当前片段？'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(capture.starts, 1);
      expect(File(capture.lastPath!).existsSync(), isTrue);
      repo.failUpload = false;
      await tester.tap(find.byKey(const ValueKey('voiceprint-retry-0')));
      await drain(tester);
      expect(repo.uploads, ['0', '0']);
      expect(File(capture.lastPath!).existsSync(), isFalse);
      expect(find.text('上传成功 · 正在检查'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await drain(tester);
    },
  );

  testWidgets(
    'failed retake does not show old acceptance or offer template build',
    (tester) async {
      final repo = FakeVoiceprintRepository({
        for (var i = 0; i < 3; i++) '$i': {'status': 'accepted'},
      })..failUpload = true;
      await open(tester, repo, FakeCapture(directory));
      expect(find.byKey(const ValueKey('voiceprint-build')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('voiceprint-select-0')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('voiceprint-record-0')));
      await drain(tester);
      await tester.tap(find.byKey(const ValueKey('voiceprint-stop-0')));
      await drain(tester);
      expect(find.text('2/3 已通过'), findsOneWidget);
      expect(find.byKey(const ValueKey('voiceprint-build')), findsNothing);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('voiceprint-step-0')),
          matching: find.text('已通过 · 已保存'),
        ),
        findsNothing,
      );
      await tester.pumpWidget(const SizedBox());
      await drain(tester);
    },
  );
}
