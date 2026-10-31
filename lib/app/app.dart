import '../features/offline_recordings/offline_recordings_model.dart';
import '../shared/widgets/content_skeleton.dart';
import '../features/recording_status/recording_status_host.dart';
import 'dart:async';
import '../features/meeting/meeting_recorder_factory.dart';
import '../features/meeting/meeting_audio_recovery.dart';
import '../features/meeting/tencent_speech.dart';
import 'package:flutter/material.dart';
import '../features/recording_device/recorder_device_view_model.dart';
import '../features/recording_device/soninote_device_adapter.dart';
import '../features/recording_device/soninote_meeting_coordinator.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../features/home/viewmodels/home_view_model.dart';
import '../features/home/viewmodels/schedule_view_model.dart';
import '../features/home/repositories/schedule_repository.dart';
import '../features/home/repositories/dio_home_repository.dart';
import '../features/affairs/viewmodels/affairs_view_model.dart';
import '../features/profile/viewmodels/profile_view_model.dart';
import '../shared/repositories/affairs_repository.dart';
import '../features/knowledge/repositories/knowledge_repository.dart';
import '../features/knowledge/repositories/knowledge_importer.dart';
import '../features/knowledge/viewmodels/knowledge_view_model.dart';
import 'router/app_router.dart';
import 'router/destinations.dart';
import 'theme/app_theme.dart';
import 'l10n/app_strings.dart';
import '../features/profile/repositories/profile_repository.dart';
import '../features/profile/services/profile_media.dart';
import '../features/profile/services/system_access.dart';
import '../features/auth/repositories/auth_repository.dart';
import '../features/auth/viewmodels/auth_view_model.dart';
import '../features/progress/repositories/progress_repository.dart';
import '../features/progress/repositories/device_evidence_audio_player.dart';
import '../features/progress/views/progress_completion_sheet.dart';
import '../features/progress/viewmodels/progress_view_model.dart';
import '../features/progress/viewmodels/voice_evidence_controller.dart';
import '../features/notifications/notification_model.dart';
import '../features/notifications/notification_views.dart';
import '../features/meeting/meeting_store.dart';
import '../features/meeting/meeting_services.dart';
import '../features/meeting/meeting_view_model.dart';
import '../features/meeting/meeting_remote.dart';
import '../core/network/api_client.dart';
import '../core/network/api_config.dart';
import '../features/notifications/account_actions.dart';
import '../features/notifications/knowledge_assistance.dart';
import '../features/notifications/local_notifications.dart';

class YanShuApp extends StatefulWidget {
  const YanShuApp({
    super.key,
    this.initialLocation = AppRoutes.home,
    this.repository,
    this.scheduleRepository,
    this.scheduleClock,
    this.progressRepository,
    this.knowledgeRepository,
    this.knowledgeImporter,
    this.profileRepository,
    this.profileMediaPicker,
    this.systemAccessService,
    this.meetingStore,
    this.meetingRecorder,
    this.meetingCalendar,
    this.meetingRemote,
    this.authRepository,
    this.initialAuthError,
    this.apiClient,
    this.connectRecordingCardToMeetings = true,
  });
  final String initialLocation;
  final AffairsRepository? repository;
  final ScheduleRepository? scheduleRepository;
  final ScheduleClock? scheduleClock;
  final ProgressRepository? progressRepository;
  final KnowledgeRepository? knowledgeRepository;
  final KnowledgeImporter? knowledgeImporter;
  final ProfileRepository? profileRepository;
  final ProfileMediaPicker? profileMediaPicker;
  final SystemAccessService? systemAccessService;
  final MeetingStore? meetingStore;
  final MeetingRecorder? meetingRecorder;
  final MeetingCalendar? meetingCalendar;
  final MeetingRemoteRepository? meetingRemote;
  final AuthRepository? authRepository;
  final String? initialAuthError;
  final ApiClient? apiClient;
  final bool connectRecordingCardToMeetings;
  @override
  State<YanShuApp> createState() => _YanShuAppState();
}

