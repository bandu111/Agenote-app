import 'dart:async';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../profile/viewmodels/profile_view_model.dart';
import '../recording_device/recorder_device_view_model.dart';
import '../meeting/meeting_view_model.dart';
import 'recording_activity_coordinator.dart';
import 'recording_status_snapshot.dart';
import 'system_recording_activity.dart';
import 'recording_permission_guide.dart';

/// Owns native status/deep links only; does not add any Flutter banner or cutout.
class RecordingStatusHost extends StatefulWidget {
  const RecordingStatusHost({
    super.key,
    required this.router,
    required this.child,
  });
  final GoRouter router;
  final Widget child;
  @override
  State<RecordingStatusHost> createState() => _RecordingStatusHostState();
}

class _RecordingStatusHostState extends State<RecordingStatusHost>
    with WidgetsBindingObserver {
  late final RecordingActivityCoordinator coordinator;
  bool _opening = false, _guideOpen = false;
  Uri get _currentUri =>
      widget.router.routerDelegate.currentConfiguration.isEmpty
      ? widget.router.routeInformationProvider.value.uri
      : widget.router.routerDelegate.state.uri;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    coordinator = RecordingActivityCoordinator(
      meeting: context.read<MeetingViewModel>(),
      profile: context.read<ProfileViewModel>(),
      device: context.read<RecorderDeviceViewModel>(),
    );
    NativeRecordingActivity.channel.setMethodCallHandler((call) async {
      if (call.method == 'showPermissionGuide') {
        if (_guideOpen || !mounted) return false;
        final navigatorContext =
            widget.router.routerDelegate.navigatorKey.currentContext;
        if (navigatorContext == null) return false;
        _guideOpen = true;
        try {
          return await showDialog<bool>(
                context: navigatorContext,
                useRootNavigator: true,
                animationStyle: MediaQuery.disableAnimationsOf(navigatorContext)
                    ? AnimationStyle.noAnimation
                    : const AnimationStyle(
                        duration: Duration(milliseconds: 200),
                      ),
                builder: (_) =>
                    RecordingPermissionGuide(snapshot: coordinator.snapshot),
              ) ??
              false;
        } finally {
          _guideOpen = false;
        }
      }
      if (call.method == 'openMeeting' && call.arguments is String) {
        await _open(call.arguments as String);
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _takeOpen());
  }

  Future<void> _takeOpen() async {
    try {
      final id = await coordinator.platform.takeOpenMeeting();
      if (id != null && mounted) await _open(id);
    } catch (_) {}
  }

  Future<void> _open(String id) async {
    if (!mounted ||
        _opening ||
        !context.read<ProfileViewModel>().data.sessionActive) {
      return;
    }
    if (recordingMeetingFromUri(
          Uri(scheme: 'agenote', host: 'recording', pathSegments: [id]),
        ) ==
        null) {
      return;
    }
    _opening = true;
    try {
      final vm = context.read<MeetingViewModel>();
      final current = coordinator.snapshot;
      if (current?.meetingId == id && vm.active) {
        final uri = _currentUri;
        if (uri.path != '/meeting' ||
            uri.queryParameters['id'] != null &&
                uri.queryParameters['id'] != id) {
          // No record=1: opening a status entry can never start a recorder.
          unawaited(widget.router.push<void>('/meeting'));
        }
      } else {
        await vm.loadHistory();
        if (!mounted) return;
        final owner = context.read<ProfileViewModel>().data.accountId;
        final exists = vm.history.any(
          (r) => r.id == id && r.ownerId == owner && r.ended,
        );
        if (exists && _currentUri.path != '/meetings/$id/minutes') {
          unawaited(
            widget.router.push<void>(
              '/meetings/${Uri.encodeComponent(id)}/minutes',
            ),
          );
        }
      }
    } finally {
      _opening = false;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      coordinator.reconcile();
      unawaited(_takeOpen());
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    NativeRecordingActivity.channel.setMethodCallHandler(null);
    coordinator.dispose();
    super.dispose();
  }
}
