import '../../first_run/first_run_store.dart';
import '../../first_run/brand_splash.dart';
import '../../first_run/onboarding_page.dart';
import 'package:flutter/material.dart';
import '../../../app/app.dart';
import '../../../app/theme/app_theme.dart';
import '../../profile/repositories/profile_repository.dart';
import '../repositories/auth_repository.dart';
import '../services/auth_bootstrap.dart';
import '../../meeting/meeting_remote.dart';
import '../../progress/repositories/progress_repository.dart';
import '../../knowledge/repositories/knowledge_repository.dart';
import '../../../core/network/api_client.dart';
import '../../meeting/meeting_store.dart';
import '../../meeting/meeting_services.dart';

/// 会话校验期间先显示加载界面，避免网络等待阻塞首帧。
class AccountBootstrap extends StatefulWidget {
  const AccountBootstrap({
    super.key,
    required this.auth,
    required this.profiles,
    this.meetingRemote,
    this.progressRepository,
    this.knowledgeRepository,
    this.apiClient,
    this.meetingStore,
    this.meetingRecorder,
    this.firstRunStore = const SecureFirstRunStore(),
  });
  final SessionAuthRepository auth;
  final ProfileRepository profiles;
  final MeetingRemoteRepository? meetingRemote;
  final ProgressRepository? progressRepository;
  final KnowledgeRepository? knowledgeRepository;
  final ApiClient? apiClient;
  final MeetingStore? meetingStore;
  final MeetingRecorder? meetingRecorder;
  final FirstRunStore firstRunStore;

  @override
  State<AccountBootstrap> createState() => _AccountBootstrapState();
}

class _AccountBootstrapState extends State<AccountBootstrap> {
  late final _restoration = restoreAccountSession(widget.auth, widget.profiles);

  late Future<bool> _firstRun = widget.firstRunStore.completed();
  bool _completed = false;

  Future<void> _complete() async {
    await widget.firstRunStore.complete();
    if (mounted) setState(() => _completed = true);
  }

  Widget _firstRunApp(Widget child) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'Agenote',
    theme: AppTheme.light(),
    darkTheme: AppTheme.dark(),
    home: child,
  );

  @override
  Widget build(BuildContext context) => FutureBuilder<String?>(
    future: _restoration,
    builder: (context, snapshot) {
      if (snapshot.connectionState == ConnectionState.done) {
        final app = YanShuApp(
          authRepository: widget.auth,
          profileRepository: widget.profiles,
          initialAuthError: snapshot.data,
          meetingRemote: widget.meetingRemote,
          progressRepository: widget.progressRepository,
          knowledgeRepository: widget.knowledgeRepository,
          apiClient: widget.apiClient,
          meetingStore: widget.meetingStore,
          meetingRecorder: widget.meetingRecorder,
        );
        // Existing authenticated accounts bypass first-run regardless of its flag.
        if (widget.auth.authenticated || _completed) return app;
        return FutureBuilder<bool>(
          future: _firstRun,
          builder: (context, firstRun) {
            if (firstRun.hasError) {
              return _firstRunApp(
                BrandSplash(
                  error: '首次使用状态读取失败，请重试',
                  onRetry: () => setState(() {
                    _firstRun = widget.firstRunStore.completed();
                  }),
                ),
              );
            }
            if (firstRun.connectionState != ConnectionState.done) {
              return _firstRunApp(const BrandSplash());
            }
            if (firstRun.data == true) return app;
            return _firstRunApp(OnboardingPage(onComplete: _complete));
          },
        );
      }
      return _firstRunApp(const BrandSplash());
    },
  );
}