class _YanShuAppState extends State<YanShuApp> {
  late final DioHomeRepository? _homeRepository = widget.apiClient == null
      ? null
      : DioHomeRepository(widget.apiClient!);
  late final MeetingRemoteRepository? _meetingRemote =
      widget.meetingRemote ??
      (widget.apiClient == null
          ? null
          : DioMeetingRepository(widget.apiClient!));
  final _navigatorKey = GlobalKey<NavigatorState>();
  late final _profile = ProfileViewModel(repository: widget.profileRepository);
  late final ScheduleClock _scheduleClock =
      widget.scheduleClock ??
      (kDebugMode
          ? PreviewScheduleClock(
              initialTime: DateTime.tryParse(
                const String.fromEnvironment('YANSHU_PREVIEW_TIME'),
              ),
            )
          : DeviceScheduleClock());
  late final GoRouter _router = createRouter(
    navigatorKey: _navigatorKey,
    initialLocation: widget.initialLocation,
    profile: _profile,
  );
  late final AffairsRepository _repository =
      widget.repository ?? LocalEmptyAffairsRepository();
  @override
  void dispose() {
    _router.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MultiProvider(
    providers: [
      Provider<KnowledgeImporter>(
        create: (_) => widget.knowledgeImporter ?? DeviceKnowledgeImporter(),
      ),
      ChangeNotifierProvider(create: (_) => _profile..load()),
      ChangeNotifierProxyProvider<ProfileViewModel, KnowledgeViewModel>(
        create: (_) => KnowledgeViewModel(
          widget.knowledgeRepository ??
              KnowledgeRepository(LocalKnowledgeStore()),
          accountId: _meetingRemote == null
              ? null
              : () => _meetingRemote.accountId,
        )..load(),
        update: (_, profile, model) => model!..refreshAccount(),
      ),
      ChangeNotifierProxyProvider<ProfileViewModel, ProgressViewModel>(
        create: (_) => ProgressViewModel(
          widget.progressRepository ?? EmptyProgressRepository(),
        )..load(),
        update: (_, profile, model) => model!..refreshAccount(),
      ),
      ChangeNotifierProxyProvider<ProfileViewModel, VoiceEvidenceController>(
        create: (_) => VoiceEvidenceController(
          player: widget.progressRepository is AccountProgressRepository
              ? DeviceEvidenceAudioPlayer(client: widget.apiClient)
              : null,
          accountId: widget.progressRepository is AccountProgressRepository
              ? () => (widget.progressRepository as AccountProgressRepository)
                    .accountId
              : null,
        ),
        update: (_, profile, model) => model!..refreshAccount(),
      ),
      ChangeNotifierProxyProvider<ProfileViewModel, NotificationModel>(
        lazy: false,
        create: (context) =>
            NotificationModel(storage: const FlutterSecureStorage())
              ..onCompleteProgress = (item) async {
                final overlay = _navigatorKey.currentContext;
                if (overlay == null) throw const ApiFailure('页面尚未就绪，请稍后重新点击补全');
                return showProgressCompletion(
                  overlay,
                  context.read<ProgressViewModel>(),
                  item,
                );
              }
              ..bind(context.read<ProgressViewModel>()),
        update: (_, profile, notifications) {
          final client = widget.apiClient;
          final owner = client?.accountId?.call();
          unawaited(
            notifications!.configureInbox(
              client != null
                  ? (owner == null
                        ? null
                        : '${client.dio.options.baseUrl}:$owner')
                  : null,
            ),
          );
          return notifications;
        },
      ),
      ChangeNotifierProxyProvider<ProfileViewModel, AccountActions?>(
        create: (context) => widget.apiClient == null
            ? null
            : AccountActions(
                widget.apiClient!,
                context.read<NotificationModel>(),
                onChanged: () async {
                  final knowledge = context.read<KnowledgeViewModel>();
                  final progress = context.read<ProgressViewModel>();
                  await knowledge.load();
                  await progress.load();
                  // 通知 Provider 位于会议 Provider 之前；通过导航上下文读取完整的 Provider 树。
                  final currentContext =
                      _router.routerDelegate.navigatorKey.currentContext;
                  if (currentContext != null && currentContext.mounted) {
                    await currentContext
                        .read<MeetingViewModel>()
                        .refreshSourceChanges();
                  }
                  if (currentContext != null && currentContext.mounted) {
                    _homeRepository?.invalidateSnapshot();
                    await currentContext.read<HomeViewModel>().refresh();
                    if (currentContext.mounted) {
                      await currentContext.read<ScheduleViewModel>().refresh();
                    }
                  }
                },
              ),
        update: (_, profile, actions) => actions?..refreshAccount(),
      ),
      ChangeNotifierProxyProvider<ProfileViewModel, HomeViewModel>(
        create: (_) =>
            HomeViewModel(repository: _homeRepository)..refreshAccount(),
        update: (_, profile, model) => model!..refreshAccount(),
      ),
      ChangeNotifierProvider(
        create: (_) => RecorderDeviceViewModel(SoniNoteDeviceAdapter()),
      ),
      ChangeNotifierProxyProvider<ProfileViewModel, KnowledgeAssistance?>(
        lazy: false,
        create: (context) => widget.apiClient == null
            ? null
            : KnowledgeAssistance(
                widget.apiClient!,
                context.read<NotificationModel>(),
                onRecorded: () async {
                  await context.read<ProgressViewModel>().load();
                  if (context.mounted) {
                    await context.read<HomeViewModel>().refresh();
                  }
                  if (context.mounted) {
                    await context.read<KnowledgeViewModel>().load();
                  }
                },
              ),
        update: (_, profile, assistance) => assistance?..refreshAccount(),
      ),
      ChangeNotifierProxyProvider<ProfileViewModel, ScheduleViewModel>(
        create: (_) => ScheduleViewModel(
          widget.scheduleRepository ??
              _homeRepository ??
              EmptyScheduleRepository(),
          clock: _scheduleClock,
          taskChecklist: true,
        )..refresh(),
        update: (_, profile, model) => model!..refreshAccount(),
      ),
      ChangeNotifierProvider(
        create: (_) => AffairsViewModel(_repository)..refresh(),
      ),
      Provider<ProfileMediaPicker>(
        create: (_) => widget.profileMediaPicker ?? DeviceProfileMediaPicker(),
      ),
      Provider<SystemAccessService>(
        create: (_) =>
            widget.systemAccessService ?? DeviceSystemAccessService(),
      ),
      ChangeNotifierProvider(
        create: (context) => AuthViewModel(
          widget.authRepository ?? UnconfiguredAuthRepository(),
          context.read<ProfileViewModel>(),
          error: widget.initialAuthError,
          onSessionEnded: () =>
              context.read<MeetingViewModel>().suspendForLogout(),
        ),
      ),
      ChangeNotifierProvider(
        create: (context) => MeetingViewModel(
          store: widget.meetingStore ?? LocalMeetingStore(),
          recorder:
              widget.meetingRecorder ??
              createDeviceMeetingRecorder(apiClient: widget.apiClient),
          calendar: widget.meetingCalendar ?? DeviceMeetingCalendar(),
          knowledge: context.read<KnowledgeViewModel>(),
          notifications: context.read<NotificationModel>(),
          home: context.read<HomeViewModel>(),
          speakerName: () => context.read<ProfileViewModel>().data.name,
          remote: _meetingRemote,
          audioRecovery:
              widget.apiClient != null && ApiConfig.speechProvider == 'tencent'
              ? MeetingAudioRecovery(
                  (id) => TencentSpeechWorker(widget.apiClient!, id),
                )
              : null,
          onProgressChanged: () async {
            if (!context.mounted) return;
            _homeRepository?.invalidateSnapshot();
            await Future.wait([
              context.read<AccountActions?>()?.refresh() ??
                  Future<void>.value(),
              context.read<ProgressViewModel>().load(silent: true),
              context.read<HomeViewModel>().refresh(),
              context.read<ScheduleViewModel>().refresh(),
            ]);
          },
          onNoticesChanged: () =>
              context.read<AccountActions?>()?.refresh() ??
              Future<void>.value(),
        ),
      ),
      ChangeNotifierProxyProvider<ProfileViewModel, OfflineRecordingsModel>(
        lazy: false,
        create: (context) => OfflineRecordingsModel(
          context.read<RecorderDeviceViewModel>(),
          context.read<MeetingViewModel>(),
        )..refreshAccount(),
        update: (_, profile, model) => model!..refreshAccount(),
      ),
      if (widget.connectRecordingCardToMeetings)
        ChangeNotifierProvider<SoniNoteMeetingCoordinator>(
          lazy: false,
          create: (context) => SoniNoteMeetingCoordinator(
            device: context.read<RecorderDeviceViewModel>(),
            meeting: context.read<MeetingViewModel>(),
            sessionActive: () =>
                context.read<ProfileViewModel>().data.sessionActive,
            openMeeting: () {
              final uri = _router.routerDelegate.currentConfiguration.isEmpty
                  ? _router.routeInformationProvider.value.uri
                  : _router.routerDelegate.state.uri;
              if (uri.path != '/meeting') {
                unawaited(_router.push<void>('/meeting'));
              }
            },
          ),
        ),
      ChangeNotifierProxyProvider<ProfileViewModel, LocalNotifications?>(
        lazy: false,
        create: (context) => widget.apiClient == null
            ? null
            : LocalNotifications(
                widget.apiClient!,
                context.read<NotificationModel>(),
                onOpen: () {
                  if (_router.routeInformationProvider.value.uri.path !=
                      '/notifications') {
                    _router.push('/notifications');
                  }
                },
                onChanged: () async {
                  await context.read<AccountActions?>()?.refresh();
                  if (!context.mounted) return;
                  await context.read<KnowledgeAssistance?>()?.refresh();
                  if (!context.mounted) return;
                  await context.read<ProgressViewModel>().load();
                  if (!context.mounted) return;
                  await context.read<HomeViewModel>().refresh();
                  if (!context.mounted) return;
                  await context.read<KnowledgeViewModel>().load();
                },
              ),
        update: (_, profile, push) => push
          ?..configure(
            enabled:
                profile.ready &&
                profile.data.sessionActive &&
                profile.data.backgroundNotifications,
          ),
      ),
    ],
    child: Consumer<ProfileViewModel>(
      builder: (context, profile, _) => MaterialApp.router(
        title: 'Agenote',
        locale: profile.locale,
        supportedLocales: const [Locale('zh', 'CN'), Locale('en', 'US')],
        localizationsDelegates: const [
          AppStrings.delegate,
          ...GlobalMaterialLocalizations.delegates,
        ],
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light(),
        darkTheme: AppTheme.dark(),
        themeMode: profile.themeMode,
        routerConfig: _router,
        builder: (context, child) {
          // Only account restoration replaces the navigation tree. Refreshing an
          // already loaded account must preserve pushed routes and their state.
          if (profile.loading && (!profile.ready || profile.resolvingAccount)) {
            return const Scaffold(
              body: SafeArea(
                child: ContentSkeleton(
                  key: ValueKey('startup-home-skeleton'),
                  layout: SkeletonLayout.home,
                  label: '正在恢复账户并加载首页',
                ),
              ),
            );
          }
          if (!profile.ready) {
            return Scaffold(
              body: SafeArea(
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(28),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          (profile.error ?? '资料读取失败，原有设置未被覆盖').tr(context),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 16),
                        FilledButton(
                          onPressed: profile.load,
                          child: Text('重试'.tr(context)),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          }
          return !profile.data.sessionActive
              ? child ?? const SizedBox.shrink()
              : NotificationOverlay(
                  child: RecordingStatusHost(
                    router: _router,
                    child: NotificationHost(
                      router: _router,
                      navigatorKey: _navigatorKey,
                      child: child ?? const SizedBox.shrink(),
                    ),
                  ),
                );
        },
      ),
    ),
  );
}
