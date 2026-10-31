import '../../features/work_assistant/assistant_page.dart';
import '../../features/work_assistant/outcome_detail_page.dart';
import '../../features/offline_recordings/transfer_space_page.dart';
import '../../features/personalization/personalization_page.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../features/progress/views/progress_page.dart';
import '../../features/progress/views/progress_details.dart';
import '../../features/home/views/home_page.dart';
import '../../features/recording_device/recorder_device_page.dart';
import '../../features/recording_device/recorder_device_detail_page.dart';
import '../../features/profile/views/profile_page.dart';
import '../../features/knowledge/views/knowledge_page.dart';
import '../../features/knowledge/views/knowledge_detail_page.dart';
import '../navigation/main_shell.dart';
import 'destinations.dart';
import '../../features/notifications/notification_views.dart';
import '../../features/meeting/meeting_page.dart';
import '../../features/meeting/minutes/meeting_minutes_page.dart';
import '../../features/auth/views/auth_page.dart';
import '../../features/auth/views/forgot_password_page.dart';
import '../../features/profile/viewmodels/profile_view_model.dart';

/// One account gate shared by startup, login and restored sessions.
String? accountRedirect(ProfileViewModel? profile, String path) {
  if (profile == null || !profile.ready) return null;
  final authRoute = ['/login', '/register', '/forgot-password'].contains(path);
  if (!profile.data.sessionActive && !authRoute) return '/login';
  if (profile.resolvingAccount) return null;
  if (profile.data.sessionActive) {
    final pending = profile.data.personalization?.required == true;
    if (pending && path != '/personalization') {
      return '/personalization';
    }
    if (!pending && (authRoute || path == '/personalization')) {
      return AppRoutes.home;
    }
  }
  return null;
}

GoRouter createRouter({
  String initialLocation = AppRoutes.home,
  GlobalKey<NavigatorState>? navigatorKey,
  ProfileViewModel? profile,
}) => GoRouter(
  navigatorKey: navigatorKey,
  initialLocation: initialLocation,
  refreshListenable: profile,
  redirect: (_, state) {
    return accountRedirect(profile, state.uri.path);
  },
  routes: [
    GoRoute(
      path: '/profile/wechat-assistant',
      builder: (_, _) => const WorkAssistantPage(),
    ),
    GoRoute(
      path: '/outcomes/:id',
      builder: (_, state) =>
          OutcomeDetailPage(runId: state.pathParameters['id']!),
    ),
    GoRoute(
      path: '/profile/transfers',
      builder: (_, _) => const TransferSpacePage(),
    ),
    GoRoute(
      path: '/personalization',
      builder: (_, _) =>
          PersonalizationPage(key: ValueKey(profile?.data.accountId)),
    ),
    GoRoute(
      path: '/profile/recording-device',
      builder: (_, _) => const RecorderDevicePage(),
      routes: [
        GoRoute(
          path: ':recordId',
          builder: (_, state) => RecorderDeviceDetailPage(
            recordId: state.pathParameters['recordId']!,
          ),
        ),
      ],
    ),
    GoRoute(path: '/login', builder: (_, _) => const AuthPage()),
    GoRoute(
      path: '/forgot-password',
      builder: (_, state) => ForgotPasswordPage(
        initialEmail: state.extra is String ? state.extra as String : '',
      ),
    ),
    GoRoute(
      path: '/register',
      builder: (_, _) => const AuthPage(register: true),
    ),
    GoRoute(
      path: '/meetings/:id/minutes',
      builder: (_, state) => MeetingMinutesPage(
        id: state.pathParameters['id']!,
        processing: state.uri.queryParameters['processing'] == '1',
        focusAction: state.uri.queryParameters['action'],
      ),
    ),
    GoRoute(
      path: '/meeting',
      pageBuilder: (_, state) => MaterialPage<void>(
        key: state.pageKey,
        child: MeetingPage(
          id: state.uri.queryParameters['id'],
          focusUtterance: state.uri.queryParameters['utterance'],
          startRecording:
              state.uri.queryParameters['record'] == '1' ||
              state.uri.queryParameters['demo'] == '1',
        ),
      ),
    ),
    GoRoute(
      path: '/notifications',
      builder: (_, _) => const NotificationsPage(),
    ),
    GoRoute(
      path: '/progress/artifacts/:id',
      redirect: (_, _) => '/notifications',
    ),
    GoRoute(
      path: '/knowledge/documents/:id',
      builder: (context, state) => KnowledgeDetailPage(
        id: state.pathParameters['id']!,
        versionId: state.uri.queryParameters['version'],
        start: int.tryParse(state.uri.queryParameters['start'] ?? ''),
        end: int.tryParse(state.uri.queryParameters['end'] ?? ''),
        hash: state.uri.queryParameters['hash'],
        relationLabel: state.uri.queryParameters['relation'],
        relationQuery: state.uri.queryParameters['relationQuery'],
        relationQuote: state.uri.queryParameters['quote'],
      ),
    ),
    for (final kind in ['goals', 'commitments'])
      GoRoute(
        path: '/progress/$kind/:id',
        builder: (context, state) =>
            ProgressDetailPage(kind: kind, id: state.pathParameters['id']!),
      ),
    StatefulShellRoute.indexedStack(
      builder: (context, state, shell) => MainShell(shell),
      branches: [
        StatefulShellBranch(
          routes: [
            GoRoute(path: AppRoutes.home, builder: (_, _) => const HomePage()),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: AppRoutes.affairs,
              builder: (_, state) => ProgressPage(
                key: ValueKey(state.uri.queryParameters['focus']),
                focusGoals: state.uri.queryParameters['section'] == 'goals',
              ),
            ),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: AppRoutes.knowledge,
              builder: (_, _) => const KnowledgePage(),
            ),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: AppRoutes.profile,
              builder: (_, _) => const ProfilePage(),
            ),
          ],
        ),
      ],
    ),
  ],
  errorBuilder: (context, state) => Scaffold(
    appBar: AppBar(title: const Text('页面未找到')),
    body: Center(
      child: TextButton(
        onPressed: () => context.go(AppRoutes.home),
        child: const Text('返回首页'),
      ),
    ),
  ),
);
